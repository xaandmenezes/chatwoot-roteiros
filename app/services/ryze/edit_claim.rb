class Ryze::EditClaim
  TTL = 60.seconds

  attr_reader :token

  def initialize(message_id)
    @key = "RYZE_OUTGOING_EDIT:#{message_id}"
  end

  def acquire(content, original:)
    @token = SecureRandom.uuid
    @state = {
      'token' => @token,
      'baseline' => baseline(original),
      'content_digest' => Digest::SHA256.hexdigest(content),
      'started_at' => Time.current.to_i
    }
    @value = @state.to_json
    Redis::Alfred.set(@key, @value, nx: true, ex: TTL)
  end

  def load_attempt(token)
    value = Redis::Alfred.get(@key)
    return unless value

    state = JSON.parse(value)
    return unless state['token'] == token

    @value = value
    @state = state
  end

  def original?(message)
    @state.fetch('baseline') == baseline(message)
  end

  def requested?(text)
    text.is_a?(String) && @state.fetch('content_digest') == Digest::SHA256.hexdigest(text)
  end

  def pending?
    Redis::Alfred.exists?(@key)
  end

  def active?
    @value.present? && Redis::Alfred.get(@key) == @value
  end

  def release
    Redis::Alfred.delete_if_equals(@key, @value)
  end

  def confirm(content, edited_at:)
    value = Redis::Alfred.get(@key)
    return unless value

    state = JSON.parse(value)
    return unless state.fetch('content_digest') == Digest::SHA256.hexdigest(content)
    return if edited_at.to_i < state.fetch('started_at')

    Redis::Alfred.delete_if_equals(@key, value)
  end

  private

  def baseline(message)
    attributes = message.additional_attributes || {}
    scope = attributes.dig(Ryze::OutboundDelivery::DELIVERY_KEY, 'scope')
    Digest::SHA256.hexdigest([scope, message.conversation_id, message.source_id, attributes['ryze_edited_at'], message.content].to_json)
  end
end
