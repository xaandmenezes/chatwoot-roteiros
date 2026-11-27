json.meta do
  json.has_more @result.has_more
  json.next_before @result.next_before
  json.imported_count @result.imported_messages.size
end

pilot = Ryze::OutgoingEditEligibility.pilot_conversation?(@conversation)
json.payload do
  json.array! @result.imported_messages do |message|
    json.partial! 'api/v1/models/message', message: message
    json.merge! message.agent_revocation_data({}) if message.deleted_by_customer?
    json.ryze_delete_scopes true if pilot
    json.can_edit_content true if pilot && message.sender_id == Current.user.id && message.ryze_editable?(conversation: @conversation)
    json.ryze_delivery_pending true if Ryze::OutboundDelivery.pending?(message)
    json.merge! message.ryze_reaction_data(conversation: @conversation, unique_source_ids: @unique_reaction_source_ids)
    edit_metadata = message.additional_attributes&.slice(
      'ryze_edited_at', Ryze::OutboundDelivery::VERIFIED_ID_KEY, Ryze::OutboundDelivery::REPLACED_ID_KEY
    )
    json.additional_attributes edit_metadata if edit_metadata.present?
  end
end
