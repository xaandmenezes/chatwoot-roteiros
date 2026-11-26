class Ryze::IncomingMessageChange
  def initialize(inbox:, event:)
    @inbox = inbox
    @event = event
  end

  def perform
    Message.transaction do
      message = original_message
      next if message.deleted && !message.deleted_by_customer?
      next if message.deleted_by_customer? && (@event.customer_revoked? || @event.edited_at)

      if @event.edited_at
        apply_edit(message)
      else
        I18n.with_locale(@inbox.account.locale) { message.mark_deleted!(by_customer: @event.customer_revoked?) }
      end
    end
  end

  private

  def original_message
    chat_jid = Arel::Nodes::InfixOperation.new('->>', Conversation.arel_table[:additional_attributes], Arel::Nodes.build_quoted('whatsapp_jid'))
    @inbox.messages.incoming.where(account_id: @inbox.account_id, private: false, source_id: @event.source_id)
          .joins(:conversation).where(chat_jid.in(@event.chat_ids)).lock('FOR UPDATE OF messages').sole
  end

  def apply_edit(message)
    # Canonical UTC strings sort by revision time, including fractional seconds.
    revision = @event.edited_at.utc.iso8601(9)
    metadata = message.additional_attributes || {}
    return if metadata.fetch('ryze_edited_at', '') >= revision

    attributes = message.content_attributes.except('translations', 'translation_provider', 'translation_failed', 'source_language')
    message.update!(content: @event.content, content_attributes: attributes.merge('edited' => true),
                    additional_attributes: metadata.merge('ryze_edited_at' => revision))
  end
end
