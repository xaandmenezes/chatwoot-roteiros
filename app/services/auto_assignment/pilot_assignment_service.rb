class AutoAssignment::PilotAssignmentService < AutoAssignment::AssignmentService
  class << self
    def start_at
      configured = ENV.fetch('PSR_RANDOM_ASSIGNMENT_START_AT', nil)
      return unless configured&.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)

      Time.iso8601(configured)
    rescue ArgumentError
      nil
    end

    def active?(inbox)
      return false unless Conversations::AssignmentAccess.enabled?(inbox) && inbox.enable_auto_assignment?

      cutoff = start_at
      cutoff.present? && cutoff <= Time.current
    end

    def wake_for_user(account_id:, user_id:)
      inbox_id = Conversations::AssignmentAccess.inbox_id
      return unless inbox_id && start_at

      inbox = Inbox.find_by(id: inbox_id, account_id: account_id)
      return unless active?(inbox) && inbox.available_agents.exists?(user_id: user_id)

      AutoAssignment::AssignmentJob.enqueue_for_inbox(inbox_id)
    end
  end

  private

  def enabled?
    self.class.active?(inbox)
  end

  def uses_assignment_rate_limit?
    inbox.auto_assignment_v2_enabled?
  end

  def uses_legacy_capacity_limit?
    !inbox.auto_assignment_v2_enabled?
  end

  def expiring_queue?
    false
  end

  def find_available_agent(conversation)
    sample_agent(eligible_agents(conversation))
  end

  def sample_agent(agents)
    agents.sample&.user
  end

  def unassigned_conversations(limit)
    agent_ids = eligible_agents.map(&:user_id)
    return Conversation.none if agent_ids.empty?

    scope = apply_queue_exclusions(waiting_conversations)
    teams = inbox.account.teams.where(allow_auto_assign: true, id: TeamMember.where(user_id: agent_ids).select(:team_id))
    scope.where(team_id: nil).or(scope.where(team_id: teams.select(:id))).reorder(waiting_order, :id).limit(limit)
  end

  def waiting_conversations
    after_cutoff = Conversation.arel_table[:created_at].gteq(self.class.start_at)
    groups = Conversations::AssignmentAccess.group_scope(inbox.account).unassigned.open.where(after_cutoff)
    inbox.conversations.unassigned.open
         .where(account_id: inbox.account_id, ai_assignee_type: nil)
         .where(after_cutoff)
         .where.not(id: groups.select(:id))
  end

  def waiting_order
    conversations = Conversation.arel_table
    Arel::Nodes::NamedFunction.new('COALESCE', [conversations[:waiting_since], conversations[:created_at]]).asc
  end

  def claimable?(locked, conversation, agent)
    return false unless locked && locked.team_id == conversation.team_id
    return false unless locked.ai_assignee_type.nil? && assignable?(locked) && !Conversations::AssignmentAccess.group?(locked)

    inbox.inbox_members.exists?(user_id: agent.id)
  end

  def dispatch_assignment_event(_conversation, _agent)
    # The conversation's after_commit sends the assignment change and its provenance.
  end
end
