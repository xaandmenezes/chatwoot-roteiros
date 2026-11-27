# Audience for dashboard events in the assignment-restricted inbox.
class Conversations::AssignmentRecipients
  def self.users(conversation)
    account_users = conversation.account.account_users
    members = conversation.inbox.inbox_members
    unless Conversations::AssignmentAccess.group?(conversation)
      members = members.where(supervisor: true).or(members.where(user_id: conversation.assignee_id))
    end

    permitted = account_users.administrator.or(account_users.where(user_id: members.select(:user_id)))
    User.where(id: permitted.select(:user_id))
  end
end
