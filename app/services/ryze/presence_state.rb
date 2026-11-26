class Ryze::PresenceState
  LEASE_SECONDS = 9
  DISPATCH_TTL = 30
  MAX_COMPOSERS = 64

  # A composer occupies at most one slot. Keep registration and dispatch ownership
  # atomic so overlapping pulses from multiple web processes share one job chain.
  UPDATE = <<~LUA.freeze
    local typing, recording, dispatch = unpack(KEYS)
    local actor, state, now, lease, capacity, token, ttl = unpack(ARGV)
    redis.call('ZREMRANGEBYSCORE', typing, '-inf', now)
    redis.call('ZREMRANGEBYSCORE', recording, '-inf', now)
    redis.call('ZREM', typing, actor)
    redis.call('ZREM', recording, actor)
    if state == 'pause' then return false end
    if redis.call('ZCARD', typing) + redis.call('ZCARD', recording) >= tonumber(capacity) then return false end

    local target = state == 'typing' and typing or recording
    redis.call('ZADD', target, tonumber(now) + tonumber(lease), actor)
    redis.call('EXPIRE', target, lease)
    return redis.call('SET', dispatch, token, 'NX', 'EX', ttl) ~= false
  LUA

  # Rotate the token before sending, so a duplicate job cannot dispatch twice.
  # Retire ownership atomically with the idle check so a new pulse can claim it.
  CLAIM = <<~LUA.freeze
    local typing, recording, dispatch = unpack(KEYS)
    local token, next_token, now, was_active, ttl = unpack(ARGV)
    if redis.call('GET', dispatch) ~= token then return false end

    local state
    if redis.call('ZCOUNT', recording, '(' .. now, '+inf') > 0 then
      state = 'recording'
    elseif redis.call('ZCOUNT', typing, '(' .. now, '+inf') > 0 then
      state = 'typing'
    elseif was_active == 'true' then
      state = 'pause'
    else
      redis.call('DEL', dispatch)
      return false
    end
    redis.call('SET', dispatch, next_token, 'EX', ttl)
    return state
  LUA

  def initialize(scope)
    @keys = %w[typing recording dispatch].map { |key| "RYZE_PRESENCE:#{scope}:#{key}" }
  end

  def update(actor, state, token)
    Sidekiq.redis do |redis|
      redis.call('EVAL', UPDATE, @keys.size, *@keys, actor, state, Time.current.to_f, LEASE_SECONDS, MAX_COMPOSERS, token, DISPATCH_TTL)
    end
  end

  def claim(token, next_token, was_active)
    Sidekiq.redis do |redis|
      redis.call('EVAL', CLAIM, @keys.size, *@keys, token, next_token, Time.current.to_f, was_active.to_s, DISPATCH_TTL)
    end
  end
end
