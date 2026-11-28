require 'rails_helper'

RSpec.describe 'Conversation Viari integration', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: agent) }
  let(:headers) { agent.create_new_auth_token.merge('Idempotency-Key' => SecureRandom.uuid) }
  let(:path) { "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/viari" }
  let(:actor) { SecureRandom.uuid }
  let(:configuration) { { origin: 'https://example.org', namespace: 'sandbox', api_key: 'fixture-key', actors: { agent.id.to_s => actor } } }
  let(:client) { instance_double(Viari::Client) }

  around do |example|
    with_modified_env(VIARI_CHATWOOT_ACCOUNTS: { account.id => configuration }.to_json, VIARI_CHATWOOT_SIGNING_SECRET: 'x' * 40) { example.run }
  end

  before do
    create(:inbox_member, inbox: inbox, user: agent)
    allow(Viari::Client).to receive(:new).and_return(client)
    allow(client).to receive(:get).with('capacidades').and_return([200, { 'ok' => true, 'data' => { 'tenantId' => SecureRandom.uuid, 'acoes' => [] } }])
  end

  it 'opens an unlinked conversation without creating a customer' do
    get path, params: { acao: 'contexto' }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('data', 'clienteId')).to be_nil
    expect(Viari::ContactLink.count).to eq(0)
  end

  it 'derives the search phone from the authorized contact' do
    conversation.contact.update!(phone_number: '+5573999999999')
    expect(client).to receive(:get).with('cliente_buscar', telefone: '+5573999999999')
                                   .and_return([200, { 'ok' => true, 'data' => { 'encontrado' => false } }])
    get path, params: { acao: 'cliente_buscar', telefone: '+15555555555' }, headers: headers
    expect(response.parsed_body.dig('data', 'clientes')).to eq([])
  end

  it 'denies an unlinked payment before calling Viari' do
    post path, params: { acao: 'pagamento_registrar', clienteId: SecureRandom.uuid, dados: { valor: 10 } }, headers: headers, as: :json
    expect(response).to have_http_status(:conflict)
  end

  it 'blocks a remapped actor from reusing an unresolved customer creation claim' do
    request_data = { acao: 'cliente_criar', dados: { nome: 'Cliente' } }
    original_key = headers.fetch('Idempotency-Key')
    expect(client).to receive(:post).with('cliente_criar', { dados: { 'nome' => 'Cliente' } }, original_key)
                                   .and_raise(Viari::Client::Unavailable)

    post path, params: request_data, headers: headers, as: :json
    expect(response).to have_http_status(:bad_gateway)

    reassigned = configuration.merge(actors: { agent.id.to_s => SecureRandom.uuid })
    with_modified_env(VIARI_CHATWOOT_ACCOUNTS: { account.id => reassigned }.to_json) do
      post path, params: request_data, headers: headers, as: :json
      expect(response).to have_http_status(:conflict)
    end

    customer = SecureRandom.uuid
    expect(client).to receive(:post).with('cliente_criar', { dados: { 'nome' => 'Cliente' } }, original_key)
                                   .and_return([200, { 'ok' => true, 'data' => { 'id' => customer } }])
    post path, params: request_data, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('data', 'id')).to eq(customer)
  end

  it 'requires conversation access even when a different agent can see the account' do
    outsider = create(:user, account: account, role: :agent)
    expect(Viari::Client).not_to receive(:new)
    get path, params: { acao: 'contexto' }, headers: outsider.create_new_auth_token
    expect(response).to have_http_status(:unauthorized).or have_http_status(:forbidden)
  end
end

