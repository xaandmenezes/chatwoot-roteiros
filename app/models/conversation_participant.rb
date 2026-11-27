# == Schema Information
#
# Table name: conversation_participants
#
#  id              :bigint           not null, primary key
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :bigint           not null
#  conversation_id :bigint           not null
#  user_id         :bigint           not null
#
# Indexes
#
#  index_conversation_participants_on_account_id                   (account_id)
#  index_conversation_participants_on_conversation_id              (conversation_id)
#  index_conversation_participants_on_user_id                      (user_id)
#  index_conversation_participants_on_user_id_and_conversation_id  (user_id,conversation_id) UNIQUE
#
class ConversationParticipant < ApplicationRecord
  validates :account_id, presence: true
  validates :conversation_id, presence: true
  validates :user_id, presence: true
  validates :user_id, uniqueness: { scope: [:conversation_id] }
  validate :ensure_inbox_access

  belongs_to :account
  belongs_to :conversation
  belongs_to :user

  before_validation :ensure_account_id
  after_commit :invalidate_filtered_unread_count_visibility, on: [:create, :destroy]
  after_commit :notify_whatsapp_group_access_change, on: [:create, :destroy]

  private

  def ensure_account_id
    self.account_id = conversation&.account_id
  end

  def ensure_inbox_access
    errors.add(:user, 'must have inbox access') if conversation && conversation.inbox.assignable_agents.exclude?(user)
  end

  def notify_whatsapp_group_access_change
    return unless conversation&.persisted? && Ryze::GroupConversations.group?(conversation)

    return unless restricted_to_participating_conversations?

    ActionCableBroadcastJob.perform_later(
      [user.pubsub_token], 'conversation.whatsapp_group_access_changed', { account_id: account_id, conversation_id: conversation.display_id }
    )
  end

  def restricted_to_participating_conversations?
    account_user = account.account_users.find_by(user_id: user_id)
    return unless account_user&.agent? && account_user.custom_role_id.present?

    permissions = account_user.permissions
    permissions.include?('conversation_participating_manage') && !permissions.intersect?(%w[conversation_manage conversation_unassigned_manage])
  end

  def invalidate_filtered_unread_count_visibility
    ::Conversations::UnreadCounts::FilteredCountInvalidator.new(account).user_visibility_changed!(user_id: user_id)
  end
end
