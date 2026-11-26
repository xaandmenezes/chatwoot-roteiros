class Ryze::MessageProvider
  def initialize
    @client = Ryze::Client.new(instance: ENV.fetch('RYZE_INSTANCE_NAME'), token: ENV.fetch('RYZE_EDIT_API_TOKEN'))
  end

  def text(source_id)
    return :edit_unavailable unless delivered_to_pilot?(source_id)

    snapshot = lookup('chat/getMessage', source_id)
    return :edit_failed unless snapshot
    return :edit_unavailable unless remote_text_snapshot_matches?(snapshot, source_id)

    snapshot.dig('data', 'content')
  rescue Ryze::Client::ConnectionError
    :edit_failed
  end

  def delivered_to_pilot?(source_id)
    status = lookup('chat/status', source_id)
    raise Ryze::Client::ConnectionError unless status

    remote_status_matches?(status, source_id)
  end

  def request_delete(source_id)
    response = @client.delete('chat/delete', messageId: source_id, deleteForEveryone: true)
    data = response_json(response)
    return :confirmed if response.code == '200' && confirmed_revoke?(data, source_id)
    return :delete_failed if %w[400 401 403 404 422 429].include?(response.code)
    return :delete_failed if response.code == '503' && disconnected?(data)

    :pending
  rescue Ryze::Client::ConnectionError
    :pending
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

  def disconnected?(data)
    return false unless data['success'] == false

    data['status'] == 'disconnected' || (data['error'].is_a?(Hash) && data.dig('error', 'message') == 'Instance is not connected to WhatsApp')
  end

  def confirmed_revoke?(data, source_id)
    data['success'] == true && data['message_id'] == source_id && data['chat_jid'] == ENV.fetch('RYZE_PILOT_CHAT_JID') &&
      data['delete_type'] == 'revoke' && data['deleted_for_everyone'] == true
  end

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
