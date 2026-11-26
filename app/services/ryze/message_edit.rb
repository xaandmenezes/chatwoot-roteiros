class Ryze::MessageEdit
  # The caller owns the row lock. Ryze's edit timestamp is the revision for both
  # the database and the dashboard's out-of-order event handling.
  def self.apply(message, content:, edited_at:)
    revision = edited_at.utc.iso8601(9)
    metadata = message.additional_attributes || {}
    return false if metadata.fetch('ryze_edited_at', '') >= revision

    attributes = message.content_attributes.except('translations', 'translation_provider', 'translation_failed', 'source_language')
    message.update!(content: content, content_attributes: attributes.merge('edited' => true),
                    additional_attributes: metadata.merge('ryze_edited_at' => revision))
  end
end
