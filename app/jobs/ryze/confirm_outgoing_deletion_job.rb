class Ryze::ConfirmOutgoingDeletionJob < ApplicationJob
  queue_as :medium
  discard_on ActiveRecord::RecordNotFound

  def perform(message_id, source_id, last_attempt: false)
    result = Ryze::MessageDeletion.new(Message.find(message_id)).confirm_by_readback(source_id)
    return unless result == :pending && !last_attempt

    self.class.set(wait: 5.seconds).perform_later(message_id, source_id, last_attempt: true)
  end
end
