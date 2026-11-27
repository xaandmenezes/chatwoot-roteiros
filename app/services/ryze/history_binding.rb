require 'openssl'

class Ryze::HistoryBinding
  KEY = 'ryze_history_binding'.freeze
  IDENTITY_FIELDS = %w[account_id inbox_id contact_id contact_inbox_id id display_id uuid].freeze

  def self.direct_inbox?(inbox)
    Ryze::OutgoingEditEligibility.direct_inbox_enabled? && inbox.id.to_s == ENV['RYZE_INBOX_ID'] && inbox.api?
  end

  def self.verified?(conversation)
    token = conversation.additional_attributes[KEY]
    secret = ENV['RYZE_HISTORY_BINDING_SECRET'].presence
    return false unless secret && token.is_a?(String)

    jid = Ryze::OutgoingEditEligibility.conversation_jid(conversation)
    ActiveSupport::SecurityUtils.secure_compare(token, signature(conversation, jid, secret))
  end

  # Operators must verify the conversation and JID independently, not copy a legacy attribute.
  def self.bind!(conversation, jid)
    raise ArgumentError, 'Expected a direct WhatsApp JID' unless Ryze::OutgoingEditEligibility::DIRECT_JID.match?(jid)

    secret = ENV['RYZE_HISTORY_BINDING_SECRET'].presence
    raise ArgumentError, 'Missing RYZE_HISTORY_BINDING_SECRET' unless secret

    conversation.with_lock do
      raise ArgumentError, 'Not the configured direct API inbox' unless direct_inbox?(conversation.inbox)

      attributes = conversation.additional_attributes
      if attributes['whatsapp_jid'].present? && attributes['whatsapp_jid'] != jid
        raise ArgumentError, 'Conversation already points to a different JID'
      end

      token = signature(conversation, jid, secret)
      conversation.update!(additional_attributes: attributes.merge('whatsapp_jid' => jid, KEY => token))
    end
  end

  def self.signature(conversation, jid, secret)
    identity = IDENTITY_FIELDS.map { |field| conversation[field] }
    data = JSON.generate(['ryze-history/v1', ENV.fetch('RYZE_INSTANCE_NAME'), jid, *identity])
    OpenSSL::HMAC.hexdigest('SHA256', secret, data)
  end
  private_class_method :signature
end
