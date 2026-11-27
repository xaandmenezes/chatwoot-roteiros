module ActionCableListener::MessageBroadcasts
  private

  def broadcast_message_event(message, event_name, **extra)
    conversation = message.conversation
    widget_tokens, client_tokens = split_contact_tokens(message_contact_inboxes(conversation, message))
    customer_tokens = client_tokens
    data = message.push_event_data
    agent_tokens = message_agent_tokens(message, conversation)
    if Ryze::GroupConversations.group?(conversation)
      broadcast(conversation.account, agent_tokens, event_name, whatsapp_group_message_data(message, data, extra), conversation: conversation)
    elsif message.deleted_by_customer?
      # Only agents receive the retained body. previous_changes can also contain that body.
      broadcast(conversation.account, agent_tokens, event_name, message.agent_view_data(data), conversation: conversation)
    elsif Ryze::OutgoingEditEligibility.pilot_conversation?(conversation)
      data.merge!(extra)
      broadcast(conversation.account, agent_tokens, event_name, message.agent_view_data(data, conversation: conversation), conversation: conversation)
    else
      client_tokens = agent_tokens + client_tokens
      data.merge!(extra)
    end

    broadcast(conversation.account, client_tokens, event_name, data,
              conversation: conversation, contact_tokens: customer_tokens,
              widget: { tokens: widget_tokens, data: message.widget_push_event_data(data) })
  end

  def whatsapp_group_message_data(message, data, extra)
    deleted_by_customer = message.deleted_by_customer?
    data.merge!(extra) unless deleted_by_customer
    group_data = data.merge(conversation: data[:conversation].merge(whatsapp_group: true))
    deleted_by_customer ? message.agent_view_data(group_data) : group_data
  end

  def message_agent_tokens(message, conversation)
    tokens = inbox_user_tokens(conversation)
    return tokens unless message.suppress_ryze_bridge_event?

    bridge_token = conversation.account.users.where(id: Ryze::OutboundDelivery.bridge_user_id).pick(:pubsub_token)
    tokens - [bridge_token]
  end
end
