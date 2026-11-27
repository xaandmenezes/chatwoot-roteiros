module ActionCableListener::ConversationBroadcasts
  include Events::Types

  def conversation_whatsapp_group_classification_changed(event)
    broadcast_whatsapp_group_classification_changed(event.data.fetch(:inbox))
  end

  private

  def broadcast_contact_group_classification_changed(contact)
    inbox = Ryze::GroupConversations.inbox_for_contact_change(contact)
    broadcast_whatsapp_group_classification_changed(inbox) if inbox
  end

  def broadcast_whatsapp_group_classification_changed(inbox)
    account = inbox.account
    broadcast(account, user_tokens(account, inbox.members), CONVERSATION_WHATSAPP_GROUP_CLASSIFICATION_CHANGED, { inbox_id: inbox.id })
  end

  def broadcast_to_inbox_members(event, event_name, **metadata)
    conversation, account = extract_conversation_and_account(event)

    broadcast(account, user_tokens(account, conversation.inbox.members), event_name, conversation.push_event_data.merge(metadata))
  end

  def add_contact_labels(data, account, conversation)
    data.merge(contact_labels: Conversations::ContactLabels.for_conversation(account, conversation))
  end

  def broadcast_conversation_event(conversation, event_name)
    widget_tokens, client_tokens = split_contact_tokens(session_contact_inboxes(conversation.contact_inbox))
    # The web widget has no handler for conversation.updated
    widget_tokens = [] if event_name == CONVERSATION_UPDATED

    account = conversation.account
    tokens = inbox_user_tokens(conversation)
    data = conversation.push_event_data
    if tokens.present? && (event_name == CONVERSATION_CREATED || data.key?(:whatsapp_group))
      # Contact labels and group classification belong to the dashboard payload.
      broadcast(account, client_tokens, event_name, data.except(:whatsapp_group))
      data = add_contact_labels(data, account, conversation) if event_name == CONVERSATION_CREATED
    else
      tokens += client_tokens
      data = data.except(:whatsapp_group) if data.key?(:whatsapp_group)
    end

    broadcast(account, tokens, event_name, data, widget: { tokens: widget_tokens, data: conversation.widget_push_event_data })
  end
end
