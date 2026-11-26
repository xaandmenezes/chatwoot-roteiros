class Conversations::ContactLabels
  CONTACTS_PER_QUERY = 1000

  def self.for_conversation(account, conversation)
    for_conversations(account, [conversation]).fetch(conversation.contact_id, [])
  end

  def self.for_conversations(account, conversations)
    labels_by_contact = {}
    conversations.map(&:contact_id).uniq.each_slice(CONTACTS_PER_QUERY) do |contact_ids|
      account.contacts.where(id: contact_ids)
             .joins(taggings: :tag)
             .where(taggings: { context: 'labels', tagger_id: nil })
             .pluck(Contact.arel_table[:id], ActsAsTaggableOn::Tag.arel_table[:name])
             .each do |contact_id, label|
        (labels_by_contact[contact_id] ||= []) << label
      end
    end
    labels_by_contact
  end
end
