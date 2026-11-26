contact_labels_by_id = Conversations::ContactLabels.for_conversations(Current.account, @conversations)

json.meta do
  json.mine_count @conversations_count[:mine_count]
  json.unassigned_count @conversations_count[:unassigned_count]
  json.all_count @conversations_count[:all_count]
end
json.payload do
  json.array! @conversations do |conversation|
    json.partial! 'api/v1/conversations/partials/conversation',
                  formats: [:json],
                  conversation: conversation,
                  contact_labels: contact_labels_by_id.fetch(conversation.contact_id, [])
  end
end
