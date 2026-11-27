require 'rails_helper'

RSpec.describe ActionCableBroadcastJob do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:stale_data) { { id: conversation.display_id, account_id: account.id, status: 'open' } }

  before do
    conversation.update!(status: :resolved)
    allow(ActionCable.server).to receive(:broadcast)
  end

  it 'refreshes a conversation event with the full payload for agents and the widget payload for widget sessions' do
    described_class.perform_now(['agent-token'], Events::Types::CONVERSATION_STATUS_CHANGED, stale_data,
                                widget_members: ['widget-token'], widget_data: stale_data)

    expect(ActionCable.server).to have_received(:broadcast).with(
      'agent-token',
      { event: Events::Types::CONVERSATION_STATUS_CHANGED, data: conversation.reload.push_event_data.merge(account_id: account.id) }
    )
    expect(ActionCable.server).to have_received(:broadcast).with(
      'widget-token',
      { event: Events::Types::CONVERSATION_STATUS_CHANGED, data: conversation.reload.widget_push_event_data.merge(account_id: account.id) }
    )
  end

  it 'keeps the group classification on dashboard events when it refreshes a conversation' do
    jid = '120363000000000001@g.us'
    inbox = create(:channel_api, account: account).inbox
    contact = create(:contact, account: account, identifier: jid)
    binding = create(:contact_inbox, inbox: inbox, contact: contact, source_id: jid)
    group = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: binding)
    data = { id: group.display_id, account_id: account.id }
    event = Events::Types::CONVERSATION_UPDATED

    with_modified_env(RYZE_GROUPS_INBOX_ENABLED: 'true', RYZE_INBOX_ID: inbox.id.to_s) do
      described_class.perform_now(['agent-token'], event, data.merge(whatsapp_group: false))
      described_class.perform_now(['client-token'], event, data)
    end

    expect(ActionCable.server).to have_received(:broadcast).with(
      'agent-token', { event: event, data: hash_including(whatsapp_group: true) }
    ).once
    expect(ActionCable.server).to have_received(:broadcast).with(
      'client-token', { event: event, data: hash_excluding(:whatsapp_group) }
    ).once
  end

  it 'sends the prebuilt payloads for events that are not refreshed' do
    widget_data = { id: 1, account_id: account.id }
    described_class.perform_now(['agent-token'], Events::Types::MESSAGE_CREATED, { id: 1, content: 'hi', account_id: account.id },
                                widget_members: ['widget-token'], widget_data: widget_data)

    expect(ActionCable.server).to have_received(:broadcast).with(
      'agent-token', { event: Events::Types::MESSAGE_CREATED, data: { id: 1, content: 'hi', account_id: account.id } }
    )
    expect(ActionCable.server).to have_received(:broadcast).with(
      'widget-token', { event: Events::Types::MESSAGE_CREATED, data: widget_data }
    )
  end

  it 'sends widget sessions their payload when there are no agent members' do
    described_class.perform_now([], Events::Types::CONVERSATION_STATUS_CHANGED, stale_data,
                                widget_members: ['widget-token'], widget_data: stale_data)

    expect(ActionCable.server).to have_received(:broadcast).once.with(
      'widget-token',
      { event: Events::Types::CONVERSATION_STATUS_CHANGED, data: conversation.reload.widget_push_event_data.merge(account_id: account.id) }
    )
  end

  context 'with inbox assignment restrictions' do
    let(:account) { create(:account) }
    let(:inbox) { create(:channel_api, account: account).inbox }
    let(:owner) { create(:user, account: account, role: :agent) }
    let(:destination) { create(:user, account: account, role: :agent) }
    let(:supervisor) { create(:user, account: account, role: :agent) }
    let(:admin) { create(:user, account: account, role: :administrator) }
    let(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: owner) }

    around do |example|
      with_modified_env(PSR_RESTRICTED_INBOX_ID: inbox.id.to_s) { example.run }
    end

    before do
      [owner, destination].each { |agent| create(:inbox_member, inbox: inbox, user: agent) }
      create(:inbox_member, inbox: inbox, user: supervisor, supervisor: true)
    end

    it 'rechecks queued socket delivery against the new owner and per-inbox supervisor' do
      foreign_agent = create(:user, account: account, role: :agent)
      members = [owner, destination, supervisor, admin, foreign_agent].map(&:pubsub_token)
      conversation.update!(assignee: destination)
      allow(ActionCable.server).to receive(:broadcast)
      data = { account_id: account.id, content: 'local test' }

      described_class.perform_now(members, Events::Types::MESSAGE_CREATED, data, restricted_conversation_id: conversation.id)

      [destination, supervisor, admin].each do |user|
        expect(ActionCable.server).to have_received(:broadcast).with(user.pubsub_token, { event: Events::Types::MESSAGE_CREATED, data: data })
      end
      [owner, foreign_agent].each { |user| expect(ActionCable.server).not_to have_received(:broadcast).with(user.pubsub_token, anything) }
    end

    it 'queues a content-free eviction for the former owner and withholds the customer socket token' do
      conversation
      expect do
        conversation.update!(assignee: destination)
      end.to have_enqueued_job(described_class).with([owner.pubsub_token], 'conversation.access_revoked',
                                                     { conversation_id: conversation.display_id, account_id: account.id })
      expect(conversation.push_event_data.fetch(:contact_inbox)).not_to have_key('pubsub_token')
    end

    it 'removes existing notifications from counts and suppresses delayed push and email after transfer' do
      notification = create(:notification, account: account, user: owner, primary_actor: conversation)
      expect(NotificationFinder.new(owner, account).notifications).to include(notification)
      conversation.update!(assignee: destination)
      expect(NotificationFinder.new(owner, account).unread_count).to eq(0)
      expect(notification.reload).not_to be_deliverable
      expect { Notification::EmailNotificationService.new(notification: notification).perform }.not_to have_enqueued_mail
      push_service = Notification::PushNotificationService.new(notification: notification)
      expect(push_service).not_to receive(:notification_subscriptions)
      push_service.perform
    end
  end
end
