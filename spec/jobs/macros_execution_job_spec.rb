require 'rails_helper'

RSpec.describe MacrosExecutionJob do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :open) }
  let(:macro) { create(:macro, account: account, actions: [{ 'action_name' => 'resolve_conversation' }]) }

  context 'when the user is an administrator' do
    let(:user) { create(:user, account: account, role: :administrator) }

    it 'executes without inbox membership' do
      described_class.perform_now(macro, conversation_ids: [conversation.display_id], user: user)

      expect(conversation.reload).to be_resolved
    end
  end

  context 'when the user belongs to the inbox' do
    before { create(:inbox_member, user: user, inbox: inbox) }

    it 'executes the macro' do
      described_class.perform_now(macro, conversation_ids: [conversation.display_id], user: user)

      expect(conversation.reload).to be_resolved
    end

    it 'skips inaccessible conversations and continues executing accessible ones' do
      forbidden_conversation = create(:conversation, account: account, status: :open)

      described_class.perform_now(macro, conversation_ids: [forbidden_conversation.display_id, conversation.display_id], user: user)

      expect(forbidden_conversation.reload).to be_open
      expect(conversation.reload).to be_resolved
    end

    it 'rechecks inbox access when a queued job runs' do
      described_class.perform_later(macro, conversation_ids: [conversation.display_id], user: user)
      inbox.inbox_members.find_by!(user: user).destroy!

      expect(Macros::ExecutionService).not_to receive(:new)

      perform_enqueued_jobs(only: described_class)

      expect(conversation.reload).to be_open
    end

    it 'skips execution and logs when account membership is removed after enqueueing' do
      described_class.perform_later(macro, conversation_ids: [conversation.display_id], user: user)
      account.account_users.find_by!(user: user).destroy!
      allow(Rails.logger).to receive(:info).and_call_original

      expect(Macros::ExecutionService).not_to receive(:new)

      perform_enqueued_jobs(only: described_class)

      expect(conversation.reload).to be_open
      expect(Rails.logger).to have_received(:info).with({
        event: 'macro_execution_skipped',
        reason: 'missing_account_membership',
        account_id: account.id,
        macro_id: macro.id,
        user_id: user.id,
        conversation_ids: [conversation.id],
        conversation_display_ids: [conversation.display_id]
      }.to_json).once
    end
  end

  context 'when the user belongs to the conversation team' do
    let(:team) { create(:team, account: account, allow_auto_assign: false) }
    let(:conversation) { create(:conversation, account: account, inbox: inbox, team: team, status: :open) }

    before { create(:team_member, user: user, team: team) }

    it 'executes without inbox membership' do
      described_class.perform_now(macro, conversation_ids: [conversation.display_id], user: user)

      expect(conversation.reload).to be_resolved
    end

    it 'rechecks team access when a queued job runs' do
      described_class.perform_later(macro, conversation_ids: [conversation.display_id], user: user)
      team.team_members.find_by!(user: user).destroy!

      expect(Macros::ExecutionService).not_to receive(:new)

      perform_enqueued_jobs(only: described_class)

      expect(conversation.reload).to be_open
    end
  end

  context 'with an assignment-restricted inbox' do
    let(:other_agent) { create(:user, account: account, role: :agent) }
    let(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: user) }
    let(:macro) { create(:macro, account: account, actions: actions, created_by: user) }

    around do |example|
      with_modified_env(PSR_RESTRICTED_INBOX_ID: inbox.id.to_s) { example.run }
    end

    before do
      create(:inbox_member, user: user, inbox: inbox)
      create(:inbox_member, user: other_agent, inbox: inbox)
    end

    context 'when the macro transfers the conversation and then sends a reply' do
      let(:actions) do
        [
          { 'action_name' => 'assign_agent', 'action_params' => [other_agent.id] },
          { 'action_name' => 'send_message', 'action_params' => ['After transfer'] }
        ]
      end

      it 'stops executing former owner actions as soon as the transfer commits' do
        described_class.perform_now(macro, conversation_ids: [conversation.display_id], user: user)

        expect(conversation.reload.assignee).to eq(other_agent)
        expect(conversation.messages.outgoing.where(content: 'After transfer')).not_to exist
      end
    end

    context 'when the macro removes the current owner' do
      let(:actions) { [{ 'action_name' => 'remove_assigned_agent', 'action_params' => [] }] }

      it 'keeps an ordinary agent from moving their conversation to the unassigned queue' do
        expect do
          described_class.perform_now(macro, conversation_ids: [conversation.display_id], user: user)
        end.not_to(change { conversation.reload.assignee_id })
      end

      it 'lets the authorized supervisor move the conversation to the unassigned queue' do
        inbox.inbox_members.find_by!(user: user).update!(supervisor: true)

        described_class.perform_now(macro, conversation_ids: [conversation.display_id], user: user)

        expect(conversation.reload.assignee_id).to be_nil
      end
    end
  end

  context 'when the user cannot view the conversation' do
    it 'skips all macro actions and logs the denied conversation' do
      allow(Rails.logger).to receive(:info).and_call_original
      expect(Macros::ExecutionService).not_to receive(:new)

      described_class.perform_now(macro, conversation_ids: [conversation.display_id], user: user)

      expect(conversation.reload).to be_open
      expect(Rails.logger).to have_received(:info).with({
        event: 'macro_execution_skipped',
        reason: 'conversation_access_denied',
        account_id: account.id,
        macro_id: macro.id,
        user_id: user.id,
        conversation_ids: [conversation.id],
        conversation_display_ids: [conversation.display_id]
      }.to_json).once
    end
  end
end
