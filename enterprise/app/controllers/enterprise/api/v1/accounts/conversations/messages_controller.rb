module Enterprise::Api::V1::Accounts::Conversations::MessagesController
  def auto_translate
    return head :forbidden unless @conversation.auto_translate_enabled?

    message_ids = params.require(:message_ids)
    return render_could_not_create_error(I18n.t('errors.auto_translate.invalid_messages')) unless conversation_messages?(message_ids)

    @conversation.messages.where(id: message_ids).find_each do |message|
      Captain::Conversation::ContactMessageTranslationJob.perform_later(message, agent_language)
    end
    head :accepted
  end

  private

  def translation_provider
    Current.account.translation_service
  end

  def translate_message
    return super unless translation_provider == 'captain'

    Captain::Conversation::TranslatorService.new(account: Current.account, conversation_display_id: @conversation.display_id)
                                            .translate(message.content, permitted_params[:target_language])
  end

  def conversation_messages?(message_ids)
    message_ids.is_a?(Array) && @conversation.messages.where(id: message_ids).count == message_ids.uniq.size
  end

  def agent_language
    Current.user.ui_settings['locale'].presence || Current.account.locale
  end
end
