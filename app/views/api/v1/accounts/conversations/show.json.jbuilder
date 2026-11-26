json.partial! 'api/v1/conversations/partials/conversation',
              formats: [:json],
              conversation: @conversation,
              contact_labels: Conversations::ContactLabels.for_conversation(Current.account, @conversation)
