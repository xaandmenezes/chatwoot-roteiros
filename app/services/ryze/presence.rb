class Ryze::Presence
  BASE_SCOPE_KEYS = %w[RYZE_INSTANCE_NAME RYZE_INBOX_ID RYZE_EDIT_API_TOKEN].freeze
  SCOPE_KEYS = (BASE_SCOPE_KEYS + %w[RYZE_PILOT_CHAT_JID RYZE_EDIT_CONVERSATION_ID]).freeze
  STATES = %w[typing recording pause].freeze
  COMPOSER_ID = /\A[0-9a-f]{12}\z/

  def self.enabled?(conversation)
    enabled_scope? && Ryze::OutgoingEditEligibility.pilot_conversation?(conversation)
  end

  def self.enabled_scope?
    keys = Ryze::OutgoingEditEligibility.direct_inbox_enabled? ? BASE_SCOPE_KEYS : SCOPE_KEYS
    ENV['RYZE_OUTBOUND_PRESENCE_ENABLED'] == 'true' && keys.all? { |key| ENV[key].present? } &&
      ENV['RYZE_WEBHOOK_SECRET'].present?
  end

  def self.scope(conversation = nil)
    key = Rails.application.key_generator.generate_key('ryze outbound presence')
    values = if Ryze::OutgoingEditEligibility.direct_inbox_enabled? && conversation
               [*ENV.values_at(*BASE_SCOPE_KEYS), conversation.inbox_id, conversation.display_id,
                Ryze::OutgoingEditEligibility.conversation_jid(conversation)]
             else
               ENV.values_at(*SCOPE_KEYS)
             end
    OpenSSL::HMAC.hexdigest('SHA256', key, values.join("\0"))
  end

  def self.valid_event?(state, composer_id)
    STATES.include?(state) && composer_id.is_a?(String) && composer_id.match?(COMPOSER_ID)
  end

  def self.update(user_id, composer_id, state, conversation: nil)
    scope_id = scope(conversation)
    chat_jid = Ryze::OutgoingEditEligibility.conversation_jid(conversation) || ENV.fetch('RYZE_PILOT_CHAT_JID', nil)
    return unless chat_jid

    store = Ryze::PresenceState.new(scope_id)
    token = SecureRandom.hex
    return unless store.update("#{user_id}:#{composer_id}", state, token)

    Ryze::DispatchPresenceJob.perform_later(scope_id, token, chat_jid, conversation&.id)
  rescue ActiveJob::EnqueueError, RedisClient::Error, ConnectionPool::TimeoutError
    Rails.logger.warn('Ryze presence could not register composer activity')
  end
end
