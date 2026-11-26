class Ryze::OutgoingMessageChange
  def initialize(inbox:, event:)
    @inbox = inbox
    @event = event
  end

  def perform(pilot_chat_id:)
    return if pilot_chat_id.blank? || @event.outside_pilot?(pilot_chat_id)

    confirmed_id = Message.transaction do
      original = bound_original
      next unless original && !original.deleted

      changed = Ryze::MessageEdit.apply(original, content: @event.content, edited_at: @event.edited_at)
      original.id if changed
    end
    Ryze::EditClaim.new(confirmed_id).confirm(@event.content, edited_at: @event.edited_at) if confirmed_id
  end

  private

  def bound_original
    candidates = @inbox.messages.outgoing.where(account_id: @inbox.account_id, private: false, content_type: :text,
                                                sender_type: 'User', source_id: @event.source_id)
    binding = Arel::Nodes::InfixOperation.new('->>', Message.arel_table[:additional_attributes], Arel::Nodes.build_quoted('ryze_outbound_message_id'))
    message = candidates.where(binding.eq(@event.source_id)).lock.sole
    message if message.conversation.account_id == @inbox.account_id && Ryze::OutboundDelivery.configured_for?(message)
  rescue ActiveRecord::RecordNotFound
    # A phone-originated or historical edit has no trusted team delivery.
    nil
  end
end
