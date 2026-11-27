require 'rails_helper'

RSpec.describe Conversation, type: :model do
  describe 'pilot assignment after a ringing call ends' do
    it 'resumes the pilot queue for the inbox instead of assigning synchronously with the legacy selector' do
      account = create(:account)
      account.disable_features!('assignment_v2')
      inbox = create(:inbox, account: account, enable_auto_assignment: true)
      conversation = create(:conversation, account: account, inbox: inbox, status: :open)

      expect(AutoAssignment::AgentAssignmentService).not_to receive(:new)
      expect(AutoAssignment::AssignmentJob).to receive(:enqueue_for_inbox).with(inbox.id)

      with_modified_env(PSR_RESTRICTED_INBOX_ID: inbox.id.to_s, PSR_RANDOM_ASSIGNMENT_START_AT: 1.day.ago.iso8601) do
        conversation.auto_assign_after_call
      end
    end
  end

  describe 'captain audience routing on create' do
    let(:account) { create(:account) }
    let(:inbox) { create(:inbox, account: account) }
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:us_contact) { create(:contact, account: account, additional_attributes: { 'country_code' => 'US' }) }
    let(:ca_contact) { create(:contact, account: account, additional_attributes: { 'country_code' => 'CA' }) }

    before do
      account.enable_features!('captain_integration')
      create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
      assistant.update!(config: assistant.config.merge('audience' => {
                                                         'attribute_key' => 'country_code', 'filter_operator' => 'equal_to', 'values' => ['US']
                                                       }))
    end

    it 'parks an in-audience contact conversation as pending' do
      conversation = create(:conversation, account: account, inbox: inbox, contact: us_contact)

      expect(conversation.status).to eq('pending')
      expect(conversation.ai_assignee).to eq(assistant)
    end

    it 'routes an out-of-audience contact conversation to open' do
      conversation = create(:conversation, account: account, inbox: inbox, contact: ca_contact)

      expect(conversation.status).to eq('open')
      expect(conversation.ai_assignee).to be_nil
    end

    it 'notifies assignment changes when only the AI owner type changes' do
      agent_bot = create(:agent_bot, id: assistant.id, account: account)
      conversation = create(:conversation, account: account, inbox: inbox, contact: us_contact)
      conversation.update!(ai_assignee: agent_bot)
      allow(Rails.configuration.dispatcher).to receive(:dispatch)

      conversation.update!(ai_assignee: assistant)

      expect(Rails.configuration.dispatcher).to have_received(:dispatch)
        .with(Conversation::ASSIGNEE_CHANGED, kind_of(Time), hash_including(
                                                               conversation: conversation,
                                                               changed_attributes: conversation.previous_changes
                                                             ))
    end
  end
end
