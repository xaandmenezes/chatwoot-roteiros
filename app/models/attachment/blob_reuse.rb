class Attachment::BlobReuse
  def initialize(blob)
    @blob = blob
  end

  def unrestricted?
    !restricted_messages.exists?
  end

  def allowed_in?(conversation, actor:)
    return true if unrestricted?
    return false unless conversation&.persisted?

    return allowed_for_user?(conversation, actor) if actor.is_a?(User)

    allowed_for_contact?(conversation)
  end

  private

  # A contact or integration can only reuse its conversation's public media.
  def allowed_for_contact?(conversation)
    origins.all? { |source| source.conversation_id == conversation.id && !source.private? && !source.activity? }
  end

  def allowed_for_user?(conversation, actor)
    target_account = conversation.account
    policy_context = { user: actor, account: target_account, account_user: target_account.account_users.find_by(user: actor) }
    return false unless policy_context[:account_user] && ConversationPolicy.new(policy_context, conversation).show?

    origins.map(&:conversation).uniq.all? { |source| Conversations::AssignmentAccess.allowed?(source, actor) }
  end

  def origins
    @origins ||= restricted_messages.select(:id, :conversation_id, :private, :message_type).includes(:conversation).to_a
  end

  def restricted_messages
    inbox_id = Conversations::AssignmentAccess.inbox_id
    return Message.none unless inbox_id && @blob&.persisted?

    attachments = Attachment.joins(:file_attachment).where(active_storage_attachments: { blob_id: @blob.id })
    Message.where(inbox_id: inbox_id, id: attachments.select(:message_id))
  end
end
