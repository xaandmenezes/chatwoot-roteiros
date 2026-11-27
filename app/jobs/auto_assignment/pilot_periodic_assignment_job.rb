class AutoAssignment::PilotPeriodicAssignmentJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    inbox_id = Conversations::AssignmentAccess.inbox_id
    return unless inbox_id && AutoAssignment::PilotAssignmentService.start_at

    inbox = Inbox.find_by(id: inbox_id)
    return unless AutoAssignment::PilotAssignmentService.active?(inbox) && inbox.available_agents.exists?

    AutoAssignment::AssignmentJob.enqueue_for_inbox(inbox_id)
  end
end
