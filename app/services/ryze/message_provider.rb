class Ryze::MessageProvider
  def initialize
    @client = Ryze::Client.new(instance: ENV.fetch('RYZE_INSTANCE_NAME'), token: ENV.fetch('RYZE_EDIT_API_TOKEN'))
  end

  def text(source_id, chat_jid: nil)
    return :edit_unavailable unless delivered_to_pilot?(source_id, chat_jid: chat_jid)

    snapshot = lookup('chat/getMessage', source_id)
    return :edit_failed unless snapshot
    return :edit_unavailable unless remote_text_snapshot_matches?(snapshot, source_id)

    snapshot.dig('data', 'content')
  rescue Ryze::Client::ConnectionError
    :edit_failed
  end

  def delivered_to_pilot?(source_id, chat_jid: nil)
    status = lookup('chat/status', source_id)
    raise Ryze::Client::ConnectionError unless status

    remote_status_matches?(status, source_id, expected_chat_jid(chat_jid))
  end

  def request_delete(source_id, chat_jid: nil)
    response = @client.delete('chat/delete', messageId: source_id, deleteForEveryone: true)
    data = response_json(response)
    return revoke_result(data, source_id, expected_chat_jid(chat_jid)) if response.code == '200'
    return :delete_failed if %w[400 401 403 404 422 429].include?(response.code)
    return :delete_failed if response.code == '503' && disconnected?(data)

    :pending
  rescue Ryze::Client::ConnectionError
    :pending
  end

  def original_absent?(source_id)
    response = @client.get('chat/getMessage', messageId: source_id)
    return false unless response.code == '404'

    data = response_json(response)
    data['success'] == false && data['error'].is_a?(Hash) && ['Mensagem não encontrada', 'Message not found'].include?(data.dig('error', 'message'))
  rescue Ryze::Client::ConnectionError
    false
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

  def revoke_result(data, source_id, chat_jid)
    return :pending unless revoke_acknowledged?(data, chat_jid)
    return :confirmed if data['message_id'] == source_id || original_absent?(source_id)

    :readback_pending
  end

  def revoke_acknowledged?(data, chat_jid)
    data['success'] == true && data['message_id'].is_a?(String) && data['message_id'].present? &&
      data['chat_jid'] == chat_jid && data['delete_type'] == 'revoke' && data['deleted_for_everyone'] == true
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

  def remote_status_matches?(status, source_id, chat_jid)
    status['message_id'] == source_id && status['chat_jid'] == chat_jid &&
      status['direction'] == 'sent' && Ryze::OutgoingEditEligibility::EDITABLE_STATUSES.include?(status['status'])
  end

  def expected_chat_jid(chat_jid)
    chat_jid.presence || ENV.fetch('RYZE_PILOT_CHAT_JID', nil)
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
