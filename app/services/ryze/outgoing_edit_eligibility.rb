class Ryze::OutgoingEditEligibility
  EDIT_WINDOW = 15.minutes
  EDITABLE_STATUSES = %w[sent delivered read].freeze
  DIRECT_JID = /\A\d{8,20}@(s\.whatsapp\.net|lid)\z/
  CONFIG_KEYS = %w[RYZE_WEBHOOK_SECRET RYZE_INSTANCE_NAME RYZE_EDIT_API_TOKEN RYZE_INBOX_ID RYZE_PILOT_CHAT_JID RYZE_EDIT_CONVERSATION_ID].freeze

  def self.pilot_conversation?(conversation)
    return false unless configured?

    jid = ENV.fetch('RYZE_PILOT_CHAT_JID')
    return false unless jid.match?(DIRECT_JID)

    conversation.inbox_id == Integer(ENV.fetch('RYZE_INBOX_ID'), 10, exception: false) &&
      conversation.display_id == Integer(ENV.fetch('RYZE_EDIT_CONVERSATION_ID'), 10, exception: false) &&
      conversation.additional_attributes&.fetch('whatsapp_jid', nil) == jid &&
      conversation.inbox.api?
  end

  def self.configured?
    CONFIG_KEYS.all? { |key| ENV.fetch(key, nil).present? }
  end
  private_class_method :configured?

  def initialize(message, conversation: nil)
    @message = message
    @conversation = conversation
  end

  def permitted?
    return false unless eligible_message? && scoped_conversation?

    @message.attachments.empty?
  end

  def expired?
    @message.created_at <= EDIT_WINDOW.ago
  end

  private

  def eligible_message?
    public_team_text? && !@message.deleted && EDITABLE_STATUSES.include?(@message.status) && @message.content.present? && verified_source_id?
  end

  def public_team_text?
    @message.outgoing? && @message.text? && @message.sender_type == 'User' && !@message.private? && !@message.forwarded?
  end

  def verified_source_id?
    attributes = @message.additional_attributes
    @message.source_id.present? && attributes&.fetch(Ryze::OutboundDelivery::VERIFIED_ID_KEY, nil) == @message.source_id &&
      attributes.dig(Ryze::OutboundDelivery::DELIVERY_KEY, 'state') == 'confirmed'
  end

  def scoped_conversation?
    return false unless @message.inbox_id == Integer(ENV.fetch('RYZE_INBOX_ID', ''), 10, exception: false)

    conversation = @conversation || @message.conversation
    conversation.account_id == @message.account_id && conversation.inbox_id == @message.inbox_id &&
      Ryze::OutboundDelivery.configured_for?(@message, conversation: conversation)
  end
end
