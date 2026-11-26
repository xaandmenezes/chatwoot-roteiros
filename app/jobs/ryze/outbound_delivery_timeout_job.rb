class Ryze::OutboundDeliveryTimeoutJob < ApplicationJob
  queue_as :medium

  def perform(message_id, attempt)
    message = Message.find_by(id: message_id)
    Ryze::OutboundDelivery.new(message).expire!(attempt) if message
  end
end
