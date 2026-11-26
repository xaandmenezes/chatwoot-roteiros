class Ryze::ReactionWebhook
  def initialize(inbox:, event:)
    @inbox = inbox
    @event = event
  end

  def perform
    conversation = @inbox.conversations.find_by(display_id: Integer(ENV.fetch('RYZE_EDIT_CONVERSATION_ID', ''), 10, exception: false))
    return unless conversation && Ryze::MessageReactions.pilot?(conversation)

    Message.transaction do
      message = Ryze::MessageReactions.originals(conversation, @event.target_id).lock.sole
      next unless Ryze::MessageReactions.target?(message)

      Ryze::MessageReactions.new(message).apply!(@event.direction, @event.attributes, source: @event.source)
    end
  end
end
