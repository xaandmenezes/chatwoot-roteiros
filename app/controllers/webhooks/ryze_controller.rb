class Webhooks::RyzeController < ActionController::API
  rescue_from ActiveRecord::RecordNotFound, with: :retry_later
  rescue_from ActiveRecord::SoleRecordExceeded, with: :reject_ambiguous_message

  def events
    return head :service_unavailable unless configured?
    return head :unauthorized unless valid_bearer_token?

    event = Ryze::WebhookEvent.new(params)
    return head :ok unless event.instance_name == ENV.fetch('RYZE_INSTANCE_NAME') && event.message_exchange?

    log_pilot_event(event)
    return head :ok unless event.message_change?

    process_event(event)
  end

  private

  def process_action(*args)
    request.set_header(
      'action_dispatch.parameter_filter',
      Array(request.get_header('action_dispatch.parameter_filter')) + %i[data instanceData]
    )
    super
  end

  def log_pilot_event(event)
    Rails.logger.info(event.pilot_log_line) if pilot_chat_id.present? && event.chat_ids.include?(pilot_chat_id)
  end

  def process_event(event)
    return head :bad_request unless event.valid?
    return head :ok if pilot_chat_id.present? && event.chat_ids.exclude?(pilot_chat_id)
    return head :service_unavailable unless inbox&.api?

    Ryze::IncomingMessageChange.new(inbox: inbox, event: event).perform
    head :ok
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
