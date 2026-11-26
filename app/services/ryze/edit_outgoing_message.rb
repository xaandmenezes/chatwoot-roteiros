class Ryze::EditOutgoingMessage
  MAX_CONTENT_LENGTH = 150_000

  def initialize(message:, conversation:, content:)
    @message = message
    @conversation = conversation
    @content = content
    @eligibility = Ryze::OutgoingEditEligibility.new(message, conversation: conversation)
    @claim = Ryze::EditClaim.new(message.id)
  end

  def perform
    return :invalid_content unless valid_content?
    return :edit_unavailable unless @eligibility.permitted? && @conversation.can_reply?
    return :edit_expired if @eligibility.expired?
    return :edit_pending unless @claim.acquire(@content)

    perform_claimed
  end

  private

  def perform_claimed
    outcome = edit_at_provider
  ensure
    @claim.release if outcome && outcome != :pending
  end

  def edit_at_provider
    source_id = @message.source_id
    revision = previous_revision
    original_content = @message.content
    remote_content = revision.present? ? original_content : Messages::WebhookContentNormalizer.normalize(original_content)
    preflight = verify_remote_message(source_id, remote_content)
    return preflight if preflight
    return :edit_unavailable unless latest_message_available?(source_id, revision, original_content)
    return :edit_expired if @eligibility.expired?

    outcome = request_edit(source_id)
    return :confirmed if edit_confirmed?(source_id, revision)

    outcome
  end

  def verify_remote_message(source_id, current_content)
    status = lookup('chat/status', source_id)
    return :edit_failed unless status
    return :edit_unavailable unless remote_status_matches?(status, source_id)

    snapshot = lookup('chat/getMessage', source_id)
    return :edit_failed unless snapshot
    return :edit_unavailable unless remote_text_snapshot_matches?(snapshot, source_id)
    return :edit_pending unless snapshot.dig('data', 'content') == current_content

    nil
  rescue Ryze::Client::ConnectionError
    :edit_failed
  end

  def lookup(path, source_id)
    response = client.get(path, messageId: source_id)
    return unless response.is_a?(Net::HTTPOK)

    data = response_json(response)
    data if data['success'] == true
  end

  def remote_text_snapshot_matches?(snapshot, source_id)
    snapshot['messageId'] == source_id && snapshot['data'].is_a?(Hash) && snapshot.dig('data', 'type') == 'text'
  end

  def remote_status_matches?(status, source_id)
    status['message_id'] == source_id && status['chat_jid'] == pilot_chat_id &&
      status['direction'] == 'sent' && Ryze::OutgoingEditEligibility::EDITABLE_STATUSES.include?(status['status'])
  end

  def request_edit(source_id)
    response = client.post('chat/edit', messageId: source_id, content: @content)
    data = response_json(response)
    return :edit_expired if response.code == '400' && expired_error?(data)

    # Transport and unexpected responses leave the command outcome uncertain.
    # Only the signed webhook can confirm that the revision was applied.
    return :edit_failed if %w[400 401 403 404 429 503].include?(response.code)

    :pending
  rescue Ryze::Client::ConnectionError
    :pending
  end

  def response_json(response)
    data = JSON.parse(response.body)
    data.is_a?(Hash) ? data : {}
  rescue JSON::ParserError, TypeError
    {}
  end

  def expired_error?(data)
    data['error'].is_a?(Hash) && data.dig('error', 'message').to_s.include?('too old to edit')
  end

  def latest_message_available?(source_id, revision, original_content)
    @message.reload
    @message.source_id == source_id && previous_revision == revision && @message.content == original_content && @eligibility.permitted?
  end

  def edit_confirmed?(source_id, revision)
    @message.reload
    @message.source_id == source_id && @message.content == @content &&
      previous_revision.present? && previous_revision != revision && !@message.deleted
  end

  def previous_revision
    @message.additional_attributes&.fetch('ryze_edited_at', nil)
  end

  def valid_content?
    @content.is_a?(String) && @content.present? && @content.length <= MAX_CONTENT_LENGTH && @content != @message.content
  end

  def pilot_chat_id
    ENV.fetch('RYZE_PILOT_CHAT_JID')
  end

  def client
    @client ||= Ryze::Client.new(instance: ENV.fetch('RYZE_INSTANCE_NAME'), token: ENV.fetch('RYZE_EDIT_API_TOKEN'))
  end
end
