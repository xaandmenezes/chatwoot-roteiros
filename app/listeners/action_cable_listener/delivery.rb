module ActionCableListener::Delivery
  private

  # widget: { tokens:, data: } sends web widget sessions their payload in the same job
  def broadcast(account, tokens, event_name, data, **audiences)
    widget = audiences.fetch(:widget, {})
    conversation = audiences[:conversation]
    contact_tokens = audiences[:contact_tokens]
    widget_tokens = widget[:tokens].to_a
    return if tokens.blank? && widget_tokens.blank?

    widget_options = {}
    widget_options = { widget_members: widget_tokens.uniq, widget_data: broadcast_payload(account, widget[:data]) } if widget_tokens.present?
    if conversation && conversation.inbox_id == Conversations::AssignmentAccess.inbox_id
      widget_options[:restricted_conversation_id] = conversation.id
      widget_options[:contact_tokens] = contact_tokens if contact_tokens.present?
    end
    ::ActionCableBroadcastJob.perform_later(tokens.uniq, event_name, broadcast_payload(account, data), **widget_options)
  end

  def broadcast_payload(account, data)
    payload = data.merge(account_id: account.id)
    # So the frondend knows who performed the action.
    # Useful in cases like conversation assignment for generating a notification with assigner name.
    payload[:performer] = Current.user&.push_event_data if Current.user.present?
    payload
  end
end