RSpec.describe 'Conversation Viari native launch', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: agent) }
  let(:headers) { agent.create_new_auth_token.merge('Idempotency-Key' => SecureRandom.uuid) }
  let(:path) { "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/viari" }
  let(:actor) { SecureRandom.uuid }
  let(:tenant) { SecureRandom.uuid }
  let(:customer) { SecureRandom.uuid }
  let(:configuration) { { origin: 'https://example.org', namespace: 'sandbox', api_key: 'secret-key', actors: { agent.id.to_s => actor } } }
  let(:client) { instance_double(Viari::Client) }

  around do |example|
    with_modified_env(VIARI_CHATWOOT_ACCOUNTS: { account.id => configuration }.to_json, VIARI_CHATWOOT_SIGNING_SECRET: 'x' * 40) { example.run }
  end

  before do
    create(:inbox_member, inbox: inbox, user: agent)
    allow(Viari::Client).to receive(:new).and_return(client)
    allow(client).to receive(:get).with('capacidades').and_return([200, { 'ok' => true, 'data' => { 'tenantId' => tenant, 'acoes' => [] } }])
    scope = Viari::Configuration.new(configuration.deep_stringify_keys).binding_scope(tenant)
    Viari::ContactBinding.new(conversation.contact, scope).bind(customer)
  end

  it 'launches with the persisted customer and excludes upstream credentials' do
    quote = SecureRandom.uuid
    expect(client).to receive(:post).with('abrir_nativo',
                                         { clienteId: customer, dados: { 'destino' => 'orcamento_editar', 'orcamentoId' => quote } },
                                         headers.fetch('Idempotency-Key'))
                                   .and_return([200, { 'ok' => true, 'data' => {
                                     'url' => 'https://example.org/atendimento/nativo?ticket=opaque', 'mode' => 'iframe',
                                     'channel' => 'channel', 'api_key' => 'secret-key'
                                   } }])
    post path, params: { acao: 'abrir_nativo', clienteId: SecureRandom.uuid,
                         dados: { destino: 'orcamento_editar', orcamentoId: quote, clienteId: SecureRandom.uuid } }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('data', 'origin')).to eq('https://example.org')
    expect(response.body).not_to include('secret-key')
  end

  it 'rejects a launch URL outside the configured origin' do
    allow(client).to receive(:post).and_return([200, { 'ok' => true, 'data' => { 'url' => 'https://other.example/atendimento/nativo' } }])
    post path, params: { acao: 'abrir_nativo', dados: { destino: 'cliente_editar' } }, headers: headers, as: :json
    expect(response).to have_http_status(:bad_gateway)
  end

  it 'does not reuse the customer binding after the verified tenant changes' do
    allow(client).to receive(:get).with('capacidades').and_return([200, { 'ok' => true, 'data' => {
      'tenantId' => SecureRandom.uuid, 'acoes' => []
    } }])
    expect(client).not_to receive(:post)
    post path, params: { acao: 'abrir_nativo', dados: { destino: 'cliente_editar' } }, headers: headers, as: :json
    expect(response).to have_http_status(:conflict)
  end

  it 'does not launch other native destinations for an unlinked contact' do
    Viari::ContactLink.where(contact_id: conversation.contact.id).delete_all
    expect(client).not_to receive(:post)
    %w[cliente_editar orcamento_criar parceiros os pagamento].each do |destination|
      post path, params: { acao: 'abrir_nativo', dados: { destino: destination } }, headers: headers, as: :json
      expect(response).to have_http_status(:conflict)
    end
  end

  it 'allows native customer creation without accepting a browser customer id' do
    Viari::ContactLink.where(contact_id: conversation.contact.id).delete_all
    expect(client).to receive(:post).with('abrir_nativo', { dados: { 'destino' => 'cliente_criar' } },
                                         headers.fetch('Idempotency-Key'))
                                   .and_return([200, { 'ok' => true, 'data' => {
                                     'url' => 'https://example.org/atendimento/nativo?ticket=opaque', 'mode' => 'iframe'
                                   } }])
    post path, params: { acao: 'abrir_nativo', clienteId: SecureRandom.uuid, dados: { destino: 'cliente_criar' } }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
  end

  it 'reads proposal text for the bound customer without submitting a command' do
    quote = SecureRandom.uuid
    expect(client).not_to receive(:post)
    expect(client).to receive(:get).with('orcamento_texto', 'clienteId' => customer, 'orcamentoId' => quote)
                                  .and_return([200, { 'ok' => true, 'data' => { 'orcamentoId' => quote, 'status' => 'rascunho', 'textoWhatsapp' => 'Proposta para conferência' } }])
    get path, params: { acao: 'orcamento_texto', orcamentoId: quote, clienteId: SecureRandom.uuid }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('data', 'textoWhatsapp')).to eq('Proposta para conferência')
  end

  it 'denies proposal text access before a customer is bound' do
    Viari::ContactLink.where(contact_id: conversation.contact.id).delete_all
    expect(client).not_to receive(:get).with('orcamento_texto', anything)
    get path, params: { acao: 'orcamento_texto', orcamentoId: SecureRandom.uuid }, headers: headers
    expect(response).to have_http_status(:conflict)
  end

  it 'reads the summary using the persisted customer' do
    expect(client).to receive(:get).with('resumo_comercial', 'clienteId' => customer)
                                  .and_return([200, { 'ok' => true, 'data' => { 'cliente' => { 'id' => customer }, 'orcamentos' => [] } }])
    get path, params: { acao: 'resumo_comercial', clienteId: SecureRandom.uuid }, headers: headers
    expect(response).to have_http_status(:ok)
  end
end
