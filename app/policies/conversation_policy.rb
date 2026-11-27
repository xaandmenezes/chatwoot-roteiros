class ConversationPolicy < ApplicationPolicy
  def index?
    true
  end

  def destroy?
    administrator?
  end

  def show?
    return Conversations::AssignmentAccess.bot_allowed?(record, user) if agent_bot? && assignment_access_enabled?

    administrator? || agent_bot? || agent_can_view_conversation?
  end

  private

  def assignment_access_enabled?
    Conversations::AssignmentAccess.enabled?(record.inbox_id)
  end

  def agent_can_view_conversation?
    return Conversations::AssignmentAccess.allowed?(record, user) if assignment_access_enabled?

    inbox_access? || (team_access? && !Ryze::GroupConversations.group?(record))
  end

  def administrator?
    account_user&.administrator?
  end

  def agent_bot?
    user.is_a?(AgentBot)
  end

  def inbox_access?
    user_context.fetch(:inbox_access) do
      user.inboxes.where(account_id: account&.id).exists?(id: record.inbox_id)
    end
  end

  def team_access?
    return false if record.team_id.blank?

    user.teams.where(account_id: account&.id).exists?(id: record.team_id)
  end

  def assigned_to_user?
    record.assignee_id == user.id
  end

  def participant?
    user_context.fetch(:conversation_participant) do
      record.conversation_participants.exists?(user_id: user.id)
    end
  end
end

ConversationPolicy.prepend_mod_with('ConversationPolicy')
