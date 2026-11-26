json.partial! 'api/v1/models/message', message: @message
json.ryze_delivery_pending true if Current.user.is_a?(User) && Ryze::OutboundDelivery.pending?(@message)
json.ryze_delete_scopes true if Current.user.is_a?(User) && Ryze::OutgoingEditEligibility.pilot_conversation?(@conversation)
