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
