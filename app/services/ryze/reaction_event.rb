class Ryze::ReactionEvent
  DIRECTIONS = %w[incoming outgoing].freeze
  DEVICE_JID = /\A(\d{8,20}):\d{1,5}@(s\.whatsapp\.net|lid)\z/
  TARGET_ID_KEYS = %w[id messageid message_id].freeze
  TARGET_CHAT_KEYS = %w[remotejid remote_jid chatjid chat_jid jid].freeze
  TARGET_KEYS = (TARGET_ID_KEYS + TARGET_CHAT_KEYS).freeze

  attr_reader :id, :direction, :target_id, :emoji, :timestamp, :source, :author

  def initialize(data)
    reaction = object(data[:message][:reaction])
    @target = reaction[:targetMessageId]
    @target_details = parse_target(@target)
    @id = data[:id]
    @direction = data[:direction]
    @timestamp = parse_timestamp(data[:timestamp])
    @target_id = @target_details[:id]
    @emoji = reaction[:emoji]
    @source = data[:message][:source]
    extract_identities(object(data[:chat]), object(data[:sender]))
  end

  def in_pilot?(jid)
    @private_chat && @chat_ids.include?(jid)
  end

  def validation_error
    return :event_metadata unless valid_metadata?

    error = target_error
    return error if error
    return :sender unless valid_sender?

    :emoji unless Ryze::MessageReactions.valid_emoji?(emoji)
  end

  def attributes
    { 'id' => id, 'emoji' => emoji, 'at' => timestamp.utc.iso8601(9), 'author' => author }
  end

  # Fixed categories only: the values are phone numbers and provider ids.
  def target_shape
    return 'absent' if @target.nil?
    return 'bare_id' if @target.is_a?(String)
    return 'invalid' unless @target.is_a?(ActionController::Parameters)

    categories = target_categories
    categories.any? ? "object:#{categories.join(',')}" : 'object:empty'
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

  def valid_metadata?
    timestamp.present? && DIRECTIONS.include?(direction) && Ryze::OutboundDelivery.provider_id?(id)
  end

  # A target is either the raw message key or a bare message id. A provided but
  # unusable value is diagnosed instead of being handled as if it were absent.
  def parse_target(value)
    return parse_target_id(value) if value.is_a?(String)
    return { error: :target_missing } if value.nil?
    return { error: :target_invalid } unless value.is_a?(ActionController::Parameters)

    target_from_key(value)
  end

  def parse_target_id(value)
    return { error: :target_id_invalid } unless Ryze::OutboundDelivery.provider_id?(value)

    { id: value }
  end

  def target_from_key(key)
    id_state, id_value = target_value(key, TARGET_ID_KEYS)
    chat_state, chat_value = target_value(key, TARGET_CHAT_KEYS)
    return { error: :target_invalid } if id_state == :missing && chat_state == :missing

    error = target_id_error(id_state, id_value) || target_chat_error(chat_state, chat_value)
    return { error: error } if error

    { id: id_value, chat: direct_id(chat_value) }
  end

  def target_id_error(state, value)
    return :target_id_invalid if state == :conflicting
    return :target_id_missing if state == :missing
    return :target_id_invalid unless Ryze::OutboundDelivery.provider_id?(value)

    nil
  end

  def target_chat_error(state, value)
    return :target_chat_invalid if state == :conflicting
    return nil unless state == :present

    :target_chat_invalid unless direct_id(value)
  end

  def target_error
    return @target_details[:error] if @target_details[:error]

    :target_self if id == target_id
  end

  def target_value(key, names)
    values = matching_target_keys(key, names).map { |name| key[name] }
    return [:missing, nil] if values.empty?
    return [:conflicting, nil] unless values.uniq.one?

    [:present, values.first]
  end

  def target_categories
    categories = []
    categories << 'id' if matching_target_keys(@target, TARGET_ID_KEYS).any?
    categories << 'chat' if matching_target_keys(@target, TARGET_CHAT_KEYS).any?
    unknown = unknown_target_key_count
    categories << "unknown=#{unknown}" if unknown.positive?
    categories
  end

  def matching_target_keys(key, names)
    key.keys.select { |name| names.include?(name.to_s.downcase) }
  end

  def unknown_target_key_count
    @target.keys.count { |name| TARGET_KEYS.exclude?(name.to_s.downcase) }
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

  def object(value)
    value.is_a?(ActionController::Parameters) ? value : {}
  end
end
