class Ryze::HistoricalSync
  class UpstreamError < StandardError; end
  class RateLimitError < UpstreamError; end

  Result = Struct.new(:imported_messages, :has_more, :next_before, keyword_init: true)
  PageResult = Struct.new(:imported, :has_more, :next_before, :next_cursor, keyword_init: true)

  PAGE_SIZE = 50
  MAX_PAGES_PER_RUN = 3
  MAX_MEDIA_BYTES = MediaAttacher::MAX_MEDIA_BYTES
  SKIPPED_TYPES = %w[reaction message_edit message_revoke protocol_message].freeze
  MEDIA_FILE_TYPES = MediaAttacher::MEDIA_FILE_TYPES

  def self.enabled?(conversation)
    Ryze::OutgoingEditEligibility.pilot_conversation?(conversation) && ENV['RYZE_HISTORY_SYNC_ENABLED'] != 'false'
  end

  def initialize(conversation:, before: nil, client: nil)
    @conversation = conversation
    @before = before
    @client = client || default_client
  end

  def perform
    validate_sync_prerequisites!

    cursor_time = parse_cursor(@before)
    imported_messages = []
    seen_ids = Set.new
    has_more = false
    next_before = nil

    MAX_PAGES_PER_RUN.times do
      page_result = process_page(cursor_time, seen_ids)
      break if page_result.nil?

      imported_messages.concat(page_result.imported)
      has_more = page_result.has_more
      next_before = page_result.next_before
      cursor_time = page_result.next_cursor

      break if imported_messages.any? || !has_more
    end

    build_result(imported_messages, has_more, next_before)
  end

  private

  def build_result(imported_messages, has_more, next_before)
    Result.new(
      imported_messages: imported_messages.sort_by { |m| [m.created_at, m.id] },
      has_more: has_more,
      next_before: next_before
    )
  end

  def default_client
    Ryze::Client.new(
      instance: ENV.fetch('RYZE_INSTANCE_NAME'),
      token: ENV.fetch('RYZE_EDIT_API_TOKEN'),
      read_timeout: 12,
      request_budget: 25
    )
  end

  def validate_sync_prerequisites!
    chat_jid = Ryze::OutgoingEditEligibility.conversation_jid(@conversation)
    raise ArgumentError, 'Ryze historical sync is not enabled for this conversation' unless self.class.enabled?(@conversation)
    raise ArgumentError, 'Conversation does not have a valid WhatsApp JID' if chat_jid.blank?

    @chat_jid = chat_jid
  end

  def process_page(cursor_time, seen_ids)
    raw_messages = fetch_history_page(cursor_time)
    return if raw_messages.empty?

    timestamps = raw_messages.filter_map { |item| parse_timestamp(item['timestamp']) }
    oldest_ts = timestamps.min

    imported = import_page_messages(raw_messages, seen_ids)
    should_stop = raw_messages.size < PAGE_SIZE || oldest_ts.nil? || (cursor_time && oldest_ts >= cursor_time)

    PageResult.new(
      imported: imported,
      has_more: !should_stop,
      next_before: should_stop ? nil : oldest_ts.to_i,
      next_cursor: oldest_ts
    )
  end

  def parse_cursor(before)
    return @conversation.messages.minimum(:created_at) if before.blank?
    return Time.zone.at(before.to_i) if before.is_a?(Numeric) || before.to_s.match?(/\A\d+\z/)

    Time.iso8601(before.to_s)
  rescue ArgumentError
    Time.zone.at(before.to_i)
  end

  def fetch_history_page(cursor_time)
    payload = { number: @chat_jid, count: PAGE_SIZE }
    payload[:to] = cursor_time.utc.iso8601 if cursor_time.present?

    response = @client.post('chat/history', payload)
    raise RateLimitError, "Ryze rate limit reached: #{response.code}" if response.code.to_i == 429
    raise UpstreamError, "Ryze upstream error: #{response.code}" unless response.code.to_i.between?(200, 299)

    parse_history_response(response.body)
  rescue Ryze::Client::ConnectionError => e
    raise UpstreamError, "Could not reach Ryze: #{e.message}"
  end

  def parse_history_response(body)
    data = JSON.parse(body)
    raise UpstreamError, "Ryze returned unsuccessful response: #{data['message'] || data['error']}" unless data['success'] == true

    extract_messages(data)
  rescue JSON::ParserError => e
    raise UpstreamError, "Invalid JSON from Ryze: #{e.message}"
  end

  def extract_messages(data)
    messages = data['messages'] || data['data'] || []
    messages = messages['messages'] if messages.is_a?(Hash) && messages['messages'].is_a?(Array)
    messages.is_a?(Array) ? messages : []
  end

  def import_page_messages(raw_messages, seen_ids)
    candidate_ids = raw_messages.filter_map { |item| message_id(item) }.uniq
    return [] if candidate_ids.empty?

    existing_ids = @conversation.messages.where(source_id: candidate_ids).pluck(:source_id).to_set

    imported = []
    raw_messages.each do |item|
      id = message_id(item)
      next if duplicate_or_seen?(id, seen_ids, existing_ids)

      seen_ids.add(id)
      message = persist_message(item, id)
      imported << message if message
    end

    imported
  end

  def duplicate_or_seen?(id, seen_ids, existing_ids)
    id.blank? || seen_ids.include?(id) || existing_ids.include?(id)
  end

  def persist_message(item, id)
    type = (item['type'] || item['messageType']).to_s
    return if SKIPPED_TYPES.include?(type)

    message = build_historical_message(item, id)
    MediaAttacher.new(conversation: @conversation, client: @client).attach(message, item, id, type)
    message.save!
    message
  rescue RateLimitError
    raise
  rescue StandardError => e
    Rails.logger.warn("Ryze historical message import failed for #{id}: #{e.message}")
    nil
  end

  def build_historical_message(item, id)
    timestamp = parse_timestamp(item['timestamp']) || Time.current
    from_me = item['fromMe'] == true || item['direction'] == 'outgoing'

    @conversation.messages.build(
      account: @conversation.account,
      inbox: @conversation.inbox,
      historical_import: true,
      created_at: timestamp,
      updated_at: timestamp,
      message_type: from_me ? :outgoing : :incoming,
      sender: from_me ? nil : @conversation.contact,
      status: from_me ? :delivered : :sent,
      source_id: id,
      content_attributes: build_content_attributes(timestamp, from_me),
      additional_attributes: { 'ryze_historical_sync' => true }
    )
  end

  def build_content_attributes(timestamp, from_me)
    attrs = { external_created_at: timestamp.to_i }
    attrs[:external_echo] = true if from_me
    attrs
  end

  def message_id(item)
    item['id'] || item['messageId']
  end

  def parse_timestamp(value)
    return if value.blank?

    if value.is_a?(Numeric) || value.to_s.match?(/\A\d+\z/)
      num = value.to_i
      return Time.zone.at(num / 1000.0) if num > 10_000_000_000

      return Time.zone.at(num)
    end

    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end
end
