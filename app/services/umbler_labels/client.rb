require 'json'
require 'net/http'

class UmblerLabels::Client
  class Error < StandardError; end
  class AmbiguousSearch < Error; end

  BASE_URL = 'https://app-utalk.umbler.com/api/v1'.freeze
  SEARCH_LIMIT = 25
  CATALOG_PAGE_SIZE = 250

  def initialize(organization_id:, token:)
    @organization_id = organization_id
    @token = token
  end

  def search_contacts(phone)
    items, total = get_page('contacts', QueryString: phone.delete_prefix('+'), Take: SEARCH_LIMIT)
    raise AmbiguousSearch, 'Umbler contact search exceeded the result limit' if total > items.size

    items.select { |item| item['phoneNumber'] == phone }
  end

  def label_catalog
    @label_catalog ||= fetch_label_catalog
  end

  private

  def fetch_label_catalog
    tags = {}
    offset = 0
    loop do
      items, total = get_page('tags', Skip: offset, Take: CATALOG_PAGE_SIZE)
      items.each { |item| add_catalog_tag(tags, item) }
      offset += items.size
      return tags if offset >= total

      raise Error, 'Umbler label catalog is incomplete' if items.empty?
    end
  end

  def add_catalog_tag(tags, item)
    id = item['id']
    raise Error, 'Invalid label in Umbler catalog' unless id.is_a?(String) && id.present? && !tags.key?(id)

    tags[id] = item
  end

  def get_page(resource, **parameters)
    result = get_json(resource, { Behavior: 'CountAllAndGetSlice', **parameters })
    items = result['items']
    total = result['page'].is_a?(Hash) && result['page']['totalItems']
    raise Error, 'Umbler returned an invalid result page' unless items.is_a?(Array) && items.all?(Hash) && total.is_a?(Integer) && total >= items.size

    [items, total]
  end

  def get_json(resource, parameters)
    uri = URI("#{BASE_URL}/#{resource}/")
    uri.query = URI.encode_www_form(organizationId: @organization_id, **parameters)
    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = "Bearer #{@token}"
    request['Accept'] = 'application/json'

    response = send_request(uri, request)
    raise Error, "Umbler request failed (HTTP #{response.code})" unless response.is_a?(Net::HTTPOK)

    data = JSON.parse(response.body)
    raise Error, 'Umbler returned an invalid response' unless data.is_a?(Hash)

    data
  rescue JSON::ParserError, TypeError
    raise Error, 'Umbler returned invalid JSON', cause: nil
  end

  def send_request(uri, request)
    Net::HTTP.start(uri.host, uri.port, nil, use_ssl: true, open_timeout: 2, read_timeout: 4, write_timeout: 2, max_retries: 0) do |http|
      http.request(request)
    end
  rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse
    raise Error, 'Could not reach Umbler', cause: nil
  end
end
