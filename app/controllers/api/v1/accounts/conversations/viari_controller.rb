class Api::V1::Accounts::Conversations::ViariController < Api::V1::Accounts::Conversations::BaseController
  before_action :prepare_integration
  rescue_from Viari::Client::Unavailable, with: :upstream_unavailable

  rescue_from Viari::ContactBinding::Conflict do
    head :conflict
  end

  READS = {
    'resumo_comercial' => [], 'capacidades' => [], 'catalogo' => [], 'parceiros' => [:busca, :incluirInativos], 'cliente_detalhe' => [], 'orcamento' => [:orcamentoId],
    'reserva_agendas_remarcacao' => [:reservaId], 'reserva' => [:reservaId], 'os' => [:grupoId], 'agendas' => [:produtoId, :dataInicio, :dataFim],
    'tarifas' => [:produtoId, :grupoTarifaId, :data]
  }.freeze
  CUSTOMER = [:nome, :telefone, :email, :documento, :nacionalidade, :hotelHospedado, :dataChegada, :dataPartida, :observacoes, :canalAquisicaoId].freeze
  PARTNER = [:nome, :tipo, :contato, :telefone, :email, :comissaoPercent, :observacoes].freeze
  QUOTE = [:canalVendaId, :periodoInicio, :periodoFim, :dataValidade, :percentualSinal, :descontoManual,
           :obsInternas, :msgCliente, :confirmarDuplicacao,
           { itens: [:produtoId, :agendaId, :qtdAdt, :qtdChd, :qtdInf, :qtdSen, :qtdFree, { itensSelecionados: [] }] }].freeze
  PASSENGER = [:nome, :tipoPax, :idade, :documento, :necessidadeEspecial, :observacao].freeze
  EDIT_QUOTE = [:operacao, :revisao, :itemId, :produtoId, :dataDesejada, :agendaId, :horarioDesejado, :localEmbarqueId,
                :qtdAdt, :qtdChd, :qtdInf, :qtdSen, :qtdFree, :cupomCodigo, :observacoes, { itensSelecionados: [] }].freeze
  PAYMENT = [:valor, :metodo, :tipoPagamento, :recebedorTipo, :parceiroId, :parcelas, :data, :contaBancariaId].freeze
  COMMANDS = {
    'cliente_criar' => CUSTOMER, 'cliente_editar' => CUSTOMER, 'parceiro_criar' => PARTNER,
    'parceiro_editar' => PARTNER + [:parceiroId], 'parceiro_ativar' => [:parceiroId, :ativo], 'orcamento_criar' => QUOTE,
    'orcamento_editar' => QUOTE + EDIT_QUOTE + PASSENGER + [:passageiroId], 'orcamento_enviar' => [:revisao], 'orcamento_aprovar' => [:revisao, :confirmado],
    'orcamento_recusar' => [:revisao, :motivo], 'orcamento_cancelar' => [:revisao],
    'orcamento_converter' => [:revisao, :canalVendaId, :observacoes, { locaisEmbarque: {} }],
    'pagamento_previa' => PAYMENT, 'pagamento_registrar' => PAYMENT,
    'os_passageiro_adicionar' => PASSENGER, 'reserva_passageiro_adicionar' => PASSENGER,
    'reserva_passageiro_atribuir' => [:passageiroId], 'reserva_passageiro_desatribuir' => [:passageiroId],
    'reserva_passageiro_editar' => PASSENGER + [:passageiroId], 'reserva_passageiro_remover' => [:passageiroId],
    'reserva_editar' => [:agendaId, :agendaOriginalId, :qtdAdt, :qtdChd, :qtdInf, :qtdSen, :qtdFree, :localEmbarqueId, :observacoes,
                        { cancelamentoParcial: [:versao, :valor, :motivo, :confirmarAcimaReferencia] }],
    'reserva_cancelamento_parcial_previa' => [:qtdAdt, :qtdChd, :qtdInf, :qtdSen, :qtdFree],
    'reserva_cancelamento_previa' => [],
    'reserva_cancelar' => [:motivo, :reterPagamento, :valorRetidoEsperado, :valorRetido],
    'pagamento_dados_edicao' => [:pagamentoId], 'pagamento_estorno_previa' => [:pagamentoId],
    'pagamento_editar' => PAYMENT + [:pagamentoId, :versao, :contaBancariaAlterada, :gatewayRef],
    'pagamento_estornar' => [:pagamentoId, :valor, :valorDisponivelEsperado]
  }.freeze

  def show
    action = params[:acao]
    return render json: { ok: true, data: { clienteId: @binding.customer_id, accountId: Current.account.id, userId: Current.user.id, acoes: @capabilities['acoes'] } } if action == 'contexto'
    return render json: { ok: true, data: @capabilities.slice('acoes') } if action == 'capacidades'
    return search_customer if action == 'cliente_buscar'
    return head :bad_request unless READS.key?(action)
    return head :conflict unless @binding.customer_id || %w[capacidades catalogo parceiros tarifas agendas].include?(action)

    relay(@client.get(action, params.permit(*READS.fetch(action)).to_h.merge('clienteId' => @binding.customer_id)))
  end

  def create
    action = params.require(:acao)
    return head :bad_request unless Viari::Settings::UUID.match?(request.headers['Idempotency-Key'].to_s)
    return link_customer if action == 'cliente_vincular'
    return launch_native if action == 'abrir_nativo'
    return head :bad_request unless COMMANDS.key?(action)
    return head :conflict if !%w[cliente_criar parceiro_criar parceiro_editar parceiro_ativar].include?(action) && @binding.customer_id.blank?
    return render json: { ok: true, data: { id: @binding.customer_id } } if action == 'cliente_criar' && @binding.customer_id.present?

    data = params.fetch(:dados, ActionController::Parameters.new).permit(*COMMANDS.fetch(action)).to_h
    attributes = params.permit(:orcamentoId, :reservaId, :grupoId, :revisao).to_h
    attributes[:clienteId] = @binding.customer_id if @binding.customer_id
    key = request.headers['Idempotency-Key']
    data['cancelamentoParcial']['chaveOperacao'] = key if action == 'reserva_editar' && data['cancelamentoParcial'].is_a?(Hash)
    key = @binding.claim_creation(data.merge('chatwoot_actor' => Current.user.id, 'viari_actor' => @viari_actor), key) if action == 'cliente_criar'
    status, result = @client.post(action, attributes.merge(dados: data), key)
    @binding.release_creation(key) if action == 'cliente_criar' && [400, 403, 422].include?(status)
    if action == 'cliente_criar' && result['ok']
      @binding.bind(result.fetch('data').fetch('id'), creation_key: key)
    end
    relay([status, result])
  end

  private

  def prepare_integration
    head :forbidden and return unless dashboard_user?
    configuration = Viari::Configuration.for(Current.account)
    @viari_actor = configuration&.actor_for(Current.user)
    head :forbidden and return if @viari_actor.blank? || Ryze::GroupConversations.group?(@conversation)

    @configuration = configuration
    @client = Viari::Client.new(configuration, @viari_actor)
    status, response_data = @client.get('capacidades')
    return relay([status, response_data]) unless response_data['ok']

    @capabilities = response_data.fetch('data')
    tenant_id = @capabilities['tenantId']
    raise Viari::Client::Unavailable unless Viari::Settings::UUID.match?(tenant_id.to_s)

    @binding = Viari::ContactBinding.new(@conversation.contact, configuration.binding_scope(tenant_id))
    response.headers['Cache-Control'] = 'no-store'
  end

  def search_customer
    phone = @conversation.contact.phone_number
    return render json: { ok: true, data: { clientes: [] } } if phone.blank?

    status, result = @client.get('cliente_buscar', telefone: phone)
    candidates = if result['ok']
                   [result.dig('data', 'cliente')].compact
                 elsif status == 409
                   result.dig('error', 'detalhes', 'candidatos')
                 end
    return relay([status, result]) unless candidates.is_a?(Array)

    render json: { ok: true, data: { clientes: candidates.map { |c| c.slice('id', 'nome', 'telefone') } } }
  end

  def link_customer
    id = params.require(:clienteId)
    phone = @conversation.contact.phone_number
    return head :unprocessable_entity if phone.blank?

    status, result = @client.post('cliente_vincular', { clienteId: id, dados: { telefone: phone } }, request.headers['Idempotency-Key'])
    return relay([status, result]) unless result['ok']

    @binding.bind(id)
    render json: { ok: true, data: { clienteId: id } }
  end

  def launch_native
    data = params.fetch(:dados, ActionController::Parameters.new).permit(:destino, :orcamentoId, :reservaId, :grupoId).to_h
    return head :conflict if @binding.customer_id.blank? && data['destino'] != 'cliente_criar'
    attributes = params.permit(:orcamentoId, :reservaId, :grupoId).to_h
    attributes[:clienteId] = @binding.customer_id if @binding.customer_id
    status, result = @client.post('abrir_nativo', attributes.merge(dados: data), request.headers['Idempotency-Key'])
    return relay([status, result]) unless result['ok']

    launch = Viari::NativeLaunch.new(@configuration.origin, result.fetch('data')).data
    render json: { ok: true, data: launch }, status: status
  end

  def relay(result)
    status, body = result
    render json: body, status: status
  end

  def upstream_unavailable
    render json: { ok: false, error: { codigo: 'viari_unavailable' } }, status: :bad_gateway
  end
end
