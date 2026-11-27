class Api::V1::Accounts::Conversations::AudioTranscriptionsController < Api::V1::Accounts::Conversations::BaseController
  MAX_ATTACHMENT_IDS = 100
  ATTACHMENT_ID_FORMAT = /\A[1-9][0-9]{0,9}\z/

  def index
    return head :not_found unless dashboard_user? && Ryze::AudioTranscription.enabled_for_conversation?(@conversation)

    ids = attachment_ids
    return render_could_not_create_error("attachment_ids must contain between 1 and #{MAX_ATTACHMENT_IDS} positive attachment IDs") unless ids

    no_store
    render json: { transcriptions: transcriptions(ids) }
  end

  private

  def attachment_ids
    ids = params[:attachment_ids]
    return unless ids.is_a?(Array) && ids.size.between?(1, MAX_ATTACHMENT_IDS)
    return unless ids.all? { |id| id.is_a?(String) && ATTACHMENT_ID_FORMAT.match?(id) }

    ids.map(&:to_i).uniq
  end

  def transcriptions(ids)
    Ryze::AudioTranscription
      .joins(attachment: :message)
      .where(attachment_id: ids, attachments: { account_id: Current.account.id },
             messages: { account_id: Current.account.id, conversation_id: @conversation.id })
      .pluck(:attachment_id, :status, :text)
      .map { |attachment_id, status, text| { attachment_id: attachment_id, status: status, text: text } }
  end
end
