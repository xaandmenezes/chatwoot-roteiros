class Webhooks::RyzeController < ActionController::API
  rescue_from ActiveRecord::RecordNotFound, with: :retry_later
  rescue_from ActiveRecord::SoleRecordExceeded, with: :reject_ambiguous_message

  def events
    return head :service_unavailable unless configured?
    return head :unauthorized unless valid_bearer_token?

    event = Ryze::WebhookEvent.new(params)
    return head :ok unless event.instance_name == ENV.fetch('RYZE_INSTANCE_NAME') && event.message_exchange?

    log_pilot_event(event)
    dispatch_event(event)
  end

  private

  def dispatch_event(event)
    reaction = event.reaction if Ryze::MessageReactions.enabled?
    return process_reaction(reaction) if reaction
    return process_outgoing(event) if event.outgoing_change?
    return process_event(event) if event.message_change?

    Ryze::SyncProfileAvatarJob.enqueue_for(event)
    head :ok
  end

  def process_action(*args)
    request.set_header(
      'action_dispatch.parameter_filter',
      Array(request.get_header('action_dispatch.parameter_filter')) + %i[data instanceData]
    )
    super
  end

  def log_pilot_event(event)
    Rails.logger.info(event.pilot_log_line) if eligible_chat?(event)
  end

  def process_outgoing(event)
    return head :ok unless outgoing_pilot_event?(event)
    return head :service_unavailable unless inbox&.api?

    return confirm_delivery(event) if event.tracked_delivery?
    return head :bad_request unless event.valid?

    Ryze::OutgoingMessageChange.new(inbox: inbox, event: event).perform(pilot_chat_id: pilot_chat_id)
    head :ok
  end

  def process_reaction(reaction)
    allowed = direct_inbox_enabled? ? reaction.in_direct_chat? : reaction.in_pilot?(pilot_chat_id)
    return head :ok unless allowed

    validation_error = reaction.validation_error
    return reject_invalid_reaction(reaction, validation_error) if validation_error
    return head :service_unavailable unless inbox&.api?

    result = Ryze::ReactionWebhook.new(inbox: inbox, event: reaction).perform
    head(result == :conflict ? :conflict : :ok)
  end

  def reject_invalid_reaction(reaction, reason)
    Rails.logger.info("Ryze pilot reaction rejected field=#{reason} target_shape=#{reaction.target_shape}")
    head :bad_request
  end

  def outgoing_pilot_event?(event)
    ENV['RYZE_EDIT_API_TOKEN'].present? && eligible_chat?(event)
  end

  def confirm_delivery(event)
    result = Ryze::OutboundDelivery.confirm_event!(inbox: inbox, event: event, pilot_chat_id: pilot_chat_id)
    head(result == :conflict ? :conflict : :ok)
  end

  def process_event(event)
    revocation = scoped_revocation?(event)
    return head :bad_request unless event.valid?(require_chat: !revocation)
    return head :ok if event_outside_scope?(event) && !revocation
    return head :service_unavailable unless inbox&.api?

    Ryze::IncomingMessageChange.new(inbox: inbox, event: event).perform(pilot_chat_id: pilot_chat_id)
    head :ok
  end

  def scoped_revocation?(event)
    event.customer_revoked? && (direct_inbox_enabled? || pilot_chat_id.present?)
  end

  def direct_inbox_enabled?
    Ryze::OutgoingEditEligibility.direct_inbox_enabled?
  end

  def eligible_chat?(event)
    direct_inbox_enabled? ? event.direct_chat? : (pilot_chat_id.present? && !event.outside_pilot?(pilot_chat_id))
  end

  def event_outside_scope?(event)
    direct_inbox_enabled? ? !event.direct_chat? : event.outside_pilot?(pilot_chat_id)
  end

  def configured?
    ENV.fetch('RYZE_WEBHOOK_SECRET', nil).present? && ENV.fetch('RYZE_INSTANCE_NAME', nil).present? &&
      ENV.fetch('RYZE_INBOX_ID', nil).present?
  end

  def inbox
    @inbox ||= Inbox.find_by(id: Integer(ENV.fetch('RYZE_INBOX_ID'), 10, exception: false))
  end

  def pilot_chat_id
    ENV.fetch('RYZE_PILOT_CHAT_JID', nil)
  end

  def valid_bearer_token?
    expected_token = ENV.fetch('RYZE_WEBHOOK_SECRET', nil)
    match = request.authorization.to_s.match(/\ABearer ([^\s]+)\z/i)
    expected_token.present? && match.present? && ActiveSupport::SecurityUtils.secure_compare(match[1], expected_token)
  end

  def retry_later
    response.headers['Retry-After'] = '2'
    head :service_unavailable
  end

  def reject_ambiguous_message
    head :conflict
  end
end
