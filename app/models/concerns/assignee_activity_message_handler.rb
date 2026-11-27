module AssigneeActivityMessageHandler
  extend ActiveSupport::Concern

  private

  def create_assignee_change_activity(user_name)
    user_name = activity_message_owner(user_name)

    return unless user_name

    content = generate_assignee_change_activity_content(user_name)
    return unless content

    ::Conversations::ActivityMessageJob.perform_later(self, activity_message_params(content, content_attributes: assignment_activity_attributes))
  end

  def assignment_activity_attributes
    return unless Current.user.is_a?(User) && Conversations::AssignmentAccess.enabled?(inbox)

    previous_agent, new_agent = saved_change_to_assignee_id
    {
      activity: {
        type: 'conversation_assignee_changed',
        actor_id: Current.user.id,
        from_assignee_id: previous_agent,
        to_assignee_id: new_agent,
        occurred_at: updated_at.iso8601(6)
      }
    }
  end

  def generate_assignee_change_activity_content(user_name)
    params = { assignee_name: assignee&.name || '', user_name: user_name }
    key = assignee_id ? 'assigned' : 'removed'
    key = 'self_assigned' if self_assign? assignee_id
    I18n.t("conversations.activity.assignee.#{key}", **params)
  end

  def activity_message_owner(user_name)
    if !user_name && Current.executed_by.present?
      user_name = case Current.executed_by
                  when AssignmentPolicy
                    I18n.t('auto_assignment.policy_actor', policy_name: Current.executed_by.name)
                  when Inbox
                    I18n.t('auto_assignment.default_policy_name')
                  else
                    I18n.t('automation.system_name')
                  end
    end
    user_name
  end
end
