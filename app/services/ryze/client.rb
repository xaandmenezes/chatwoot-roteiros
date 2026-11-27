require 'net/http'
require 'json'
require 'timeout'

class Ryze::Client
  class ConnectionError < StandardError; end

  REQUEST_BUDGET = 8
  ResponseLimits = Data.define(:deadline, :max_bytes)

  def initialize(instance:, token:, read_timeout: 4, request_budget: REQUEST_BUDGET, limits: nil)
    @instance = URI.encode_www_form_component(instance).gsub('+', '%20')
    @token = token
    @read_timeout = read_timeout
    @request_budget = request_budget
    @limits = limits
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
    http_request['Accept-Encoding'] = 'identity' if @limits

    budget = @limits ? [@request_budget, @limits.deadline - Time.current].min : @request_budget
    raise ConnectionError, 'Ryze request deadline reached' unless budget.positive?

    Timeout.timeout(budget) do
      Net::HTTP.start(uri.host, uri.port, nil,
                      use_ssl: true, open_timeout: 2, read_timeout: @read_timeout, write_timeout: 2, max_retries: 0) do |http|
        return http.request(http_request) unless @limits

        http.request(http_request) do |response|
          return response unless response.code.to_i.between?(200, 299)

          read_bounded_body(response)
          return response
        end
      end
    end
  rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse
    raise ConnectionError, 'Could not reach Ryze', cause: nil
  end

  def read_bounded_body(response)
    body = +''.b
    response.read_body do |chunk|
      raise ConnectionError, 'Ryze response exceeded size limit' if body.bytesize + chunk.bytesize > @limits.max_bytes

      body << chunk
    end
    response.body = body
  end
end
