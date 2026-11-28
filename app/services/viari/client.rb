require 'net/http'
require 'openssl'

class Viari::Client
  class Unavailable < StandardError; end

  def initialize(configuration, actor)
    @configuration = configuration
    @actor = actor
  end

  def get(action, attributes = {})
    request(:get, { acao: action }.merge(attributes))
  end

  def post(action, attributes, key)
    request(:post, { acao: action }.merge(attributes), key)
  end

  private

  def request(method, attributes, key = nil)
    uri = @configuration.origin.dup
    uri.path = '/api/viari/atendimento'
    uri.query = URI.encode_www_form(attributes.compact) if method == :get
    body = method == :post ? attributes.to_json : ''
    timestamp = Time.current.to_i.to_s
    canonical = [method.to_s.upcase, uri.request_uri, timestamp, @actor, key, body].join("\n")
    headers = {
      'Content-Type' => 'application/json', 'Accept' => 'application/json',
      'x-viari-api-key' => @configuration.api_key, 'x-viari-actor-id' => @actor,
      'x-viari-timestamp' => timestamp, 'Idempotency-Key' => key,
      'x-viari-signature' => OpenSSL::HMAC.hexdigest('SHA256', @configuration.signing_secret, canonical)
    }.compact
    req = (method == :get ? Net::HTTP::Get : Net::HTTP::Post).new(uri, headers)
    req.body = body if method == :post
    http = Net::HTTP.new(uri.host, uri.port, nil)
    http.use_ssl = uri.is_a?(URI::HTTPS)
    http.open_timeout = 4
    http.read_timeout = 20
    http.write_timeout = 5
    http.max_retries = 0
    response = http.request(req)
    status = response.code.to_i
    raise Unavailable unless [200, 201, 400, 401, 403, 404, 409, 422, 429].include?(status)

    json = JSON.parse(response.body)
    raise Unavailable unless json.is_a?(Hash) && [true, false].include?(json['ok'])
    return [status, json.slice('ok', 'data')] if json['ok'] && status < 300

    error = json.fetch('error').slice('codigo', 'mensagem')
    if attributes[:acao] == 'cliente_buscar' && status == 409
      error['detalhes'] = json.fetch('error').fetch('detalhes', {}).slice('candidatos')
    end
    [status, { 'ok' => false, 'error' => error }]
  rescue JSON::ParserError, KeyError, Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError, Net::ProtocolError
    raise Unavailable
  end
end
