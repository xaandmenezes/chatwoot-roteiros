module ActionCableListener::ConversationBroadcasts
  include Events::Types

  private

  def broadcast_to_inbox_members(event, event_name, **metadata)
    conversation, account = extract_conversation_and_account(event)

    broadcast(account, user_tokens(account, conversation.inbox.members), event_name, conversation.push_event_data.merge(metadata))
  end

  def broadcast_conversation_event(conversation, event_name)
    widget_tokens, client_tokens = split_contact_tokens(session_contact_inboxes(conversation.contact_inbox))
    # The web widget has no handler for conversation.updated
    widget_tokens = [] if event_name == CONVERSATION_UPDATED

    account = conversation.account
    tokens = inbox_user_tokens(conversation)
    data = conversation.push_event_data
    if event_name == CONVERSATION_CREATED && tokens.present?
      # Customer-facing Client API and widget payloads do not include contact labels.
      broadcast(account, client_tokens, event_name, data)
      data = data.merge(contact_labels: Conversations::ContactLabels.for_conversation(account, conversation))
    else
      tokens += client_tokens
    end

    broadcast(account, tokens, event_name, data, widget: { tokens: widget_tokens, data: conversation.widget_push_event_data })
  end
end
