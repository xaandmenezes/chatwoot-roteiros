class Conversations::AssignmentService
  class InvalidDestination < StandardError; end

  def initialize(conversation:, assignee_id:, assignee_type: nil, actor: nil, updates: {})
    @conversation = conversation
    @assignee_id = assignee_id
    @assignee_type = assignee_type
    @actor = actor
    @updates = updates
  end

  def perform
    return manual_transfer if restricted_actor?
    return bot_handoff if restricted_bot?

    agent_bot_assignment? ? assign_agent_bot : assign_agent
  end

  private

  def restricted_actor?
    @actor.is_a?(User) && Conversations::AssignmentAccess.enabled?(conversation.inbox_id)
  end

  def restricted_bot?
    @actor.is_a?(AgentBot) && Conversations::AssignmentAccess.enabled?(conversation.inbox_id)
  end

  def bot_handoff
    conversation.with_lock do
      raise Pundit::NotAuthorizedError unless Conversations::AssignmentAccess.bot_allowed?(conversation, @actor)
      raise Pundit::NotAuthorizedError if conversation.assignee_id?
      raise InvalidDestination if assignee_id.blank? || agent_bot_assignment? || !inbox_destination?

      assign_agent
    end
  end

  def manual_transfer
    conversation.with_lock do
      raise Pundit::NotAuthorizedError unless Conversations::AssignmentAccess.allowed?(conversation, @actor)
      raise InvalidDestination if agent_bot_assignment? || !inbox_destination?

      assign_agent
    end
  end

  def inbox_destination?
    if assignee_id.nil?
      return true if Conversations::AssignmentAccess.group?(conversation)

      return Conversations::AssignmentAccess.administrator?(conversation.account_id, @actor) ||
             conversation.inbox.inbox_members.exists?(user_id: @actor.id, supervisor: true)
    end

    assignee && conversation.inbox.inbox_members.exists?(user_id: assignee.id)
  end

  attr_reader :conversation, :assignee_id, :assignee_type

  def assign_agent
    conversation.with_lock do
      conversation.assign_attributes(@updates)
      if open_on_assignment? && conversation.pending?
        conversation.status = :open
        conversation.waiting_since = Time.current if conversation.waiting_since.blank?
      end
      conversation.assignee = assignee
      conversation.ai_assignee = nil
      conversation.save!
    end
    assignee
  end

  def assign_agent_bot
    assign_ai_assignee(agent_bot)
  end

  def open_on_assignment?
    assignee.present? && conversation.ai_assignee_type.present?
  end

  def assign_ai_assignee(ai_assignee)
    return unless ai_assignee

    conversation.with_lock do
      conversation.assignee = nil
      conversation.ai_assignee = ai_assignee
      conversation.status = :pending
      conversation.save!
    end
    ai_assignee
  end

  def assignee
    @assignee ||= conversation.account.users.find_by(id: assignee_id)
  end

  def agent_bot
    @agent_bot ||= AgentBot.accessible_to(conversation.account).find_by(id: assignee_id)
  end

  def agent_bot_assignment?
    assignee_type.to_s == 'AgentBot'
  end
end

Conversations::AssignmentService.prepend_mod_with('Conversations::AssignmentService')
