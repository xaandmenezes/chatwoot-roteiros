class Conversations::AssignmentAccess
  class << self
    def inbox_id
      value = Integer(ENV.fetch('PSR_RESTRICTED_INBOX_ID', ''), 10, exception: false)
      value if value&.between?(1, (2**63) - 1)
    end

    def enabled?(inbox)
      configured_id = inbox_id
      configured_id.present? && configured_id == (inbox.is_a?(Inbox) ? inbox.id : inbox)
    end

    def allowed?(conversation, user)
      return false unless user.is_a?(User)

      role = account_role(conversation.account_id, user)
      return true if role == 'administrator'
      return false unless role == 'agent'

      membership = InboxMember.find_by(inbox_id: conversation.inbox_id, user_id: user.id)
      membership.present? && (membership.supervisor? || conversation.assignee_id == user.id || group?(conversation))
    end

    def bot_allowed?(conversation, bot)
      AgentBotInbox.active.exists?(account_id: conversation.account_id, inbox_id: conversation.inbox_id, agent_bot_id: bot.id)
    end

    def scope(relation, user, account)
      restricted_inbox_id = inbox_id
      return relation unless restricted_inbox_id

      outside = relation.where.not(inbox_id: restricted_inbox_id)
      outside.or(relation.where(id: visible_pilot(account, user).select(:id)))
    end

    def visible_pilot(account, user)
      return account.conversations.none unless inbox_id && user.is_a?(User)

      role = account_role(account.id, user)
      pilot = account.conversations.where(inbox_id: inbox_id)
      return pilot if role == 'administrator'
      return pilot.none unless role == 'agent'

      membership = InboxMember.find_by(inbox_id: inbox_id, user_id: user.id)
      return pilot.none unless membership
      return pilot if membership.supervisor?

      pilot.assigned_to(user).or(pilot.where(id: group_scope(account).select(:id)))
    end

    def group_scope(account)
      Ryze::GroupConversations.scope(account, inbox_id: inbox_id)
    end

    def group?(conversation)
      Ryze::GroupConversations.group?(conversation, inbox_id: inbox_id)
    end

    def administrator?(account_id, user)
      account_role(account_id, user) == 'administrator'
    end

    private

    def account_role(account_id, user)
      AccountUser.find_by(account_id: account_id, user_id: user.id)&.role if user.is_a?(User)
    end
  end
end
