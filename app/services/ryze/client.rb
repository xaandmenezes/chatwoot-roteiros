require 'net/http'
require 'json'
require 'timeout'

class Ryze::Client
  class ConnectionError < StandardError; end

  REQUEST_BUDGET = 8

  def initialize(instance:, token:, read_timeout: 4, request_budget: REQUEST_BUDGET)
    @instance = URI.encode_www_form_component(instance).gsub('+', '%20')
    @token = token
    @read_timeout = read_timeout
    @request_budget = request_budget
  end

  def get(path, **query)
    uri = endpoint(path)
    uri.query = URI.encode_www_form(query)
    request(uri, Net::HTTP::Get.new(uri))
  end

  def post(path, payload)
    send_json(path, Net::HTTP::Post, payload)
  end

  def delete(path, payload)
    send_json(path, Net::HTTP::Delete, payload)
  end

  private

  def send_json(path, request_class, payload)
    uri = endpoint(path)
    http_request = request_class.new(uri)
    http_request['Content-Type'] = 'application/json'
    http_request.body = JSON.generate(payload)
    request(uri, http_request)
  end

  def endpoint(path)
    URI("https://ryzeapi.cloud/api/#{path}/#{@instance}")
  end

  def request(uri, http_request)
    http_request['token'] = @token
    http_request['Accept'] = 'application/json'

    Timeout.timeout(@request_budget) do
      Net::HTTP.start(uri.host, uri.port, nil,
                      use_ssl: true, open_timeout: 2, read_timeout: @read_timeout, write_timeout: 2, max_retries: 0) do |http|
        http.request(http_request)
      end
    end
  rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse
    raise ConnectionError, 'Could not reach Ryze', cause: nil
  end
end
