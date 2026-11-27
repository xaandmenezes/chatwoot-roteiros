# == Schema Information
#
# Table name: inbox_members
#
#  id         :integer          not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  inbox_id   :integer          not null
#  supervisor :boolean          default(FALSE), not null
#  user_id    :integer          not null
#
# Indexes
#
#  index_inbox_members_on_inbox_id              (inbox_id)
#  index_inbox_members_on_inbox_id_and_user_id  (inbox_id,user_id) UNIQUE
#

class InboxMember < ApplicationRecord
  validates :inbox_id, presence: true
  validates :user_id, presence: true
  validates :user_id, uniqueness: { scope: :inbox_id }

  belongs_to :user
  belongs_to :inbox

  after_create :add_agent_to_round_robin
  after_destroy :remove_agent_from_round_robin
  after_commit :invalidate_filtered_unread_count_visibility, on: [:create, :destroy]
  after_create_commit :publish_access_grant
  after_update_commit :publish_supervision_change, if: :saved_change_to_supervisor?
  after_destroy_commit :publish_access_revocation

  def access_level
    supervisor? ? 'supervisor' : 'agent'
  end

  private

  def publish_access_grant
    publish_access_change('none', access_level)
  end

  def publish_supervision_change
    invalidate_filtered_unread_count_visibility
    publish_access_change(supervisor_before_last_save ? 'supervisor' : 'agent', access_level)
  end

  def publish_access_revocation
    publish_access_change(access_level, 'none')
  end

  def publish_access_change(previous_level, new_level)
    return unless inbox_id == Conversations::AssignmentAccess.inbox_id && inbox

    occurred_at = Time.current
    Rails.logger.info({
      event: 'inbox_member_access_changed',
      account_id: inbox.account_id,
      inbox_id: inbox_id,
      user_id: user_id,
      actor_id: Current.user&.id,
      previous_level: previous_level,
      access_level: new_level,
      occurred_at: occurred_at.iso8601
    }.to_json)
    Rails.configuration.dispatcher.dispatch(Events::Types::INBOX_MEMBER_ACCESS_CHANGED, occurred_at, inbox: inbox, user: user)
  end

  def add_agent_to_round_robin
    ::AutoAssignment::InboxRoundRobinService.new(inbox: inbox).add_agent_to_queue(user_id)
  end

  def remove_agent_from_round_robin
    ::AutoAssignment::InboxRoundRobinService.new(inbox: inbox).remove_agent_from_queue(user_id) if inbox.present?
  end

  def invalidate_filtered_unread_count_visibility
    ::Conversations::UnreadCounts::FilteredCountInvalidator.new(inbox&.account).user_visibility_changed!(user_id: user_id)
  end
end

InboxMember.include_mod_with('Audit::InboxMember')
