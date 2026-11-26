class Ryze::ReactionEvent
  DIRECTIONS = %w[incoming outgoing].freeze

  attr_reader :id, :direction, :target_id, :emoji, :timestamp, :source, :author

  def initialize(data)
    reaction = object(data[:message][:reaction])
    target = object(reaction[:targetMessageId])
    @id = data[:id]
    @direction = data[:direction]
    @timestamp = parse_timestamp(data[:timestamp])
    @target_id = target[:ID]
    @target_chat = target[:remoteJID]
    @emoji = reaction[:emoji]
    @source = data[:message][:source]
    extract_identities(object(data[:chat]), object(data[:sender]))
  end

  def in_pilot?(jid)
    @private_chat && @chat_ids.include?(jid)
  end

  def valid?
    timestamp.present? && DIRECTIONS.include?(direction) && valid_identifiers? && Ryze::MessageReactions.valid_emoji?(emoji)
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

  def valid_identifiers?
    Ryze::OutboundDelivery.provider_id?(id) && Ryze::OutboundDelivery.provider_id?(target_id) && id != target_id &&
      @chat_ids.include?(@target_chat) && @sender_ids.present? &&
      @sender_ids.intersect?(@chat_ids) == (direction == 'incoming')
  end

  def direct_ids(identity)
    identity.values_at(:jid, :lid).select { |jid| jid.is_a?(String) && jid.match?(Ryze::OutboundDelivery::PILOT_JID) }
  end

  def object(value)
    value.is_a?(ActionController::Parameters) ? value : {}
  end
end
