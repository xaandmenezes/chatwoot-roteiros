class WebhookListener < BaseListener
  def conversation_status_changed(event)
    conversation = extract_conversation_and_account(event)[0]
    changed_attributes = extract_changed_attributes(event)
    inbox = conversation.inbox
    payload = conversation.webhook_data.merge(event: __method__.to_s, changed_attributes: changed_attributes)
    deliver_webhook_payloads(payload, inbox)
  end

  def conversation_updated(event)
    conversation = extract_conversation_and_account(event)[0]
    changed_attributes = extract_changed_attributes(event)
    inbox = conversation.inbox
    payload = conversation.webhook_data.merge(event: __method__.to_s, changed_attributes: changed_attributes)
    deliver_webhook_payloads(payload, inbox)
  end

  def conversation_created(event)
    conversation = extract_conversation_and_account(event)[0]
    inbox = conversation.inbox
    payload = conversation.webhook_data.merge(event: __method__.to_s)
    deliver_webhook_payloads(payload, inbox)
  end

  def message_created(event)
    message = extract_message_and_account(event)[0]

    return unless message.webhook_sendable?

    payload = message.webhook_data.merge(event: __method__.to_s)
    deliver_message_webhooks(payload, message)
    return unless Ryze::OutboundDelivery.direct?(message)

    raise ActiveJob::EnqueueError, 'Could not enqueue Ryze delivery' unless Ryze::OutboundDelivery.enqueue(message.id, 1)
  end

  def message_updated(event)
    message = extract_message_and_account(event)[0]

    return unless message.webhook_sendable?

    payload = message.webhook_data.merge(event: __method__.to_s)
    deliver_message_webhooks(payload, message, suppress_inbox_webhook: suppress_audio_metadata_echo?(message, event))
  end

  def webwidget_triggered(event)
    contact_inbox = event.data[:contact_inbox]
    inbox = contact_inbox.inbox

    payload = contact_inbox.webhook_data.merge(event: __method__.to_s)
    payload[:event_info] = event.data[:event_info]
    deliver_webhook_payloads(payload, inbox)
  end

  def contact_created(event)
    contact, account = extract_contact_and_account(event)
    payload = contact.webhook_data.merge(event: __method__.to_s)
    deliver_account_webhooks(payload, account)
  end

  def contact_updated(event)
    contact, account = extract_contact_and_account(event)
    changed_attributes = extract_changed_attributes(event)
    return if changed_attributes.blank?

    payload = contact.webhook_data.merge(event: __method__.to_s, changed_attributes: changed_attributes)
    deliver_account_webhooks(payload, account)
  end

  def inbox_created(event)
    inbox, account = extract_inbox_and_account(event)
    inbox_webhook_data = Inbox::EventDataPresenter.new(inbox).webhook_data
    payload = inbox_webhook_data.merge(event: __method__.to_s)
    deliver_account_webhooks(payload, account)
  end

  def inbox_updated(event)
    inbox, account = extract_inbox_and_account(event)
    changed_attributes = extract_changed_attributes(event)
    return if changed_attributes.blank?

    inbox_webhook_data = Inbox::EventDataPresenter.new(inbox).webhook_data
    payload = inbox_webhook_data.merge(event: __method__.to_s, changed_attributes: changed_attributes)
    deliver_account_webhooks(payload, account)
  end

  def conversation_typing_on(event)
    handle_typing_status(__method__.to_s, event)
  end

  def conversation_typing_off(event)
    handle_typing_status(__method__.to_s, event)
  end

  private

  def handle_typing_status(event_name, event)
    conversation = event.data[:conversation]
    user = event.data[:user]
    inbox = conversation.inbox

    payload = {
      event: event_name,
      user: user.webhook_data,
      conversation: conversation.webhook_data,
      is_private: event.data[:is_private] || false
    }
    deliver_webhook_payloads(payload, inbox)
  end

  def deliver_account_webhooks(payload, account, except_url: nil)
    return unless account.api_and_webhooks_enabled?

    account.webhooks.account_type.each do |webhook|
      next if except_url && webhook.url == except_url
      next unless webhook.subscriptions.include?(payload[:event])

      WebhookJob.perform_later(webhook.url, payload, :account_webhook,
                               secret: webhook.secret,
                               delivery_id: SecureRandom.uuid)
    end
  end

  def deliver_api_inbox_webhooks(payload, inbox)
    return unless inbox.channel_type == 'Channel::Api'
    return if inbox.channel.webhook_url.blank?

    WebhookJob.perform_later(inbox.channel.webhook_url, payload, :api_inbox_webhook,
                             secret: inbox.channel.secret, delivery_id: SecureRandom.uuid)
  end

  def deliver_message_webhooks(payload, message, suppress_inbox_webhook: false)
    inbox = message.inbox
    suppress_bridge = message.suppress_ryze_bridge_event?
    excluded_url = inbox.channel.webhook_url if suppress_bridge || suppress_inbox_webhook
    deliver_account_webhooks(payload, inbox.account, except_url: excluded_url)
    return if suppress_bridge || suppress_inbox_webhook || Ryze::OutboundDelivery.direct?(message) || Ryze::OutboundDelivery.native_mirror?(message)

    deliver_api_inbox_webhooks(payload, inbox)
  end

  def suppress_audio_metadata_echo?(message, event)
    return false unless Ryze::AudioDelivery.applies?(message)

    changes = event.data[:previous_changes]
    return false unless changes.is_a?(Hash)

    changes = changes.stringify_keys
    # The native bridge receives an agent retry as a failed-to-sent update.
    return false if changes['status'] == %w[failed sent] && changes.dig('additional_attributes', 1, Ryze::AudioDelivery::STATUS_KEY).blank?

    changes.all? { |attribute, values| audio_metadata_change?(attribute, values) }
  end

  def audio_metadata_change?(attribute, values)
    case attribute
    when 'updated_at', 'status', 'source_id'
      true
    when 'content_attributes'
      only_metadata_key_changed?(values, 'external_error')
    when 'additional_attributes'
      key = Ryze::AudioDelivery::STATUS_KEY
      values.last&.key?(key) && only_metadata_key_changed?(values, key)
    else
      false
    end
  end

  def only_metadata_key_changed?(values, key)
    previous, current = values
    previous.to_h.except(key) == current.to_h.except(key)
  end

  def deliver_webhook_payloads(payload, inbox)
    deliver_account_webhooks(payload, inbox.account)
    deliver_api_inbox_webhooks(payload, inbox)
  end
end
