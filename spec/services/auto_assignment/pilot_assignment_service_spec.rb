require 'rails_helper'

RSpec.describe AutoAssignment::PilotAssignmentService do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:first_agent) { create(:user, account: account, role: :agent) }
  let(:second_agent) { create(:user, account: account, role: :agent) }
  let(:offline_agent) { create(:user, account: account, role: :agent) }
  let(:calls_only) { create(:user, account: account, role: :agent) }
  let(:outside_agent) { create(:user, account: account, role: :agent) }
  let(:start_at) { 14.days.ago.change(usec: 0) }
  let(:available_users) do
    {
      first_agent.id.to_s => 'online',
      second_agent.id.to_s => 'online',
      offline_agent.id.to_s => 'offline',
      calls_only.id.to_s => 'online',
      outside_agent.id.to_s => 'online'
    }
  end

  around do |example|
    with_modified_env(
      PSR_RESTRICTED_INBOX_ID: inbox.id.to_s,
      PSR_RANDOM_ASSIGNMENT_START_AT: start_at.iso8601,
      RYZE_INBOX_ID: inbox.id.to_s,
      RYZE_GROUPS_INBOX_ENABLED: 'false'
    ) { example.run }
  end

  before do
    inbox.update!(enable_auto_assignment: true)
    [first_agent, second_agent, offline_agent, calls_only].each { |user| create(:inbox_member, inbox: inbox, user: user) }
    calls_only.account_users.find_by!(account: account).update!(accepts_conversations: false, accepts_calls: true)
    allow(OnlineStatusTracker).to receive(:get_available_users).and_return(available_users)
    allow(AutoAssignment::AssignmentJob).to receive(:enqueue_for_inbox)
  end

  it 'submits a new direct conversation to the job and uses the pilot selector for a legacy inbox' do
    inbox.account.disable_features!('assignment_v2')
    expect(AutoAssignment::AssignmentJob).to receive(:enqueue_for_inbox).once.with(inbox.id)
    conversation = create(:conversation, account: account, inbox: inbox)

    expect(conversation.assignee).to be_nil
    AutoAssignment::AssignmentJob.perform_now(inbox_id: inbox.id)
    expect(conversation.reload.assignee_id).to be_in([first_agent.id, second_agent.id])
  end

  it 'keeps online-only assignment with the V2 rate limit' do
    inbox.account.reload.enable_features!('assignment_v2')
    expect(inbox).to be_auto_assignment_v2_enabled

    rate_limiter = instance_double(AutoAssignment::RateLimiter, within_limit?: false)
    allow(AutoAssignment::RateLimiter).to receive(:new).and_call_original
    allow(AutoAssignment::RateLimiter).to receive(:new).with(inbox: inbox, agent: first_agent).and_return(rate_limiter)

    conversation = create(:conversation, account: account, inbox: inbox)
    expect(described_class.new(inbox: inbox).perform_bulk_assignment).to eq(1)
    expect(conversation.reload.assignee).to eq(second_agent)
  end

  it 'draws from all and only eligible online agents and can repeat the same pick' do
    first = create(:conversation, account: account, inbox: inbox)
    second = create(:conversation, account: account, inbox: inbox)
    eligible = inbox.inbox_members.where(user_id: [first_agent.id, second_agent.id]).to_a
    service = described_class.new(inbox: inbox)

    allow(service).to receive(:sample_agent).and_call_original
    expect(service).to receive(:sample_agent).with(match_array(eligible)).twice.and_return(eligible.last.user)
    expect(service.perform_bulk_assignment).to eq(2)
    expect([first.reload.assignee, second.reload.assignee]).to eq([eligible.last.user, eligible.last.user])
  end

  it 'assigns the oldest eligible waiting conversation after agents return, even beyond the native age limit' do
    allow(OnlineStatusTracker).to receive(:get_available_users).and_return({})
    old = create(:conversation, account: account, inbox: inbox, created_at: 8.days.ago)
    newer = create(:conversation, account: account, inbox: inbox, created_at: 2.days.ago)
    pre_pilot = create(:conversation, account: account, inbox: inbox, created_at: 15.days.ago)
    service = described_class.new(inbox: inbox)

    expect(service.perform_bulk_assignment).to eq(0)
    allow(OnlineStatusTracker).to receive(:get_available_users).and_return(first_agent.id.to_s => 'online')

    expect(service.perform_bulk_assignment(limit: 1)).to eq(1)
    expect(old.reload.assignee).to eq(first_agent)
    expect([newer.reload.assignee_id, pre_pilot.reload.assignee_id]).to eq([nil, nil])
  end

  it 'keeps a confirmed WhatsApp group out of the queue even with the group menu disabled' do
    contact = create(:contact, account: account, identifier: '123456789@g.us')
    binding = create(:contact_inbox, contact: contact, inbox: inbox, source_id: contact.identifier)
    group = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: binding)
    direct = create(:conversation, account: account, inbox: inbox)
    expect(described_class.new(inbox: inbox).perform_bulk_assignment).to eq(1)
    expect(group.reload.assignee_id).to be_nil
    expect(direct.reload.assignee_id).to be_in([first_agent.id, second_agent.id])
  end

  it 'respects teams and does not let an unavailable team at the head starve the queue' do
    offline_team = create(:team, account: account, allow_auto_assign: true)
    create(:team_member, team: offline_team, user: offline_agent)
    online_team = create(:team, account: account, allow_auto_assign: true)
    create(:team_member, team: online_team, user: second_agent)
    waiting = create(:conversation, account: account, inbox: inbox, team: offline_team, created_at: 3.days.ago)
    eligible = create(:conversation, account: account, inbox: inbox, team: online_team)
    expect(described_class.new(inbox: inbox).perform_bulk_assignment(limit: 1)).to eq(1)
    expect(waiting.reload.assignee_id).to be_nil
    expect(eligible.reload.assignee).to eq(second_agent)
  end

  it 'cannot overwrite a transfer that commits after the candidate is picked' do
    conversation = create(:conversation, account: account, inbox: inbox)
    service = described_class.new(inbox: inbox)
    allow(service).to receive(:sample_agent) do
      conversation.update!(assignee: second_agent)
      first_agent
    end

    expect(service.perform_bulk_assignment).to eq(0)
    expect(conversation.reload.assignee).to eq(second_agent)
  end

  it 'keeps an existing owner when a conversation reopens or changes team' do
    conversation = create(:conversation, account: account, inbox: inbox, status: :resolved, assignee: offline_agent)
    conversation.update!(status: :open, team: create(:team, account: account, allow_auto_assign: true))

    expect(described_class.new(inbox: inbox).perform_bulk_assignment).to eq(0)
    expect(conversation.reload.assignee).to eq(offline_agent)
  end

  it 'does not run without an explicit start time' do
    conversation = create(:conversation, account: account, inbox: inbox)

    with_modified_env(PSR_RANDOM_ASSIGNMENT_START_AT: nil) do
      expect(described_class.new(inbox: inbox).perform_bulk_assignment).to eq(0)
    end
    expect(conversation.reload.assignee_id).to be_nil
  end
end
