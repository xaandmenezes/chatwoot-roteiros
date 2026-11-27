require 'rails_helper'

RSpec.describe AutoAssignment::PilotPeriodicAssignmentJob do
  let(:inbox) { create(:inbox, enable_auto_assignment: true) }
  let(:user) { create(:user, account: inbox.account, role: :agent) }

  before do
    create(:inbox_member, inbox: inbox, user: user)
    allow(OnlineStatusTracker).to receive(:get_available_users).with(inbox.account_id).and_return(user.id.to_s => 'online')
  end

  it 'wakes the pilot queue even for a legacy assignment inbox with no assignment policy' do
    inbox.account.disable_features!('assignment_v2')
    expect(AutoAssignment::AssignmentJob).to receive(:enqueue_for_inbox).with(inbox.id)

    with_modified_env(PSR_RESTRICTED_INBOX_ID: inbox.id.to_s, PSR_RANDOM_ASSIGNMENT_START_AT: 1.day.ago.iso8601) do
      described_class.perform_now
    end
  end

  it 'does not queue work before the cutoff or without online agents' do
    expect(AutoAssignment::AssignmentJob).not_to receive(:enqueue_for_inbox)
    with_modified_env(PSR_RESTRICTED_INBOX_ID: inbox.id.to_s, PSR_RANDOM_ASSIGNMENT_START_AT: 1.day.from_now.iso8601) do
      described_class.perform_now
    end

    allow(OnlineStatusTracker).to receive(:get_available_users).with(inbox.account_id).and_return({})
    with_modified_env(PSR_RESTRICTED_INBOX_ID: inbox.id.to_s, PSR_RANDOM_ASSIGNMENT_START_AT: 1.day.ago.iso8601) do
      described_class.perform_now
    end
  end
end
