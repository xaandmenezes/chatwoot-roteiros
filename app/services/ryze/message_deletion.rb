class Ryze::MessageDeletion
  REMOTE_KEY = 'ryze_outgoing_revoke'.freeze
  LOCAL_KEY = 'ryze_deleted_only_in_chatwoot'.freeze

  def self.pending?(message)
    message.additional_attributes&.dig(REMOTE_KEY, 'state') == 'pending'
  end

  def self.suppress_bridge_event?(message)
    return false unless message.deleted

    attributes = message.additional_attributes
    attributes&.fetch(LOCAL_KEY, false) || attributes&.dig(REMOTE_KEY, 'state') == 'confirmed'
  end

  def initialize(message, remote_ip: nil)
    @message = message
    @remote_ip = remote_ip
    @eligibility = Ryze::OutgoingEditEligibility.new(message)
  end

  def everyone
    result = remote_result
    return result if result

    source_id = @message.source_id
    chat_jid = Ryze::OutgoingEditEligibility.conversation_jid(@message.conversation)
    provider = Ryze::MessageProvider.new
    return :delete_unavailable unless provider.delivered_to_pilot?(source_id, chat_jid: chat_jid)

    result = @message.with_lock { claim(source_id) }
    return result if result

    outcome = @eligibility.expired? ? :delete_expired : provider.request_delete(source_id, chat_jid: chat_jid)
    finish_request(outcome, source_id)
  rescue Ryze::Client::ConnectionError
    :delete_failed
  end

  def confirm_by_readback(source_id)
    return unless acknowledged_pending?(source_id)
    return :pending unless Ryze::MessageProvider.new.original_absent?(source_id)

    @message.with_lock { confirm_pending!(source_id) if acknowledged_pending?(source_id) }
  end

  def local(actor:)
    @message.with_lock do
      next :delete_unavailable unless Ryze::OutgoingEditEligibility.pilot_conversation?(@message.conversation)
      next :delete_unavailable unless Ryze::OutboundDelivery.bridge_user_id
      next :delete_busy if Ryze::OutboundDelivery.pending?(@message) || busy?
      next :confirmed if @message.deleted && !@message.deleted_by_customer?

      @message.mark_deleted_by_agent!(actor: actor, remote_ip: @remote_ip, additional_attributes: attributes.merge(LOCAL_KEY => true))
      :confirmed
    end
  end

  # Called under the original message's row lock by either confirmation path.
  def confirm_pending!(source_id)
    return unless bound?(source_id) && self.class.pending?(@message) && remote['source_id'] == source_id

    confirmed = attributes.merge(REMOTE_KEY => remote.merge('state' => 'confirmed'))
    I18n.with_locale(@message.account.locale) do
      @message.mark_deleted_by_agent!(actor: @message.sender, remote_ip: @remote_ip, additional_attributes: confirmed)
    end
    :confirmed
  end

  private

  def busy?
    # An ambiguous provider request is never resent. Once its HTTP budget has elapsed,
    # staff can still remove their local copy while a delayed webhook remains valid.
    (self.class.pending?(@message) && remote.fetch('started_at') + Ryze::Client::REQUEST_BUDGET >= Time.current.to_i) ||
      Ryze::EditClaim.new(@message.id).pending?
  end

  def claim(source_id)
    result = remote_result
    return result if result
    return :delete_unavailable unless @message.source_id == source_id

    pending = { 'state' => 'pending', 'source_id' => source_id, 'started_at' => Time.current.to_i }
    @message.update!(additional_attributes: attributes.merge(REMOTE_KEY => pending))
    nil
  end

  def finish_request(outcome, source_id)
    result = @message.with_lock { finish(outcome, source_id) }
    return result unless result == :readback_pending

    Ryze::ConfirmOutgoingDeletionJob.set(wait: 3.seconds).perform_later(@message.id, source_id)
    :pending
  end

  def acknowledged_pending?(source_id)
    bound?(source_id) && self.class.pending?(@message) && remote['source_id'] == source_id && remote['acknowledged'] == true
  end

  def finish(outcome, source_id)
    return :delete_unavailable unless bound?(source_id) && attributes.dig(REMOTE_KEY, 'source_id') == source_id
    return :confirmed if remote['state'] == 'confirmed'
    return confirm_pending!(source_id) if outcome == :confirmed

    @message.update!(additional_attributes: attributes.merge(REMOTE_KEY => remote.merge('acknowledged' => true))) if outcome == :readback_pending
    @message.update!(additional_attributes: attributes.except(REMOTE_KEY)) if [:delete_failed, :delete_expired].include?(outcome)
    outcome
  end

  def remote_result
    return :delete_unavailable unless bound?(@message.source_id)
    return existing_result if remote

    eligibility_error
  end

  def existing_result
    return :delete_unavailable unless remote['source_id'] == @message.source_id
    return :confirmed if remote['state'] == 'confirmed' && @message.deleted
    return :pending if self.class.pending?(@message)

    :delete_unavailable
  end

  def eligibility_error
    return :delete_unavailable unless @eligibility.permitted? && @message.conversation.can_reply?
    return :delete_expired if @eligibility.expired?
    return :delete_busy if Ryze::EditClaim.new(@message.id).pending?
    return :delete_unavailable unless Ryze::OutboundMessageCorrelation.matching_message(@message.conversation, @message.source_id) == @message

    nil
  end

  def bound?(source_id)
    source_id.present? && @message.source_id == source_id && attributes[Ryze::OutboundDelivery::VERIFIED_ID_KEY] == source_id &&
      Ryze::OutboundDelivery.configured_for?(@message)
  end

  def attributes
    @message.additional_attributes || {}
  end

  def remote
    attributes[REMOTE_KEY]
  end
end
