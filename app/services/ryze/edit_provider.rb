class Ryze::EditProvider
  def initialize
    @client = Ryze::Client.new(instance: ENV.fetch('RYZE_INSTANCE_NAME'), token: ENV.fetch('RYZE_EDIT_API_TOKEN'))
  end

  def text(source_id)
    status = lookup('chat/status', source_id)
    return :edit_failed unless status
    return :edit_unavailable unless remote_status_matches?(status, source_id)

    snapshot = lookup('chat/getMessage', source_id)
    return :edit_failed unless snapshot
    return :edit_unavailable unless remote_text_snapshot_matches?(snapshot, source_id)

    snapshot.dig('data', 'content')
  rescue Ryze::Client::ConnectionError
    :edit_failed
  end

  def request_edit(source_id, content)
    response = @client.post('chat/edit', messageId: source_id, content: content)
    data = response_json(response)
    return :edit_expired if response.code == '400' && expired_error?(data)
    return :edit_failed if %w[400 401 403 404 429 503].include?(response.code)

    :pending
  rescue Ryze::Client::ConnectionError
    :pending
  end

  private

  def lookup(path, source_id)
    response = @client.get(path, messageId: source_id)
    return unless response.is_a?(Net::HTTPOK)

    data = response_json(response)
    data if data['success'] == true
  end

  def remote_text_snapshot_matches?(snapshot, source_id)
    data = snapshot['data']
    snapshot['messageId'] == source_id && data.is_a?(Hash) && data['type'] == 'text' && data['content'].is_a?(String)
  end

  def remote_status_matches?(status, source_id)
    status['message_id'] == source_id && status['chat_jid'] == ENV.fetch('RYZE_PILOT_CHAT_JID') &&
      status['direction'] == 'sent' && Ryze::OutgoingEditEligibility::EDITABLE_STATUSES.include?(status['status'])
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
end
