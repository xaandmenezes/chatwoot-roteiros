class BulkActionsJob < ApplicationJob
  include DateRangeHelper

  queue_as :medium
  attr_accessor :records

  MODEL_TYPE = ['Conversation'].freeze

  def perform(account:, params:, user:)
    @account = account
    @user = user
    Current.user = user
    @params = params
    @records = records_to_updated(params[:ids])
    bulk_update
  ensure
    Current.reset
  end

  def bulk_update
    bulk_remove_labels
    bulk_conversation_update
  end

  def bulk_conversation_update
    params = available_params(@params)
    records.each do |conversation|
      if Conversations::AssignmentAccess.enabled?(conversation.inbox_id)
        update_restricted_conversation(conversation, params)
      else
        update_conversation(conversation, params)
      end
    end
  end

  def bulk_remove_labels
    records.each do |conversation|
      next if Conversations::AssignmentAccess.enabled?(conversation.inbox_id)

      remove_labels(conversation)
    end
  end

  def update_restricted_conversation(conversation, params)
    conversation.with_lock do
      next unless Conversations::AssignmentAccess.allowed?(conversation, @user)

      updates = restricted_bulk_updates(conversation, params)
      if updates.key?(:assignee_id)
        assignee_id = updates.delete(:assignee_id)
        Conversations::AssignmentService.new(conversation: conversation, actor: @user, assignee_id: assignee_id, updates: updates).perform
      else
        conversation.update(updates)
      end
    end
  rescue Conversations::AssignmentService::InvalidDestination, Pundit::NotAuthorizedError
    nil
  end

  def restricted_bulk_updates(conversation, params)
    updates = (params || {}).with_indifferent_access
    operation = @params[:labels]
    if operation.present?
      current_labels = conversation.label_list - Array(operation[:remove])
      updates[:label_list] = current_labels + Array(operation[:add])
    end
    updates[:snoozed_until] = parse_date_time(@params[:snoozed_until].to_s) if @params[:snoozed_until]
    updates
  end

  def update_conversation(conversation, params)
    bulk_add_labels(conversation)
    bulk_snoozed_until(conversation)
    conversation.update(params) if params
  end

  def available_params(params)
    return unless params[:fields]

    params[:fields].delete_if { |key, value| value.nil? && key == 'status' }
  end

  def bulk_add_labels(conversation)
    conversation.add_labels(@params[:labels][:add]) if @params[:labels] && @params[:labels][:add]
  end

  def bulk_snoozed_until(conversation)
    conversation.snoozed_until = parse_date_time(@params[:snoozed_until].to_s) if @params[:snoozed_until]
  end

  def remove_labels(conversation)
    return unless @params[:labels] && @params[:labels][:remove]

    labels = conversation.label_list - @params[:labels][:remove]
    conversation.update(label_list: labels)
  end

  def records_to_updated(ids)
    current_model = @params[:type].camelcase
    return unless MODEL_TYPE.include?(current_model)

    scope = current_model.constantize.where(account_id: @account.id, display_id: ids)
    Conversations::PermissionFilterService.new(scope, @user, @account).perform
  end
end
