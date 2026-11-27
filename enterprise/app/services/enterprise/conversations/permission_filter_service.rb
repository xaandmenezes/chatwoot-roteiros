module Enterprise::Conversations::PermissionFilterService
  def perform
    return super unless user_has_custom_role?

    legacy_scope = filter_by_permissions(permissions)
    inbox_id = Conversations::AssignmentAccess.inbox_id
    return legacy_scope unless inbox_id

    visible_pilot = Conversations::AssignmentAccess.visible_pilot(account, user)
    conversations.where(id: legacy_scope.where.not(inbox_id: inbox_id).reselect(:id)).or(conversations.where(id: visible_pilot.select(:id)))
  end

  private

  def user_has_custom_role?
    user_role == 'agent' && account_user&.custom_role_id.present?
  end

  def permissions
    account_user&.permissions || []
  end

  def filter_by_permissions(permissions)
    # Permission-based filtering with hierarchy
    # conversation_manage > conversation_unassigned_manage > conversation_participating_manage
    if permissions.include?('conversation_manage')
      accessible_conversations
    elsif permissions.include?('conversation_unassigned_manage')
      filter_unassigned_and_mine
    elsif permissions.include?('conversation_participating_manage')
      filter_participating_and_mine
    else
      Conversation.none
    end
  end

  def filter_participating_and_mine
    conversations = accessible_conversations
    participant_conversation_ids = ConversationParticipant.where(account_id: account.id, user_id: user.id).select(:conversation_id)

    conversations
      .where(assignee_id: user.id)
      .or(conversations.where(id: participant_conversation_ids))
  end

  def filter_unassigned_and_mine
    conversations = accessible_conversations
    conversations.unassigned.or(conversations.assigned_to(user))
  end
end
