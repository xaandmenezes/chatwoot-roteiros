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
end
