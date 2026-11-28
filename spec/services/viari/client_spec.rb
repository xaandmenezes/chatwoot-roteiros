require 'rails_helper'

RSpec.describe Viari::Client do
  let(:actor) { SecureRandom.uuid }
  let(:configuration) { Viari::Configuration.new('origin' => 'https://viari.example', 'namespace' => 'test', 'api_key' => 'sample-key', 'actors' => {}) }
  let(:client) { described_class.new(configuration, actor) }
  let(:key) { SecureRandom.uuid }

  around do |example|
    with_modified_env(VIARI_CHATWOOT_SIGNING_SECRET: 'x' * 40) { example.run }
  end

  it 'signs and transmits the exact bytes of an authorized command' do
    stub = stub_request(:post, 'https://viari.example/api/viari/atendimento').with do |req|
      headers = req.headers
      canonical = ['POST', '/api/viari/atendimento', headers['X-Viari-Timestamp'], actor, key, req.body].join("\n")
      signature = OpenSSL::HMAC.hexdigest('SHA256', 'x' * 40, canonical)
      headers['X-Viari-Signature'] == signature && headers['X-Viari-Api-Key'] == 'sample-key' &&
        JSON.parse(req.body).dig('dados', 'nome') == 'João'
    end.to_return(status: 200, body: { ok: true, data: { id: actor } }.to_json)
    expect(client.post('cliente_criar', { dados: { nome: 'João' } }, key).first).to eq(200)
    expect(stub).to have_been_requested.once
  end

  it 'does not forward credentials when an upstream responds with a redirect' do
    stub_request(:get, 'https://viari.example/api/viari/atendimento?acao=capacidades').to_return(status: 307, headers: { 'Location' => 'https://other.example' })
    expect { client.get('capacidades') }.to raise_error(described_class::Unavailable)
    expect(WebMock).not_to have_requested(:get, 'https://other.example')
  end
end
