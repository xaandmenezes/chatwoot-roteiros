class Ryze::DeliverOutboundMessageJob < ApplicationJob
  queue_as :high

  def perform(message_id, attempt)
    message = Message.find_by(id: message_id)
    Ryze::OutboundDelivery.new(message).perform(attempt) if message
  end
end
