class Ryze::ReactionEvent
  DIRECTIONS = %w[incoming outgoing].freeze
  DEVICE_JID = /\A(\d{8,20}):\d{1,5}@(s\.whatsapp\.net|lid)\z/

  attr_reader :id, :direction, :target_id, :emoji, :timestamp, :source, :author

  def initialize(data)
    reaction = object(data[:message][:reaction])
    target = object(reaction[:targetMessageId])
    @id = data[:id]
    @direction = data[:direction]
    @timestamp = parse_timestamp(data[:timestamp])
    @target_id = key_value(target, :ID, :id)
    @target_chat = direct_id(key_value(target, :remoteJID, :remoteJid))
    @emoji = reaction[:emoji]
    @source = data[:message][:source]
    extract_identities(object(data[:chat]), object(data[:sender]))
  end

  def in_pilot?(jid)
    @private_chat && @chat_ids.include?(jid)
  end

  def validation_error
    return :event_metadata unless timestamp && DIRECTIONS.include?(direction) && Ryze::OutboundDelivery.provider_id?(id)
    return :target_key unless valid_target?
    return :sender unless valid_sender?
    return :emoji unless Ryze::MessageReactions.valid_emoji?(emoji)

    nil
  end

  def attributes
    { 'id' => id, 'emoji' => emoji, 'at' => timestamp.utc.iso8601(9), 'author' => author }
  end

  private

  def extract_identities(chat, sender)
    @private_chat = chat[:type] == 'private'
    @chat_ids = direct_ids(chat)
    @sender_ids = direct_ids(sender)
    @author = sender[:name].slice(0, 128).presence if sender[:name].is_a?(String)
  end

  def parse_timestamp(value)
    Time.iso8601(value) if value.is_a?(String)
  rescue ArgumentError
    nil
  end

  def valid_sender?
    @sender_ids.present? && @sender_ids.intersect?(@chat_ids) == (direction == 'incoming')
  end

  def valid_target?
    Ryze::OutboundDelivery.provider_id?(target_id) && id != target_id && @chat_ids.include?(@target_chat)
  end

  def direct_ids(identity)
    identity.values_at(:jid, :lid).filter_map { |value| direct_id(value) }
  end

  def direct_id(value)
    return unless value.is_a?(String)
    return value if value.match?(Ryze::OutboundDelivery::PILOT_JID)

    device_jid = DEVICE_JID.match(value)
    "#{device_jid[1]}@#{device_jid[2]}" if device_jid
  end

  def key_value(key, *aliases)
    values = key.values_at(*aliases.select { |name| key.key?(name) }).uniq
    values.first if values.one?
  end

  def object(value)
    value.is_a?(ActionController::Parameters) ? value : {}
  end
end
