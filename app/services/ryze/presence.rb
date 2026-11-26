class Ryze::Presence
  SCOPE_KEYS = %w[RYZE_INSTANCE_NAME RYZE_INBOX_ID RYZE_PILOT_CHAT_JID RYZE_EDIT_CONVERSATION_ID RYZE_EDIT_API_TOKEN].freeze
  STATES = %w[typing recording pause].freeze
  COMPOSER_ID = /\A[0-9a-f]{12}\z/

  def self.enabled?(conversation)
    enabled_scope? && Ryze::OutgoingEditEligibility.pilot_conversation?(conversation)
  end

  def self.enabled_scope?
    ENV['RYZE_OUTBOUND_PRESENCE_ENABLED'] == 'true' && SCOPE_KEYS.all? { |key| ENV[key].present? } &&
      ENV['RYZE_WEBHOOK_SECRET'].present?
  end

  def self.scope
    key = Rails.application.key_generator.generate_key('ryze outbound presence')
    OpenSSL::HMAC.hexdigest('SHA256', key, ENV.values_at(*SCOPE_KEYS).join("\0"))
  end

  def self.valid_event?(state, composer_id)
    STATES.include?(state) && composer_id.is_a?(String) && composer_id.match?(COMPOSER_ID)
  end

  def self.update(user_id, composer_id, state)
    scope_id = scope
    store = Ryze::PresenceState.new(scope_id)
    token = SecureRandom.hex
    return unless store.update("#{user_id}:#{composer_id}", state, token)

    Ryze::DispatchPresenceJob.perform_later(scope_id, token)
  rescue ActiveJob::EnqueueError, RedisClient::Error, ConnectionPool::TimeoutError
    Rails.logger.warn('Ryze presence could not register composer activity')
  end
end
