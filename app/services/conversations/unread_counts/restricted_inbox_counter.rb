class Conversations::UnreadCounts::RestrictedInboxCounter
  pattr_initialize [:account!, :user!]

  def inbox_id
    return @inbox_id if defined?(@inbox_id)

    configured_id = Conversations::AssignmentAccess.inbox_id
    @inbox_id = nil
    return unless configured_id && user.inboxes.where(account_id: account.id).exists?(id: configured_id)
    return if Conversations::AssignmentAccess.administrator?(account.id, user)

    @inbox_id = configured_id
  end

  def perform(counts)
    return counts unless inbox_id

    # Ownership and group membership must be checked against current PostgreSQL rows.
    @unread = Conversations::AssignmentAccess.visible_pilot(account, user).open.with_unread_incoming
    count = @unread.count
    return counts if count.zero?

    counts.merge(
      all_count: counts.fetch(:all_count) + count,
      inboxes: counts.fetch(:inboxes).merge(inbox_id.to_s => count),
      labels: add_counts(counts.fetch(:labels), label_counts),
      teams: add_counts(counts.fetch(:teams), team_counts)
    )
  end

  private

  def team_counts
    @unread.where(team_id: user.teams.where(account: account).select(:id)).group(:team_id).count
  end

  def label_counts
    labels = account.labels.where(show_on_sidebar: true).pluck(:title, :id).to_h
    @unread.joins(:labels)
           .where(tags: { name: labels.keys })
           .group('tags.name').distinct.count(:id).transform_keys { |name| labels.fetch(name) }
  end

  def add_counts(legacy_counts, pilot_counts)
    legacy_counts.merge(pilot_counts.stringify_keys) { |_id, legacy_count, pilot_count| legacy_count + pilot_count }
  end
end
