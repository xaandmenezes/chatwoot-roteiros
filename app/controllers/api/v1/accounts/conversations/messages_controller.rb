class Api::V1::Accounts::Conversations::MessagesController < Api::V1::Accounts::Conversations::BaseController
  MESSAGE_ACTION_ERRORS = {
    delete_busy: :conflict,
    delete_expired: :unprocessable_entity,
    delete_failed: :bad_gateway,
    delete_unavailable: :unprocessable_entity,
    edit_expired: :unprocessable_entity,
    edit_failed: :bad_gateway,
    edit_unavailable: :unprocessable_entity,
    invalid_content: :unprocessable_entity,
    edit_pending: :conflict
  }.freeze

  REACTION_ERRORS = {
    invalid_reaction: :unprocessable_entity,
    reaction_unavailable: :unprocessable_entity,
    reaction_failed: :bad_gateway
  }.freeze

  before_action :ensure_api_inbox, only: :update

  def index
    @messages = message_finder.perform
    @agent_history = Current.user.is_a?(User)
    preload_customer_revocations if @agent_history
    return unless @agent_history && Ryze::MessageReactions.pilot?(@conversation)

    source_ids = @messages.filter_map { |message| message.source_id if Ryze::MessageReactions.target?(message) }
    @unique_reaction_source_ids = Ryze::MessageReactions.unique_source_ids(@conversation, source_ids)
  end

  def create
    user = Current.user || @resource
    mb = Messages::MessageBuilder.new(user, @conversation, params, api_token_request: @access_token.present?)
    @message = mb.perform(replay_incoming_attachments: true)
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def update
    Messages::StatusUpdateService.new(message, permitted_params[:status], permitted_params[:external_error]).perform
    @message = message
  end

  def edit_content
    return render json: { error_code: 'edit_unavailable' }, status: :forbidden unless own_message?

    result = Ryze::EditOutgoingMessage.new(message: message, conversation: @conversation, content: params[:content]).perform
    render_message_action_result(result)
  end

  def reaction
    return head :forbidden unless Current.user.is_a?(User)

    result = Ryze::SendReaction.new(message: message, actor: Current.user, emoji: params[:emoji]).perform
    case result
    when :confirmed, :pending
      status = result == :pending ? :accepted : :ok
      render json: Ryze::MessageReactions.new(message).payload, status: status
    else
      render json: { error_code: result }, status: REACTION_ERRORS.fetch(result)
    end
  end

  def delete_for_everyone
    return render json: { error_code: 'delete_unavailable' }, status: :forbidden unless own_message?

    render_message_action_result(Ryze::MessageDeletion.new(message, remote_ip: request.remote_ip).everyone)
  end

  def delete_only_in_chatwoot
    return render json: { error_code: 'delete_unavailable' }, status: :forbidden unless Current.user.is_a?(User)

    render_message_action_result(Ryze::MessageDeletion.new(message, remote_ip: request.remote_ip).local(actor: Current.user))
  end

  def destroy
    unless Ryze::OutgoingEditEligibility.pilot_conversation?(@conversation)
      return message.mark_deleted_by_agent!(actor: Current.user,
                                            remote_ip: request.remote_ip)
    end

    result = Ryze::MessageDeletion.new(message, remote_ip: request.remote_ip).local(actor: Current.user)
    render_message_action_result(result) unless result == :confirmed
  end

  def retry
    return retry_ryze_delivery if Ryze::OutboundDelivery.direct?(message)

    ::SendReplyJob.perform_later(message.id) if claim_message_retry
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def translate
    return head :ok if already_translated_content_available?

    original_content = message.content
    translation = translate_message unless message.deleted
    saved_content = save_translation(original_content, translation) if translation.present?
    render json: { content: saved_content }
  rescue Google::Cloud::Error => e
    # `details` carries the clean human message; `message` includes gRPC debug noise
    render_could_not_create_error(e.details.presence || e.message)
  end

  private

  def own_message?
    Current.user.is_a?(User) && message.sender_type == 'User' && message.sender_id == Current.user.id
  end

  def render_message_action_result(result)
    case result
    when :confirmed then render json: message.agent_view_data(message.push_event_data)
    when :pending then render json: { status: 'pending' }, status: :accepted
    else render json: { error_code: result }, status: MESSAGE_ACTION_ERRORS.fetch(result)
    end
  end

  def preload_customer_revocations
    revoked = @messages.select(&:deleted_by_customer?)
    return if revoked.empty?

    ActiveRecord::Associations::Preloader.new(records: revoked, associations: :customer_revocation).call
  end

  def save_translation(original_content, translation)
    message.with_current_content(original_content) do
      translations = message.translations.to_h.merge(permitted_params[:target_language] => translation)
      message.update!(translations: translations, translation_provider: translation_provider)
      translation
    end
  end

  def translation_provider
    'google_translate'
  end

  def translate_message
    hook = Current.account.hooks.find_by(app_id: 'google_translate')
    Integrations::GoogleTranslate::ProcessorService.new(hook: hook).translate_message(message, permitted_params[:target_language]) if hook
  end

  def message
    @message ||= @conversation.messages.find(permitted_params[:id])
  end

  def message_finder
    @message_finder ||= MessageFinder.new(@conversation, params)
  end

  def retry_ryze_delivery
    return head :accepted if Ryze::OutboundDelivery.retry_rejected!(message)

    render json: { error_code: 'ryze_retry_unavailable' }, status: :conflict
  end

  def claim_message_retry
    message.with_lock do
      next false unless message.failed?

      Messages::StatusUpdateService.new(message, 'sent').perform
      clear_source_id unless @conversation.inbox.api? || @conversation.inbox.web_widget?
      true
    end
  end

  def clear_source_id
    Rails.logger.info "Cleared older source ID #{message.source_id} for message #{message.id}" if message.source_id.present?
    message.update!(source_id: nil)
  end

  def permitted_params
    params.permit(:id, :target_language, :status, :external_error)
  end

  def already_translated_content_available?
    message.translations.present? && message.translations[permitted_params[:target_language]].present?
  end

  # API inbox check
  def ensure_api_inbox
    # Only API inboxes can update messages
    render json: { error: 'Message status update is only allowed for API inboxes' }, status: :forbidden unless @conversation.inbox.api?
  end
end

Api::V1::Accounts::Conversations::MessagesController.prepend_mod_with('Api::V1::Accounts::Conversations::MessagesController')
