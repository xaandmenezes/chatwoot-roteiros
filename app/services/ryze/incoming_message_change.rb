class Ryze::IncomingMessageChange
  def initialize(inbox:, event:)
    @inbox = inbox
    @event = event
  end

  def perform(pilot_chat_id: nil)
    Message.transaction do
      message = original_message(pilot_chat_id)
      apply_change(message) if message
    end
  end

  private

  def original_message(pilot_chat_id)
    originals = @inbox.messages.incoming.where(account_id: @inbox.account_id, private: false, source_id: @event.source_id)
                      .lock('FOR UPDATE OF messages')
    if @event.outside_pilot?(pilot_chat_id)
      return pilot_revoked_message(originals, pilot_chat_id) if @event.customer_revoked?

      return
    end

    chat_jid = Arel::Nodes::InfixOperation.new('->>', Conversation.arel_table[:additional_attributes], Arel::Nodes.build_quoted('whatsapp_jid'))
    originals.joins(:conversation).where(chat_jid.in(@event.chat_ids)).sole
  end

  def pilot_revoked_message(originals, pilot_chat_id)
    # Ryze can revoke by the original message ID with a different or absent chat identifier.
    message = originals.sole
    conversation = message.conversation
    return unless conversation.account_id == @inbox.account_id && conversation.inbox_id == @inbox.id
    return unless conversation.additional_attributes&.fetch('whatsapp_jid', nil) == pilot_chat_id

    Rails.logger.info(@event.pilot_log_line)
    message
  end

  def apply_change(message)
    return if message.deleted && !message.deleted_by_customer?
    return if message.deleted_by_customer? && (@event.customer_revoked? || @event.edited_at)

    if @event.edited_at
      Ryze::MessageEdit.apply(message, content: @event.content, edited_at: @event.edited_at)
    else
      I18n.with_locale(@inbox.account.locale) { message.mark_deleted!(by_customer: @event.customer_revoked?) }
    end
  end
end
