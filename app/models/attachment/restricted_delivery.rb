module Attachment::RestrictedDelivery
  extend ActiveSupport::Concern

  included do
    validate :validate_restricted_blob_reuse, if: -> { attachment_changes.key?('file') && file.attached? }
  end

  # The bridge fetches media without a dashboard session. Expose an expiring storage
  # URL only in an outbound integration payload.
  def webhook_event_data
    data = push_event_data
    return data unless data && restricted_file? && with_attached_file?

    service_url = download_url
    data.merge(data_url: service_url, thumb_url: image? ? service_url : '')
  end

  private

  def validate_restricted_blob_reuse
    return if Attachment::BlobReuse.new(file.blob).allowed_in?(message&.conversation, actor: Current.user)

    errors.add(:file, :invalid)
  end

  def restricted_file?
    inbox_id = Conversations::AssignmentAccess.inbox_id
    return false unless inbox_id && file.attached?

    message.inbox_id == inbox_id || protected_blob_origin?
  end

  def protected_blob_origin?
    return @protected_blob_origin if defined?(@protected_blob_origin)

    @protected_blob_origin = !Attachment::BlobReuse.new(file.blob).unrestricted?
  end

  def restricted_file_url(thumbnail: nil)
    api_v1_account_conversation_attachment_url(account_id, message.conversation.display_id, id, thumbnail: thumbnail)
  end
end
