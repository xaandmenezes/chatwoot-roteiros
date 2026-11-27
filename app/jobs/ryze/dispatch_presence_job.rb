class Ryze::DispatchPresenceJob < ApplicationJob
  queue_as :high
  sidekiq_options retry: false

  PULSE_INTERVAL = 4.seconds

  def perform(scope, token, chat_jid = nil, conversation_id = nil, was_active: false)
    conversation = Conversation.find_by(id: conversation_id) if conversation_id
    return unless authorized_scope?(scope, conversation)

    target_jid = chat_jid || Ryze::OutgoingEditEligibility.conversation_jid(conversation) || ENV.fetch('RYZE_PILOT_CHAT_JID', nil)
    return unless target_jid

    store = Ryze::PresenceState.new(scope)
    next_token = SecureRandom.hex
    state = store.claim(token, next_token, was_active)
    return unless state

    publish(state, target_jid)
    self.class.set(wait: PULSE_INTERVAL).perform_later(scope, next_token, target_jid, conversation_id, was_active: state != 'pause')
  end

  private

  def authorized_scope?(scope, conversation)
    if conversation
      Ryze::Presence.enabled?(conversation) && scope == Ryze::Presence.scope(conversation)
    elsif !Ryze::OutgoingEditEligibility.direct_inbox_enabled?
      Ryze::Presence.enabled_scope? && scope == Ryze::Presence.scope
    else
      false
    end
  end

  def publish(state, target_jid)
    client = Ryze::Client.new(instance: ENV.fetch('RYZE_INSTANCE_NAME'), token: ENV.fetch('RYZE_EDIT_API_TOKEN'))
    response = client.post('chat/presence', { number: target_jid, state: state })
    Rails.logger.warn("Ryze presence rejected (HTTP #{response.code})") unless response.is_a?(Net::HTTPSuccess)
  rescue Ryze::Client::ConnectionError
    Rails.logger.warn('Ryze presence provider unavailable')
  end
end
