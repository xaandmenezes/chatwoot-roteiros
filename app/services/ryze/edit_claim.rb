class Ryze::EditClaim
  TTL = 60.seconds

  def initialize(message_id)
    @key = "RYZE_OUTGOING_EDIT:#{message_id}"
  end

  def acquire(content)
    @value = {
      'token' => SecureRandom.uuid,
      'content_digest' => Digest::SHA256.hexdigest(content),
      'started_at' => Time.current.to_i
    }.to_json
    Redis::Alfred.set(@key, @value, nx: true, ex: TTL)
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
end
