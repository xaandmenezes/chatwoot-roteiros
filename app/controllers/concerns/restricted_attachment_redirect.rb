# Legacy blob and representation URLs may predate activation of the inbox.
module RestrictedAttachmentRedirect
  extend ActiveSupport::Concern

  included do
    before_action :route_restricted_attachment
  end

  private

  def route_restricted_attachment
    inbox_id = Conversations::AssignmentAccess.inbox_id
    return unless inbox_id && @blob

    file = Attachment.joins(:file_attachment, :message)
                     .where(active_storage_attachments: { blob_id: @blob.id }, messages: { inbox_id: inbox_id }).first
    return unless file

    no_store
    redirect_to Rails.application.routes.url_helpers.api_v1_account_conversation_attachment_path(
      file.account_id, file.message.conversation.display_id, file.id,
      thumbnail: ('true' if params[:variation_key]), disposition: params[:disposition].presence_in(%w[inline attachment])
    )
  end
end
