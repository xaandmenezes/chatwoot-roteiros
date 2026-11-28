class Ryze::AudioDelivery
  UNKNOWN_ERROR = 'ryze_delivery_unknown'.freeze
  STATUS_KEY = 'ryze_audio_bridge_status'.freeze

  def self.applies?(message)
    return false unless message.inbox_id.to_s == ENV['RYZE_INBOX_ID'] && message.outgoing? && !message.private?
    return false unless message.inbox.api?

    # The callback identifies a message, so its receipt can only identify one attachment.
    attachments = message.attachments.to_a
    attachments.one? && attachments.first.audio?
  end

  def self.uncertain_transport?(error)
    return error.message.match?(/\A5\d{2}\b/) if error.is_a?(SafeFetch::HttpError)
    return false unless error.is_a?(SafeFetch::FetchError)

    [Net::ReadTimeout, EOFError, Errno::EPIPE, Errno::ECONNRESET, Errno::ECONNABORTED].any? { |type| error.cause.is_a?(type) }
  end

  # Called under the message row lock. A locally initialized "sent" is not a receipt.
  def self.apply_source(message, status, source)
    return true unless applies?(message)

    attributes = message.additional_attributes.to_h

    case source
    when :api_inbox_webhook
      # A transport error is authoritative only until the bridge reports the outcome.
      return !attributes.key?(STATUS_KEY) && !delivery_confirmed?(message)
    when :ryze_bridge
      return record_callback(message, status, attributes)
    when :agent_retry
      message.additional_attributes = message.additional_attributes&.except(STATUS_KEY)
    end
    true
  end

  def self.record_callback(message, status, attributes)
    return false if stale_callback?(message, attributes[STATUS_KEY], status)

    message.external_error = 'ryze_delivery_failed' if status == 'failed' && message.external_error == UNKNOWN_ERROR
    message.additional_attributes = attributes.merge(STATUS_KEY => status)
    true
  end

  def self.stale_callback?(message, receipt, status)
    return delivery_confirmed?(message) if status == 'failed'

    status == 'sent' && receipt == 'failed'
  end

  def self.delivery_confirmed?(message)
    message.delivered? || message.read?
  end
  private_class_method :record_callback, :stale_callback?, :delivery_confirmed?
end
