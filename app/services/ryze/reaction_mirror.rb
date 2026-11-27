class Ryze::ReactionMirror
  BRIDGE_PLACEHOLDER = '💬 Reagiu a uma mensagem'.freeze

  def initialize(conversation:, provider_id:)
    @conversation = conversation
    @provider_id = provider_id
  end

  def receive(content:, &create_mirror)
    return @conversation.with_lock(&create_mirror) unless eligible?

    verified = verify_uncorrelated_placeholder?(content)
    @conversation.with_lock do
      next yield unless eligible? && (receipt || verified)

      yield if record! == :conflict
    end
  end

  # For explicit recovery of an existing native mirror by provider ID.
  def reconcile!
    return :unverified unless eligible? && verified_snapshot?

    @conversation.with_lock do
      result = record!
      next result unless result.in?(%i[recorded replayed])

      scoped_messages.exists?(source_id: @provider_id) ? :retained : result
    end
  end

  # Callers of record! hold the conversation lock.
  def record!(target_id: nil, emoji: nil)
    return :ignored unless eligible?

    matches = scoped_messages.where(source_id: @provider_id).reorder(nil).lock.limit(2).to_a
    return :conflict unless matches.empty? || (matches.one? && native_echo?(matches.first))

    result = record_receipt!(target_id, emoji)
    remove!(matches.first) if result != :conflict && removable?(matches.first)
    result
  end

  private

  def eligible?
    Ryze::OutboundDelivery.provider_id?(@provider_id) && Ryze::MessageReactions.pilot?(@conversation) &&
      Ryze::OutboundDelivery.bridge_user_id.present?
  end

  def provider_key(*parts)
    chat_jid = Ryze::OutgoingEditEligibility.conversation_jid(@conversation) || ENV.fetch('RYZE_PILOT_CHAT_JID', '')
    Digest::SHA256.hexdigest([ENV.fetch('RYZE_INSTANCE_NAME'), chat_jid, *parts].join("\0"))
  end

  def receipt
    Ryze::ReactionEcho.find_by(conversation: @conversation, provider_key: provider_key(@provider_id))
  end

  def verify_uncorrelated_placeholder?(content)
    # The placeholder only limits which requests need a lookup before the webhook arrives.
    content == BRIDGE_PLACEHOLDER && !receipt && verified_snapshot?
  end

  def record_receipt!(target_id, emoji)
    echo = receipt || Ryze::ReactionEcho.new(conversation: @conversation, provider_key: provider_key(@provider_id))
    reaction_key = provider_key(target_id, emoji) if target_id
    if echo.reaction_key?
      return :conflict if reaction_key && echo.reaction_key != reaction_key

      return :replayed
    end

    echo.reaction_key = reaction_key
    echo.save! if echo.changed?
    :recorded
  end

  def verified_snapshot?
    client = Ryze::Client.new(instance: ENV.fetch('RYZE_INSTANCE_NAME'), token: ENV.fetch('RYZE_EDIT_API_TOKEN'), request_budget: 2)
    response = client.get('chat/getMessage', messageId: @provider_id)
    return false unless response.code == '200'

    body = JSON.parse(response.body)
    return false unless body.is_a?(Hash) && body.values_at('success', 'status', 'messageId') == [true, 'found', @provider_id]

    outgoing_reaction?(body['data'])
  rescue Ryze::Client::ConnectionError, JSON::ParserError
    false
  end

  def outgoing_reaction?(data)
    chat = Ryze::OutgoingEditEligibility.conversation_jid(@conversation)
    data.is_a?(Hash) && chat && data.values_at('type', 'chat', 'to', 'isGroup') == ['reaction', chat, chat, false] &&
      data['from'] != chat && data['from'].is_a?(String) && data['from'].match?(Ryze::OutboundDelivery::PILOT_JID)
  end

  def scoped_messages
    @conversation.messages.where(account_id: @conversation.account_id, inbox_id: @conversation.inbox_id)
  end

  def native_echo?(message)
    Ryze::OutboundMessageCorrelation.native_mirror?(message) && message.outgoing? && message.text? && !message.private?
  end

  def removable?(message)
    message && !message.deleted && !message.attachments.exists? && !message.referenced_in_conversation?
  end

  def remove!(message)
    @conversation.notifications.where(account_id: @conversation.account_id, secondary_actor: message).destroy_all
    message.destroy!
    restore_activity!(message)
    Message.current_transaction.after_commit { broadcast_removal(message) }
  end

  def restore_activity!(message)
    return unless @conversation.last_activity_at == message.created_at

    last_activity = scoped_messages.reorder(created_at: :desc).first&.created_at || @conversation.created_at
    # Repairs the derived timestamp without creating a conversation or provider event.
    # rubocop:disable Rails/SkipsModelValidations
    @conversation.update_columns(last_activity_at: last_activity, updated_at: Time.current)
    # rubocop:enable Rails/SkipsModelValidations
  end

  def broadcast_removal(message)
    @conversation.reload
    preview = scoped_messages.non_activity_messages.first&.push_event_data
    data = { id: message.id, conversation_id: @conversation.display_id, echo_created_at: message.created_at.to_i,
             last_non_activity_message: preview, last_activity_at: @conversation.last_activity_at.to_i }
    Rails.configuration.dispatcher.sync_dispatcher.dispatch('message.ryze_reaction_echo_removed', Time.current,
                                                            { conversation: @conversation, payload: data })
  end
end
