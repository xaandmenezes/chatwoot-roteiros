class Ryze::HistoricalSync::ConversationWindow
  attr_reader :starts_at, :ends_at

  def initialize(conversation)
    return unless Conversations::AssignmentAccess.enabled?(conversation.inbox_id)

    @conversation = conversation
    @starts_at = conversation.created_at if related_conversations.where(earlier).exists?
    @ends_at = related_conversations.where(later).minimum(:created_at)
  end

  def bounded?
    starts_at.present? || ends_at.present?
  end

  def include?(timestamp)
    timestamp && (!starts_at || timestamp >= starts_at) && (!ends_at || timestamp < ends_at)
  end

  def query(cursor)
    times = [cursor, ends_at].compact
    { from: starts_at&.utc&.iso8601(6), to: times.min&.utc&.iso8601(ends_at ? 6 : 0) }.compact
  end

  private

  def related_conversations
    @related_conversations ||= begin
      conversations = @conversation.inbox.conversations.where(account_id: @conversation.account_id)
      conversations.where(contact_id: @conversation.contact_id).or(conversations.where(contact_inbox_id: @conversation.contact_inbox_id))
    end
  end

  def earlier
    table = Conversation.arel_table
    table[:created_at].lt(@conversation.created_at).or(same_time.and(table[:id].lt(@conversation.id)))
  end

  def later
    table = Conversation.arel_table
    table[:created_at].gt(@conversation.created_at).or(same_time.and(table[:id].gt(@conversation.id)))
  end

  def same_time
    Conversation.arel_table[:created_at].eq(@conversation.created_at)
  end
end
