class Messages::IncomingAttachmentReplay
  def self.fingerprint_attribute
    key = Arel::Nodes.build_quoted(Message::INCOMING_ATTACHMENT_FINGERPRINT_KEY)
    Arel::Nodes::InfixOperation.new('->>', Message.arel_table[:additional_attributes], key)
  end

  def initialize(message, uploads, candidates)
    @message = message
    @uploads = uploads
    @candidates = candidates
    @staged_blobs = []
  end

  def perform
    @fingerprint = fingerprint(@message.attachments)
    raise ArgumentError, 'attachments must contain uploaded files or signed blob IDs' unless @fingerprint

    existing = matching_message
    return replay(existing) if existing

    @message.validate!
    stage_uploads
    result = @message.conversation.with_lock do
      matching_message || persist_message
    end
    replay(result)
  ensure
    @staged_blobs.each(&:purge_later) unless @message.persisted?
  end

  private

  def matching_message
    attribute = self.class.fingerprint_attribute
    @candidates.where(attribute.eq(@fingerprint).or(attribute.eq(nil)))
               .reorder(nil).includes(attachments: { file_attachment: :blob }).find_each(batch_size: 25).find do |candidate|
      stored_fingerprint = candidate.incoming_attachment_fingerprint
      stored_fingerprint ? stored_fingerprint == @fingerprint : fingerprint(candidate.attachments.sort_by(&:id)) == @fingerprint
    end
  end

  def fingerprint(attachments)
    return if attachments.empty? || attachments.any? { |attachment| !attachment.file.attached? }

    manifest = attachments.map { |attachment| attachment_identity(attachment) }
    Digest::SHA256.hexdigest(manifest.to_json)
  end

  def attachment_identity(attachment)
    blob = attachment.file.blob
    identity = blob.checksum.present? && !blob.composed ? [blob.checksum, blob.byte_size] : blob.id
    [identity, blob.filename.to_s, blob.content_type, attachment.file_type, attachment.meta&.[]('is_voice_message') == true]
  end

  def stage_uploads
    # Keep storage writes and failed uploads outside the conversation lock and message commit.
    @message.attachments.zip(@uploads).each do |attachment, upload|
      blob = attachment.file.blob
      if blob.new_record?
        blob.save!
        @staged_blobs << blob
        blob.upload_without_unfurling(upload.open)
        attachment.file = blob
      elsif !blob.service.exist?(blob.key)
        raise ActiveStorage::FileNotFoundError, 'Attachment upload is incomplete'
      end
    end
  end

  def persist_message
    @message.update!(additional_attributes: replay_attributes(@message))
    @message
  end

  def replay(message)
    return message if message.incoming_attachment_fingerprint

    message.with_lock do
      next if message.deleted || message.incoming_attachment_fingerprint

      attachments = message.attachments.with_attached_file.order(:id).to_a
      raise ActiveRecord::StaleObjectError.new(message, 'verify attachments for replay') unless fingerprint(attachments) == @fingerprint

      # Older Rails saves could leave a committed blob row with a missing or truncated object.
      attachments.zip(@message.attachments, @uploads).each do |stored, incoming, upload|
        verify_or_restore(stored.file.blob, incoming.file.blob, upload)
      end

      # Record the verified files without running reply resolution or republishing the message.
      message.update_column(:additional_attributes, replay_attributes(message)) # rubocop:disable Rails/SkipsModelValidations
    end
    message
  end

  def verify_or_restore(stored, incoming, upload)
    stored.open { nil }
  rescue ActiveStorage::FileNotFoundError, ActiveStorage::IntegrityError
    if upload.is_a?(String)
      incoming.open { |file| stored.upload_without_unfurling(file) }
    else
      stored.upload_without_unfurling(upload.open)
    end
  end

  def replay_attributes(message)
    (message.additional_attributes || {}).merge(Message::INCOMING_ATTACHMENT_FINGERPRINT_KEY => @fingerprint)
  end
end
