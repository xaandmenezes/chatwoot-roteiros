class Ryze::SyncProfileAvatarJob < ApplicationJob
  queue_as :purgable

  LOOKUP_INTERVAL = 15.minutes.to_i

  class << self
    def enqueue_for(event)
      return unless event.incoming_private_text?

      scope = resolve_scope(event)
      return unless scope

      inbox_id, display_id, _instance, chat_id = scope
      key = "RYZE_PROFILE_AVATAR:#{inbox_id}:#{display_id}"
      return unless Redis::Alfred.set(key, true, nx: true, ex: LOOKUP_INTERVAL)

      if Ryze::OutgoingEditEligibility.direct_inbox_enabled?
        perform_later(scope_hash(scope), display_id, chat_id)
      else
        perform_later(scope_hash(scope))
      end
    rescue Redis::BaseError, ConnectionPool::TimeoutError, ActiveJob::EnqueueError => e
      Rails.logger.warn("Ryze profile avatar could not be queued (#{e.class})")
    end

    def resolve_scope(event)
      return direct_inbox_scope(event) if Ryze::OutgoingEditEligibility.direct_inbox_enabled?

      scope = pilot_scope
      scope if scope && event.chat_ids.include?(scope.last)
    end

    def direct_inbox_scope(event)
      inbox_id, instance = base_scope
      return unless inbox_id && instance

      conversation = missing_avatar_conversation(inbox_id, event.chat_ids)
      chat_id = Ryze::OutgoingEditEligibility.conversation_jid(conversation)
      [inbox_id, conversation.display_id, instance, chat_id] if chat_id
    end

    def missing_avatar_conversation(inbox_id, chat_ids)
      inbox = Inbox.find_by(id: inbox_id)
      return unless inbox&.api?

      conversation = Ryze::OutgoingEditEligibility.matching_direct_conversation(inbox, chat_ids)
      contact = conversation&.contact
      conversation if contact && !contact.avatar.attached?
    end

    def base_scope
      return unless ENV['RYZE_PROFILE_AVATAR_SYNC'] == 'true' && ENV['RYZE_EDIT_API_TOKEN'].present?

      inbox_id = Integer(ENV.fetch('RYZE_INBOX_ID', ''), 10, exception: false)
      instance = ENV.fetch('RYZE_INSTANCE_NAME', nil)
      [inbox_id, instance] if inbox_id && instance.present?
    end

    def pilot_scope
      inbox_id, instance = base_scope
      return unless inbox_id && instance

      display_id = Integer(ENV.fetch('RYZE_EDIT_CONVERSATION_ID', ''), 10, exception: false)
      chat_id = ENV.fetch('RYZE_PILOT_CHAT_JID', '')
      return unless display_id && chat_id.match?(Ryze::OutgoingEditEligibility::DIRECT_JID)

      [inbox_id, display_id, instance, chat_id]
    end

    def scope_hash(scope)
      Digest::SHA256.hexdigest(scope.to_json)
    end
  end

  def perform(expected_scope, display_id = nil, chat_id = nil)
    scope = resolved_job_scope(display_id, chat_id)
    return unless scope && self.class.scope_hash(scope) == expected_scope

    inbox_id, target_display_id, instance, target_chat_id = scope
    contact = linked_contact(inbox_id, target_display_id, target_chat_id)
    return unless contact && !contact.avatar.attached?

    client = Ryze::Client.new(instance: instance, token: ENV.fetch('RYZE_EDIT_API_TOKEN'), read_timeout: 12, request_budget: 15)
    url = profile_picture(client, target_chat_id)
    # Keep the signed CDN URL out of Active Job argument logs.
    Avatar::AvatarFromUrlJob.new.perform(contact, url, only_if_missing: true) if allowed_picture_url?(url)
  rescue Ryze::Client::ConnectionError, JSON::ParserError
    Rails.logger.info('Ryze profile avatar lookup unavailable')
  end

  private

  def resolved_job_scope(display_id, chat_id)
    if Ryze::OutgoingEditEligibility.direct_inbox_enabled? && display_id && chat_id
      inbox_id, instance = self.class.base_scope
      return unless inbox_id && instance && chat_id.match?(Ryze::OutgoingEditEligibility::DIRECT_JID)

      return [inbox_id, display_id, instance, chat_id]
    end

    self.class.pilot_scope
  end

  def linked_contact(inbox_id, display_id, chat_id)
    inbox = Inbox.find_by(id: inbox_id)
    return unless inbox&.api?

    conversation = inbox.conversations.find_by(account_id: inbox.account_id, display_id: display_id)
    return unless conversation && Ryze::OutgoingEditEligibility.conversation_jid(conversation) == chat_id
    return unless Ryze::OutgoingEditEligibility.pilot_conversation?(conversation)

    inbox.account.contacts.find_by(id: conversation.contact_id)
  end

  def profile_picture(client, chat_id)
    response = client.get('profile/getAccount', number: chat_id.delete_suffix('@s.whatsapp.net'))
    unless response.is_a?(Net::HTTPOK)
      Rails.logger.info("Ryze profile avatar lookup unavailable (HTTP #{response.code})")
      return
    end

    data = JSON.parse(response.body)
    profile = data['profile'] if data.is_a?(Hash) && data['success'] == true
    profile['profilePicture'] if profile.is_a?(Hash)
  end

  def allowed_picture_url?(url)
    return false unless url.is_a?(String)

    uri = URI.parse(url)
    uri.is_a?(URI::HTTPS) && uri.host == 'pps.whatsapp.net' && uri.port == 443 && uri.userinfo.nil?
  rescue URI::InvalidURIError
    false
  end
end
