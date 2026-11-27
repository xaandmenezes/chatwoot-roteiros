class Ryze::OutgoingEditEligibility
  EDIT_WINDOW = 15.minutes
  EDITABLE_STATUSES = %w[sent delivered read].freeze
  DIRECT_JID = /\A\d{8,20}@(s\.whatsapp\.net|lid)\z/
  BASE_CONFIG_KEYS = %w[RYZE_WEBHOOK_SECRET RYZE_INSTANCE_NAME RYZE_EDIT_API_TOKEN RYZE_INBOX_ID].freeze
  PILOT_CONFIG_KEYS = %w[RYZE_PILOT_CHAT_JID RYZE_EDIT_CONVERSATION_ID].freeze
  CONFIG_KEYS = (BASE_CONFIG_KEYS + PILOT_CONFIG_KEYS).freeze

  def self.direct_inbox_enabled?
    ENV['RYZE_DIRECT_INBOX_ENABLED'] == 'true'
  end

  def self.conversation_jid(conversation)
    jid = conversation&.additional_attributes&.fetch('whatsapp_jid', nil)
    jid if jid.is_a?(String) && jid.match?(DIRECT_JID)
  end

  def self.matching_direct_conversation(inbox, chat_ids)
    direct_ids = Array(chat_ids).select { |id| id.is_a?(String) && id.match?(DIRECT_JID) }
    return if direct_ids.empty?

    jid_attr = Arel::Nodes::InfixOperation.new('->>', Conversation.arel_table[:additional_attributes], Arel::Nodes.build_quoted('whatsapp_jid'))
    matches = inbox.conversations.where(account_id: inbox.account_id).where(jid_attr.in(direct_ids)).limit(2).to_a
    raise ActiveRecord::SoleRecordExceeded if matches.many?

    conversation = matches.first
    conversation if conversation && pilot_conversation?(conversation)
  end

  def self.pilot_conversation?(conversation)
    jid = conversation_jid(conversation)
    return false unless configured? && jid && eligible_api_conversation?(conversation)
    return true if direct_inbox_enabled?

    conversation.display_id == Integer(ENV.fetch('RYZE_EDIT_CONVERSATION_ID'), 10, exception: false) &&
      jid == ENV.fetch('RYZE_PILOT_CHAT_JID')
  end

  def self.eligible_api_conversation?(conversation)
    conversation.inbox_id == Integer(ENV.fetch('RYZE_INBOX_ID'), 10, exception: false) && conversation.inbox&.api?
  end

  def self.configured?
    keys = direct_inbox_enabled? ? BASE_CONFIG_KEYS : CONFIG_KEYS
    keys.all? { |key| ENV.fetch(key, nil).present? }
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
