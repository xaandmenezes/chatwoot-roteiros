class Ryze::DispatchPresenceJob < ApplicationJob
  queue_as :high
  sidekiq_options retry: false

  PULSE_INTERVAL = 4.seconds

  def perform(scope, token, was_active: false)
    return unless Ryze::Presence.enabled_scope? && scope == Ryze::Presence.scope

    store = Ryze::PresenceState.new(scope)
    next_token = SecureRandom.hex
    state = store.claim(token, next_token, was_active)
    return unless state

    publish(state)
    self.class.set(wait: PULSE_INTERVAL).perform_later(scope, next_token, was_active: state != 'pause')
  end

  private

  def publish(state)
    client = Ryze::Client.new(instance: ENV.fetch('RYZE_INSTANCE_NAME'), token: ENV.fetch('RYZE_EDIT_API_TOKEN'))
    response = client.post('chat/presence', { number: ENV.fetch('RYZE_PILOT_CHAT_JID'), state: state })
    Rails.logger.warn("Ryze presence rejected (HTTP #{response.code})") unless response.is_a?(Net::HTTPSuccess)
  rescue Ryze::Client::ConnectionError
    Rails.logger.warn('Ryze presence provider unavailable')
  end
end
