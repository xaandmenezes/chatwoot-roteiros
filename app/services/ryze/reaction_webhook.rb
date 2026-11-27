class Ryze::ReactionWebhook
  def initialize(inbox:, event:)
    @inbox = inbox
    @event = event
  end

  def perform
    conversation = target_conversation
    return unless conversation

    conversation.with_lock do
      next unless Ryze::MessageReactions.pilot?(conversation)

      message = Ryze::MessageReactions.originals(conversation, @event.target_id).lock.sole
      next unless Ryze::MessageReactions.target?(message)

      echo = record_echo(conversation) if @event.direction == 'outgoing'
      next :conflict if echo == :conflict

      Ryze::MessageReactions.new(message).apply!(@event.direction, @event.attributes, source: @event.source, replayed: echo == :replayed)
    end
  end

  private

  def target_conversation
    return Ryze::OutgoingEditEligibility.matching_direct_conversation(@inbox, @event.chat_ids) if Ryze::OutgoingEditEligibility.direct_inbox_enabled?

    @inbox.conversations.find_by(display_id: Integer(ENV.fetch('RYZE_EDIT_CONVERSATION_ID', ''), 10, exception: false))
  end

  def record_echo(conversation)
    Ryze::ReactionMirror.new(conversation: conversation, provider_id: @event.id).record!(target_id: @event.target_id, emoji: @event.emoji)
  end
end
