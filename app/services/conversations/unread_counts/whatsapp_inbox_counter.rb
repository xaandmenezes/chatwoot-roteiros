class Conversations::UnreadCounts::WhatsappInboxCounter
  def initialize(account:, user:)
    @account = account
    @user = user
  end

  def perform(counts)
    inbox = Ryze::GroupConversations.inbox(@account)
    return counts.merge(whatsapp_groups_count: 0) unless inbox

    total, group_count = count_unread(inbox)
    inbox_counts = counts.fetch(:inboxes).except(inbox.id.to_s)
    ordinary_count = total - group_count
    inbox_counts[inbox.id.to_s] = ordinary_count if ordinary_count.positive?

    counts.merge(all_count: inbox_counts.values.sum, inboxes: inbox_counts, whatsapp_groups_count: group_count)
  end

  private

  def count_unread(inbox)
    unread = @account.conversations.where(inbox_id: inbox.id).open.with_unread_incoming
    visible = Conversations::PermissionFilterService.new(unread, @user, @account).perform
    group_ids = Ryze::GroupConversations.scope(@account).select(:id)
    id = Conversation.arel_table[:id]

    # Count both halves in one snapshot so each unread conversation belongs to one total.
    group_weight = Arel::Nodes::Case.new.when(id.in(group_ids.arel)).then(1).else(0)
    group_total = Arel::Nodes::NamedFunction.new('SUM', [group_weight])
    total, groups = visible.unscope(:order).pick(id.count, group_total)
    [total.to_i, groups.to_i]
  end
end
