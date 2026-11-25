class Ryze::IncomingMessageChange
  def initialize(inbox:, source_id:, chat_ids:, content:, edited_at:)
    @inbox = inbox
    @source_id = source_id
    @chat_ids = chat_ids
    @content = content
    @edited_at = edited_at
  end

  def perform
    Message.transaction do
      message = original_message
      next if message.deleted

      if @edited_at
        apply_edit(message)
      else
        I18n.with_locale(@inbox.account.locale) { message.mark_deleted! }
      end
    end
  end

  private

  def original_message
    chat_jid = Arel::Nodes::InfixOperation.new('->>', Conversation.arel_table[:additional_attributes], Arel::Nodes.build_quoted('whatsapp_jid'))
    @inbox.messages.incoming.where(account_id: @inbox.account_id, private: false, source_id: @source_id)
          .joins(:conversation).where(chat_jid.in(@chat_ids)).lock('FOR UPDATE OF messages').sole
  end

  def apply_edit(message)
    # Canonical UTC strings sort by revision time, including fractional seconds.
    revision = @edited_at.utc.iso8601(9)
    metadata = message.additional_attributes || {}
    return if metadata.fetch('ryze_edited_at', '') >= revision

    attributes = message.content_attributes.except('translations', 'translation_provider', 'translation_failed', 'source_language')
    message.update!(content: @content, content_attributes: attributes.merge('edited' => true),
                    additional_attributes: metadata.merge('ryze_edited_at' => revision))
  end
end
