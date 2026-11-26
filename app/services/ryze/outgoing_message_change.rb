class Ryze::OutgoingMessageChange
  def initialize(inbox:, event:)
    @inbox = inbox
    @event = event
  end

  def perform(pilot_chat_id:)
    return if pilot_chat_id.blank? || @event.outside_pilot?(pilot_chat_id)

    edited_id = Message.transaction { apply_change(bound_original) }
    Ryze::EditClaim.new(edited_id).confirm(@event.content, edited_at: @event.edited_at) if edited_id
  end

  private

  def apply_change(original)
    return unless original

    if @event.outgoing_revoke?
      Ryze::MessageDeletion.new(original).confirm_pending!(@event.source_id)
      return
    end
    return if original.deleted

    changed = Ryze::MessageEdit.apply(original, content: @event.content, edited_at: @event.edited_at)
    original.id if changed
  end

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
