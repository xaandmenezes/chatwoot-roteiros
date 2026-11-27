class Ryze::HistoricalSync
  class UpstreamError < StandardError; end
  class RateLimitError < UpstreamError; end
  class InvalidCursor < ArgumentError; end
  class NotEnabled < ArgumentError; end

  Result = Struct.new(:imported_messages, :has_more, :next_before, keyword_init: true)
  PageResult = Struct.new(:imported, :has_more, :next_before, :next_cursor, keyword_init: true)

  PAGE_SIZE = 50
  MAX_PAGES_PER_RUN = 3
  RUN_BUDGET = 20.seconds
  SKIPPED_TYPES = %w[reaction message_edit message_revoke protocol_message].freeze

  def self.enabled?(conversation)
    return false if ENV['RYZE_HISTORY_SYNC_ENABLED'] == 'false' || !Ryze::OutgoingEditEligibility.pilot_conversation?(conversation)

    !Ryze::OutgoingEditEligibility.direct_inbox_enabled? || Ryze::HistoryBinding.verified?(conversation)
  end

  def initialize(conversation:, before: nil, client: nil, actor: nil)
    @conversation = conversation
    @before = before
    @provided_client = client
    @actor = actor
  end

  def perform
    @session = Session.new(@conversation, client: @provided_client, actor: @actor)
    cursor_time = parse_cursor(@before)
    @window = ConversationWindow.new(@conversation)
    return Result.new(imported_messages: [], has_more: false) if @window.starts_at && cursor_time && cursor_time < @window.starts_at

    @session.media.repair_pending
    import_history(cursor_time)
  end

  private

  def import_history(cursor_time)
    seen_ids = Set.new
    page = nil

    MAX_PAGES_PER_RUN.times do
      page = process_page(cursor_time, seen_ids)
      break if page.imported.any? || !page.has_more || Time.current >= @session.deadline

      cursor_time = page.next_cursor
    end

    messages = page.imported.sort_by { |message| [message.created_at, message.id] }
    Result.new(imported_messages: messages, has_more: page.has_more, next_before: page.next_before)
  end

  def process_page(cursor_time, seen_ids)
    raw_messages = fetch_eligible_history_page(cursor_time)
    result = pagination(raw_messages, cursor_time)
    unseen_items(raw_messages, seen_ids).each do |item|
      # Replay this page rather than advancing past rows not yet persisted.
      return interrupted_page(result.imported, cursor_time, raw_messages) if Time.current >= @session.deadline

      message = persist_message(item, message_id(item))
      result.imported << message if message
    end
    result
  end

  def pagination(items, cursor_time)
    oldest = items.filter_map { |item| parse_timestamp(item['timestamp']) }.min
    has_more = items.size == PAGE_SIZE && oldest.present? && (!cursor_time || oldest < cursor_time)
    PageResult.new(imported: [], has_more: has_more, next_before: has_more ? oldest.to_i : nil, next_cursor: oldest)
  end

  def interrupted_page(imported, cursor_time, items)
    newest = items.filter_map { |item| parse_timestamp(item['timestamp']) }.max || Time.current
    retry_before = cursor_time || (newest + 1.second)
    PageResult.new(imported: imported, has_more: true, next_before: retry_before.to_f.ceil, next_cursor: retry_before)
  end

  def parse_cursor(before)
    return @conversation.messages.minimum(:created_at) if before.nil?
    return Time.zone.at(before.to_i) if (before.is_a?(Integer) || before.is_a?(String)) && before.to_s.match?(/\A\d{1,10}\z/)
    raise InvalidCursor unless before.is_a?(String)

    Time.iso8601(before)
  rescue ArgumentError
    raise InvalidCursor, 'Invalid history cursor'
  end

  def fetch_eligible_history_page(cursor_time)
    messages = fetch_history_page(cursor_time)
    raise UpstreamError, 'Ryze history page exceeds requested size' if messages.size > PAGE_SIZE
    return messages unless @window.bounded?

    messages.select { |item| @window.include?(parse_timestamp(item['timestamp'])) }
  end

  def fetch_history_page(cursor_time)
    raise UpstreamError, 'Ryze history deadline reached' if Time.current >= @session.deadline

    payload = { number: @session.chat_jid, count: PAGE_SIZE }.merge(@window.query(cursor_time))

    response = @session.client.post('chat/history', payload)
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

  def unseen_items(raw_messages, seen_ids)
    candidates = raw_messages.select do |item|
      id = message_id(item)
      id.present? && seen_ids.add?(id)
    end
    ids = candidates.map { |item| message_id(item) }
    existing_ids = @conversation.messages.where(source_id: ids).pluck(:source_id).to_set
    candidates.reject { |item| existing_ids.include?(message_id(item)) }
  end

  def persist_message(item, id)
    type = (item['type'] || item['messageType']).to_s
    return if SKIPPED_TYPES.include?(type)

    @session.media.with_download(item, id, type) do |blob|
      @session.with_current_target do
        next if @conversation.messages.exists?(source_id: id)

        message = build_historical_message(item, id)
        @session.media.assign(message, item, type, blob)
        message.save!
        message
      end
    end
  rescue ActiveRecord::RecordInvalid => e
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
