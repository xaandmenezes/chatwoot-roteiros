module AutoAssignmentHandler
  extend ActiveSupport::Concern
  include Events::Types

  included do
    before_save :run_legacy_auto_assignment, unless: [:new_record?, :pilot_assignment_inbox?]
    after_save :run_auto_assignment
  end

  private

  # Legacy (V1) assignment for status changes runs inside the same save, so status and
  # assignee commit as one change-set; a follow-up save would reset saved_changes and
  # hide the status change from the after_commit callbacks (no conversation.opened).
  def run_legacy_auto_assignment
    return unless status_changed? && open?
    return if inbox.auto_assignment_v2_enabled?
    return if will_save_change_to_assignee_id? && assignee_id.present?
    return unless should_run_auto_assignment?

    AutoAssignment::AgentAssignmentService.new(conversation: self, allowed_agent_ids: legacy_allowed_agent_ids).assign_under_lock
  end

  def run_auto_assignment
    return run_pilot_assignment if pilot_assignment_inbox?

    # Assignment V2: Also trigger assignment when conversation is resolved or snoozed,
    # bypassing the open-only condition so the AssignmentJob can redistribute capacity.
    return unless conversation_status_changed_to_open? || conversation_status_changed_to_resolved_or_snoozed?
    return unless should_run_auto_assignment?

    if inbox.auto_assignment_v2_enabled?
      enqueue_assignment
    elsif saved_change_to_id?
      # Legacy (V1) assignment for new conversations stays post-save: their status is only
      # finalized by before_create callbacks, which run after before_save.
      AutoAssignment::AgentAssignmentService.new(conversation: self, allowed_agent_ids: legacy_allowed_agent_ids).perform
    end
  end

  def pilot_assignment_inbox?
    inbox_id.present? && inbox_id == Conversations::AssignmentAccess.inbox_id
  end

  def run_pilot_assignment
    return unless AutoAssignment::PilotAssignmentService.active?(inbox)

    enqueue_assignment if pilot_assignment_candidate? || pilot_assignment_capacity_freed?
  end

  def pilot_assignment_candidate?
    return false unless pilot_assignment_relevant_change?
    return false unless open? && assignee_id.nil? && ai_assignee_type.nil?
    return false if created_at < AutoAssignment::PilotAssignmentService.start_at
    return false unless should_run_auto_assignment?

    !Conversations::AssignmentAccess.group?(self)
  end

  def pilot_assignment_relevant_change?
    conversation_status_changed_to_open? || saved_change_to_team_id? || saved_change_to_ai_assignee_type? || saved_change_to_assignee_agent_bot_id?
  end

  def pilot_assignment_capacity_freed?
    saved_change_to_status? && (resolved? || snoozed?)
  end

  def enqueue_assignment
    assignment_inbox_id = inbox_id
    ActiveRecord.after_all_transactions_commit { AutoAssignment::AssignmentJob.enqueue_for_inbox(assignment_inbox_id) }
  end

  def legacy_allowed_agent_ids
    # If conversation has a team, only consider team members for assignment
    team_id.present? ? team_member_ids_with_capacity : inbox.member_ids_with_assignment_capacity
  end

  def conversation_status_changed_to_resolved_or_snoozed?
    inbox.auto_assignment_v2_enabled? && saved_change_to_status? && (resolved? || snoozed?)
  end

  def team_member_ids_with_capacity
    return [] if team.blank? || team.allow_auto_assign.blank?

    inbox.member_ids_with_assignment_capacity & team.members.ids
  end

  def should_run_auto_assignment?
    return false unless inbox.enable_auto_assignment?
    # Assignment V2: Resolved/snoozed conversations still have an assignee, so bypass the
    # assignee-blank check below. The AssignmentJob needs to run to rebalance assignments.
    return true if conversation_status_changed_to_resolved_or_snoozed?
    return false if assignee_agent_bot_id.present?

    # run only if assignee is blank or doesn't have access to inbox
    assignee.blank? || inbox.members.exclude?(assignee)
  end
end
