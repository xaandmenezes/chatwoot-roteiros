module AttachmentConcern
  extend ActiveSupport::Concern

  def validate_and_prepare_attachments(actions, record = nil)
    blobs = []
    return [blobs, actions, nil] if actions.blank?

    sanitized = actions.map do |action|
      next action unless action[:action_name] == 'send_attachment'

      result = process_attachment_action(action, record, blobs)
      return [nil, nil, I18n.t('errors.attachments.invalid')] unless result

      result
    end

    [blobs, sanitized, nil]
  end

  private

  def process_attachment_action(action, record, blobs)
    blob_ids = action[:action_params].map do |blob_id|
      resolved_id = prepare_macro_blob(blob_id, record, blobs)
      return nil unless resolved_id

      resolved_id
    end

    action.merge(action_params: blob_ids) if blob_ids.present?
  end

  def prepare_macro_blob(blob_id, record, blobs)
    blob = ActiveStorage::Blob.find_signed(blob_id.to_s)
    return existing_macro_blob_id(blob_id, record) unless blob
    return unless Attachment::BlobReuse.new(blob).unrestricted?

    blobs << blob
    blob.id
  end

  def existing_macro_blob_id(blob_id, record)
    existing = record&.files&.find { |file| file.blob_id == blob_id.to_i }
    blob_id if existing && Attachment::BlobReuse.new(existing.blob).unrestricted?
  end
end
