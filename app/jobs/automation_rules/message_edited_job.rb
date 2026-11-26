class AutomationRules::MessageEditedJob < ApplicationJob
  self.enqueue_after_transaction_commit = true
  self.log_arguments = false
  queue_as :medium

  def perform(message, revision, content, occurred_at)
    return if message.deleted || message.activity? || message.auto_reply_email?
    return if occurred_at < AutomationRulePendingExecution::RETENTION_WINDOW.ago

    # A queued edit can run after another edit. Both the text filter and Captain
    # must see this revision, while conversation conditions still use live state.
    message.content = content
    rules = message.account.automation_rules.active.where(event_name: 'message_edited', execution_delay: nil, created_at: ..occurred_at)
    rules.find_each do |rule|
      next unless AutomationRules::ConditionsFilterService.new(rule, message.conversation, message: message, edited_content: content).perform

      execute_once(rule, message, revision, occurred_at)
    end
  end

  private

  def execute_once(rule, message, revision, occurred_at)
    # The unique episode index elects one worker before any side effect. A crash
    # during actions leaves an executing row for the existing sweep to report.
    key = "edit:#{message.id}:#{revision}"
    execution = rule.pending_executions.create_or_find_by!(conversation_id: message.conversation_id, episode_key: key) do |row|
      row.assign_attributes(account_id: message.account_id, message_id: message.id, status: :executing, due_at: occurred_at)
    end
    return unless execution.previously_new_record?

    AutomationRules::ActionService.new(rule, message.account, message.conversation).perform
    execution.update!(status: :executed)
  end
end
