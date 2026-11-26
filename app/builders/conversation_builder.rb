class ConversationBuilder
  pattr_initialize [:params!, :contact_inbox!]

  SERVER_MANAGED_ADDITIONAL_ATTRIBUTES = %w[auto_reply captain_waiting_resolved_at].freeze
  CHANNEL_MANAGED_ADDITIONAL_ATTRIBUTES = {
    'Channel::Telegram' => %w[chat_id business_connection_id].freeze,
    'Channel::Tiktok' => %w[conversation_id tiktok_capabilities].freeze,
    'Channel::Whatsapp' => %w[call_permission_requests call_permission_requested_at call_permission_request_message_id].freeze
  }.freeze

  def perform
    look_up_exising_conversation || create_new_conversation
  end

  private

  def look_up_exising_conversation
    return unless @contact_inbox.inbox.lock_to_single_conversation?

    @contact_inbox.conversations.last
  end

  def create_new_conversation
    ::Conversation.create!(conversation_params)
  end

  def conversation_params
    custom_attributes = params[:custom_attributes]&.permit! || {}
    status = params[:status].present? ? { status: params[:status] } : {}

    # TODO: temporary fallback for the old bot status in conversation, we will remove after couple of releases
    # commenting this out to see if there are any errors, if not we can remove this in subsequent releases
    # status = { status: 'pending' } if status[:status] == 'bot'
    {
      account_id: @contact_inbox.inbox.account_id,
      inbox_id: @contact_inbox.inbox_id,
      contact_id: @contact_inbox.contact_id,
      contact_inbox_id: @contact_inbox.id,
      additional_attributes: additional_attributes,
      custom_attributes: custom_attributes,
      snoozed_until: params[:snoozed_until],
      assignee_id: params[:assignee_id],
      team_id: params[:team_id]
    }.merge(status)
  end

  def additional_attributes
    return {} unless params.key?(:additional_attributes)

    attributes = params.slice(:additional_attributes).permit(additional_attributes: {})[:additional_attributes]
    channel_attributes = CHANNEL_MANAGED_ADDITIONAL_ATTRIBUTES.fetch(@contact_inbox.inbox.channel_type, [])
    attributes.to_h.except(*SERVER_MANAGED_ADDITIONAL_ATTRIBUTES, *channel_attributes)
  end
end
