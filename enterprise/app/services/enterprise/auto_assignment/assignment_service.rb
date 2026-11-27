module Enterprise::AutoAssignment::AssignmentService
  private

  # Override assignment config to use policy if available
  def assignment_config
    return super unless policy

    {
      'conversation_priority' => policy.conversation_priority,
      'fair_distribution_limit' => policy.fair_distribution_limit,
      'fair_distribution_window' => policy.fair_distribution_window,
      'balanced' => policy.balanced?
    }.compact
  end

  # A run's batch can predate the call, so a conversation is rechecked before it is claimed
  def assignable?(conversation)
    super && !(inbox.rings_for_calls? && conversation.calls.holding_assignment.exists?)
  end

  def find_available_agent(conversation = nil)
    agents = eligible_agents(conversation)
    return if agents.empty?

    selector = policy&.balanced? && account.feature_enabled?('advanced_assignment') ? balanced_selector : round_robin_selector
    selector.select_agent(agents)
  end

  def eligible_agents(conversation = nil)
    agents = super
    return agents unless uses_legacy_capacity_limit?

    allowed_ids = inbox.member_ids_with_assignment_capacity.to_set
    agents.select { |member| allowed_ids.include?(member.user_id) }
  end

  def filter_agents_by_rate_limit(agents)
    filter_agents_by_capacity(super)
  end

  def filter_agents_by_capacity(agents)
    return agents unless capacity_filtering_enabled?

    capacity_service = Enterprise::AutoAssignment::CapacityService.new
    agents.select { |agent_member| capacity_service.agent_has_capacity?(agent_member.user, inbox) }
  end

  def capacity_filtering_enabled?
    account.feature_enabled?('advanced_assignment') &&
      account.account_users.joins(:agent_capacity_policy).exists?
  end

  def round_robin_selector
    @round_robin_selector ||= AutoAssignment::RoundRobinSelector.new(inbox: inbox)
  end

  def balanced_selector
    @balanced_selector ||= Enterprise::AutoAssignment::BalancedSelector.new(inbox: inbox)
  end

  def policy
    @policy ||= inbox.assignment_policy
  end

  def account
    inbox.account
  end

  def apply_queue_exclusions(scope)
    eligible = apply_exclusion_rules(super(scope))

    # A conversation whose inbound call is ringing waits for the agent who answers.
    inbox.rings_for_calls? ? eligible.where.not(id: inbox.calls.holding_assignment.select(:conversation_id)) : eligible
  end

  def apply_exclusion_rules(scope)
    capacity_policy = inbox.inbox_capacity_limits.first&.agent_capacity_policy
    return scope unless capacity_policy

    rules = capacity_policy.exclusion_rules || {}
    scope = apply_label_exclusions(scope, rules['excluded_labels'])
    expiring_queue? ? apply_age_exclusions(scope, rules['exclude_older_than_hours']) : scope
  end

  def apply_label_exclusions(scope, excluded_labels)
    return scope if excluded_labels.blank?

    scope.tagged_with(excluded_labels, exclude: true, on: :labels)
  end
end
