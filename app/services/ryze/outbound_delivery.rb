class Ryze::OutboundDelivery
  DELIVERY_KEY = 'ryze_outbound_delivery'.freeze
  MIRROR_KEY = 'ryze_native_bridge_mirror'.freeze
  VERIFIED_ID_KEY = 'ryze_outbound_message_id'.freeze
  REPLACED_ID_KEY = 'ryze_replaced_message_id'.freeze
  PROVIDER_ID = /\A[a-zA-Z0-9_:-]{1,128}\z/
  PILOT_JID = /\A\d{8,20}@(s\.whatsapp\.net|lid)\z/
  REJECTED_CODES = %w[400 401 403 404 422 429].freeze
  SEND_DEADLINE = 2.minutes
  SCOPE_KEYS = %w[RYZE_INSTANCE_NAME RYZE_EDIT_API_TOKEN RYZE_INBOX_ID RYZE_PILOT_CHAT_JID RYZE_EDIT_CONVERSATION_ID
                  RYZE_NATIVE_BRIDGE_USER_ID].freeze

  class << self
    def configured_pilot?(conversation)
      bridge_user_id.present? && ENV.fetch('RYZE_PILOT_CHAT_JID', '').match?(PILOT_JID) &&
        Ryze::OutgoingEditEligibility.pilot_conversation?(conversation)
    end

    def configured_for?(message, conversation: message.conversation)
      configured_pilot?(conversation) && message.additional_attributes.dig(DELIVERY_KEY, 'scope') == scope_fingerprint
    end

    def bridge_user?(user)
      user.is_a?(User) && user.id == bridge_user_id
    end

    def bridge_user_id
      id = Integer(ENV.fetch('RYZE_NATIVE_BRIDGE_USER_ID', ''), 10, exception: false)
      id if id&.positive?
    end

    def direct?(message)
      message.additional_attributes&.key?(DELIVERY_KEY)
    end

    def pending?(message)
      message.additional_attributes&.dig(DELIVERY_KEY, 'state').in?(%w[queued sending])
    end

    def native_mirror?(message)
      message.additional_attributes&.fetch(MIRROR_KEY, false) == true
    end

    def provider_id?(value)
      value.is_a?(String) && value.match?(PROVIDER_ID)
    end

    def prepare(message)
      delivery = { 'state' => 'queued', 'scope' => scope_fingerprint, 'attempt' => 1 }
      message.additional_attributes = (message.additional_attributes || {}).merge(DELIVERY_KEY => delivery)
    end

    def enqueue(message_id, attempt)
      timeout = Ryze::OutboundDeliveryTimeoutJob.set(wait: SEND_DEADLINE).perform_later(message_id, attempt)
      timeout && Ryze::DeliverOutboundMessageJob.perform_later(message_id, attempt)
    end

    def confirm_event!(inbox:, event:, pilot_chat_id:)
      return :ignored unless event.chat_ids.include?(pilot_chat_id) && provider_id?(event.source_id)

      message = Ryze::OutboundMessageCorrelation.find_tracked_message(inbox, event.tracking_source)
      return :ignored unless message && direct?(message)

      Ryze::OutboundMessageCorrelation.new(message).confirm!(event.source_id, event.tracking_source, event.content)
    end

    def retry_rejected!(message)
      new(message).retry_rejected!
    end

    private

    def scope_fingerprint
      key = Rails.application.key_generator.generate_key('ryze outbound delivery scope')
      OpenSSL::HMAC.hexdigest('SHA256', key, ENV.values_at(*SCOPE_KEYS).join("\0"))
    end
  end

  def initialize(message)
    @message = message
    @correlation = Ryze::OutboundMessageCorrelation.new(message)
  end

  def perform(attempt)
    return unless claim_send!(attempt)

    client = Ryze::Client.new(instance: ENV.fetch('RYZE_INSTANCE_NAME'), token: ENV.fetch('RYZE_EDIT_API_TOKEN'))
    response = client.post(
      'message/text',
      { number: ENV.fetch('RYZE_PILOT_CHAT_JID'), message: @message.webhook_content, source: @correlation.tracking_source }
    )
    handle_response(response, attempt)
  rescue Ryze::Client::ConnectionError, JSON::ParserError
    finish_attempt(attempt, 'unknown')
  end

  def expire!(attempt)
    @message.with_lock do
      next unless matching_attempt?(attempt)

      case delivery['state']
      when 'queued' then fail_delivery!('rejected')
      when 'sending' then fail_delivery!('unknown')
      end
    end
  end

  def retry_rejected!
    attempt = queue_retry
    return false unless attempt
    return true if self.class.enqueue(@message.id, attempt)

    expire!(attempt)
    false
  end

  private

  def queue_retry
    @message.with_lock do
      next unless delivery&.fetch('state') == 'rejected' && !@message.deleted && self.class.configured_for?(@message)

      attempt = delivery['attempt'] + 1
      @message.update!(additional_attributes: attributes_with_state('queued', attempt: attempt), status: :sent, external_error: nil)
      attempt
    end
  end

  def claim_send!(attempt)
    @message.with_lock do
      next false unless matching_attempt?(attempt) && delivery['state'] == 'queued'

      unless self.class.configured_for?(@message)
        fail_delivery!('rejected')
        next false
      end

      @message.update!(additional_attributes: attributes_with_state('sending'))
    end
  end

  def matching_attempt?(attempt)
    delivery&.fetch('attempt') == attempt && !@message.deleted
  end

  def handle_response(response, attempt)
    body = JSON.parse(response.body.to_s)
    return finish_attempt(attempt, 'unknown') unless body.is_a?(Hash)
    return if accepted?(response, body) && confirm_response(body['data']) == :confirmed

    finish_attempt(attempt, definite_rejection?(response, body) ? 'rejected' : 'unknown')
  end

  def accepted?(response, body)
    response.code == '200' && body['success'] == true && body['status'] == 'sent' && body['data'].is_a?(Hash)
  end

  def confirm_response(data)
    return unless data['direction'] == 'outgoing' && data['messageType'] == 'text' && data['chat'].is_a?(Hash)
    return unless [data['chat']['jid'], data['chat']['lid']].include?(ENV.fetch('RYZE_PILOT_CHAT_JID'))
    return unless self.class.provider_id?(data['messageId'])

    @correlation.confirm!(data['messageId'], data['source'], data['content'])
  end

  def definite_rejection?(response, body)
    body['success'] == false && (REJECTED_CODES.include?(response.code) || (response.code == '503' && body['status'] == 'disconnected'))
  end

  def finish_attempt(attempt, state)
    @message.with_lock do
      fail_delivery!(state) if matching_attempt?(attempt) && delivery['state'] == 'sending'
    end
  end

  def fail_delivery!(state)
    error = state == 'rejected' ? 'ryze_delivery_failed' : 'ryze_delivery_unknown'
    @message.update!(additional_attributes: attributes_with_state(state), status: :failed, external_error: error)
  end

  def delivery
    @message.additional_attributes&.fetch(DELIVERY_KEY, nil)
  end

  def attributes_with_state(state, attempt: delivery['attempt'])
    @message.additional_attributes.merge(DELIVERY_KEY => delivery.merge('state' => state, 'attempt' => attempt))
  end
end
