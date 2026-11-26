require 'rails_helper'
describe ActionCableListener do
  let(:listener) { described_class.instance }
  let!(:account) { create(:account) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:agent) { create(:user, account: account, role: :agent) }
  let!(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: agent) }

  before do
    create(:inbox_member, inbox: inbox, user: agent)
    Current.user = nil
    Current.account = nil
  end

  describe '#conversation_created' do
    it 'includes contact labels on the dashboard event and excludes them from customer events' do
      api_inbox = create(:inbox, account: account, channel: create(:channel_api, account: account))
      create(:inbox_member, inbox: api_inbox, user: agent)
      api_conversation = create(:conversation, account: account, inbox: api_inbox)
      api_conversation.contact.update_labels(['direct-insta'])
      api_conversation.contact_inbox.update!(hmac_verified: true)
      widget_session = create(:contact_inbox, contact: api_conversation.contact, inbox: inbox, hmac_verified: true)
      event = Events::Base.new(:'conversation.created', Time.current, conversation: api_conversation)
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      listener.conversation_created(event)

      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        a_collection_containing_exactly(agent.pubsub_token, admin.pubsub_token),
        'conversation.created',
        hash_including(contact_labels: ['direct-insta']),
        widget_members: [widget_session.pubsub_token],
        widget_data: hash_excluding(:contact_labels)
      ).once
      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        [api_conversation.contact_inbox.pubsub_token],
        'conversation.created',
        hash_excluding(:contact_labels)
      ).once
    end
  end

  describe '#conversation_contact_changed' do
    it 'sends the replacement contact labels to inbox agents and account admins' do
      conversation.contact.update_labels(['direct-insta'])
      event = Events::Base.new(:'conversation.contact_changed', Time.current, conversation: conversation)

      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        a_collection_containing_exactly(agent.pubsub_token, admin.pubsub_token),
        'conversation.contact_changed',
        hash_including(contact_labels: ['direct-insta'])
      )

      listener.conversation_contact_changed(event)
    end
  end

  describe '#conversation_bot_handoff' do
    let(:event) { Events::Base.new(:'conversation.bot_handoff', Time.zone.now, conversation: conversation) }

    it 'broadcasts the handoff to inbox agents and account admins only' do
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        a_collection_containing_exactly(agent.pubsub_token, admin.pubsub_token),
        'conversation.bot_handoff',
        conversation.push_event_data.merge(account_id: account.id)
      )

      listener.conversation_bot_handoff(event)
    end

    it 'includes the performer so dashboards can distinguish human takeovers' do
      Current.user = agent
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        a_collection_containing_exactly(agent.pubsub_token, admin.pubsub_token),
        'conversation.bot_handoff',
        conversation.push_event_data.merge(account_id: account.id, performer: agent.push_event_data)
      )

      listener.conversation_bot_handoff(event)
    end
  end

  describe '#account_cache_invalidated' do
    let!(:event) do
      Events::Base.new(
        :'account.cache_invalidated',
        Time.zone.now,
        account: account,
        cache_keys: account.cache_keys
      )
    end

    it 'sends cache invalidation to account agents and admins' do
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        a_collection_containing_exactly(agent.pubsub_token, admin.pubsub_token),
        'account.cache_invalidated',
        {
          cache_keys: account.cache_keys,
          account_id: account.id
        }
      )

      listener.account_cache_invalidated(event)
    end
  end

  describe '#message_created' do
    let(:event_name) { :'message.created' }
    let!(:message) do
      create(:message, message_type: 'incoming', sender: conversation.contact,
                       account: account, inbox: inbox, conversation: conversation)
    end
    let!(:event) { Events::Base.new(event_name, Time.zone.now, message: message) }

    it 'sends the full message to agents and the widget payload to the web widget session in one job' do
      # HACK: to reload conversation inbox members
      expect(conversation.inbox.reload.inbox_members.count).to eq(1)
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      listener.message_created(event)

      expect(ActionCableBroadcastJob).to have_received(:perform_later).once.with(
        a_collection_containing_exactly(agent.pubsub_token, admin.pubsub_token),
        'message.created',
        message.push_event_data.merge(account_id: account.id),
        widget_members: [conversation.contact_inbox.pubsub_token],
        widget_data: message.widget_push_event_data.merge(account_id: account.id)
      )
    end

    it 'sends the widget payload to all hmac verified contact inboxes' do
      conversation.contact_inbox.update(hmac_verified: true)
      # creating a non verified contact inbox to ensure the events are not sent to it
      create(:contact_inbox, contact: conversation.contact, inbox: inbox)
      verified_contact_inbox = create(:contact_inbox, contact: conversation.contact, inbox: inbox, hmac_verified: true)
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      listener.message_created(event)

      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        anything,
        'message.created',
        anything,
        widget_members: a_collection_containing_exactly(conversation.contact_inbox.pubsub_token, verified_contact_inbox.pubsub_token),
        widget_data: message.widget_push_event_data.merge(account_id: account.id)
      )
    end

    it 'sends each verified session the payload of its own inbox' do
      conversation.contact_inbox.update(hmac_verified: true)
      api_inbox = create(:inbox, account: account, channel: create(:channel_api, account: account))
      api_session = create(:contact_inbox, contact: conversation.contact, inbox: api_inbox, hmac_verified: true)
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      listener.message_created(event)

      expect(ActionCableBroadcastJob).to have_received(:perform_later).once.with(
        a_collection_containing_exactly(agent.pubsub_token, admin.pubsub_token, api_session.pubsub_token),
        'message.created',
        message.push_event_data.merge(account_id: account.id),
        widget_members: [conversation.contact_inbox.pubsub_token],
        widget_data: message.widget_push_event_data.merge(account_id: account.id)
      )
    end

    it 'skips a verified session whose inbox no longer exists' do
      conversation.contact_inbox.update(hmac_verified: true)
      orphan = create(:contact_inbox, contact: conversation.contact, inbox: create(:inbox, account: account), hmac_verified: true)
      orphan.update_column(:inbox_id, 0) # rubocop:disable Rails/SkipsModelValidations
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      listener.message_created(event)

      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        anything, 'message.created', anything, widget_members: [conversation.contact_inbox.pubsub_token], widget_data: anything
      )
    end

    it 'sends a Client API session the full message in the agents job' do
      api_inbox = create(:inbox, account: account, channel: create(:channel_api, account: account))
      api_conversation = create(:conversation, account: account, inbox: api_inbox)
      api_message = create(:message, message_type: 'incoming', sender: api_conversation.contact,
                                     account: account, inbox: api_inbox, conversation: api_conversation)
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      listener.message_created(Events::Base.new(event_name, Time.zone.now, message: api_message))

      expect(ActionCableBroadcastJob).to have_received(:perform_later).once.with(
        a_collection_containing_exactly(admin.pubsub_token, api_conversation.contact_inbox.pubsub_token),
        'message.created',
        api_message.push_event_data.merge(account_id: account.id)
      )
    end

    it 'does not send a private note to the contact' do
      note = create(:message, message_type: 'outgoing', private: true, account: account, inbox: inbox, conversation: conversation)
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      listener.message_created(Events::Base.new(event_name, Time.zone.now, message: note))

      expect(ActionCableBroadcastJob).to have_received(:perform_later).once
    end
  end

  describe '#message_updated' do
    it 'sends edit capability to staff sessions only' do
      api_inbox = create(:inbox, account: account, channel: create(:channel_api, account: account))
      create(:inbox_member, inbox: api_inbox, user: agent)
      chat_id = '15550001111@s.whatsapp.net'
      api_conversation = create(:conversation, account: account, inbox: api_inbox, additional_attributes: { whatsapp_jid: chat_id })
      api_conversation.contact_inbox.update!(hmac_verified: true)
      widget_session = create(:contact_inbox, contact: api_conversation.contact, inbox: inbox, hmac_verified: true)
      reply = create(:message, account: account, inbox: api_inbox, conversation: api_conversation, sender: agent,
                               message_type: :outgoing, status: :delivered, source_id: 'team-message-id',
                               additional_attributes: { ryze_outbound_message_id: 'team-message-id' })
      event = Events::Base.new(:'message.updated', Time.current, message: reply, previous_changes: {})
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      with_modified_env(RYZE_INBOX_ID: api_inbox.id.to_s, RYZE_PILOT_CHAT_JID: chat_id, RYZE_INSTANCE_NAME: 'Pilot',
                        RYZE_WEBHOOK_SECRET: 'test-webhook', RYZE_EDIT_API_TOKEN: 'test-token',
                        RYZE_EDIT_CONVERSATION_ID: api_conversation.display_id.to_s, RYZE_NATIVE_BRIDGE_USER_ID: agent.id.to_s) do
        Ryze::OutboundDelivery.prepare(reply)
        reply.additional_attributes[Ryze::OutboundDelivery::DELIVERY_KEY]['state'] = 'confirmed'
        listener.message_updated(event)
      end

      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        a_collection_containing_exactly(agent.pubsub_token, admin.pubsub_token),
        'message.updated',
        hash_including(id: reply.id, can_edit_content: true)
      ).once
      public_payload = satisfy { |data| data[:id] == reply.id && !data.key?(:can_edit_content) }
      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        [api_conversation.contact_inbox.pubsub_token], 'message.updated', public_payload,
        widget_members: [widget_session.pubsub_token], widget_data: public_payload
      ).once
    end

    it 'keeps customer-revoked text and the before-value out of every contact session' do
      api_inbox = create(:inbox, account: account, channel: create(:channel_api, account: account))
      create(:inbox_member, inbox: api_inbox, user: agent)
      chat_id = '5511111111111@s.whatsapp.net'
      api_conversation = create(:conversation, account: account, inbox: api_inbox, additional_attributes: { whatsapp_jid: chat_id })
      api_conversation.contact_inbox.update!(hmac_verified: true)
      widget_session = create(:contact_inbox, contact: api_conversation.contact, inbox: inbox, hmac_verified: true)
      original_content = 'Retained text'
      message = create(:message, message_type: 'incoming', sender: api_conversation.contact,
                                 account: account, inbox: api_inbox, conversation: api_conversation, content: original_content,
                                 source_id: 'test-customer-revocation')
      message.mark_deleted!(by_customer: true)
      deleted_content = I18n.t('conversations.messages.deleted', locale: account.locale)
      event = Events::Base.new(:'message.updated', Time.current, message: message.reload,
                                                                 previous_changes: { 'content' => [original_content, deleted_content] })
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      listener.message_updated(event)

      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        a_collection_containing_exactly(agent.pubsub_token, admin.pubsub_token),
        'message.updated',
        hash_including(id: message.id, content: original_content, processed_message_content: original_content,
                       content_attributes: hash_including('deleted' => true, 'deleted_by_customer' => true))
      ).once

      tombstone = satisfy do |data|
        data[:id] == message.id && data[:content] == deleted_content &&
          data[:content_attributes]['deleted'] == true && !data.key?(:previous_changes) &&
          data.to_json.exclude?(original_content)
      end
      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        [api_conversation.contact_inbox.pubsub_token],
        'message.updated',
        tombstone,
        widget_members: [widget_session.pubsub_token],
        widget_data: tombstone
      ).once
      expect(ActionCableBroadcastJob).to have_received(:perform_later).exactly(2).times
    end
  end

  describe '#typing_on' do
    let(:event_name) { :'conversation.typing_on' }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation, user: agent, is_private: false) }

    it 'sends the full event to other agents and the widget payload to the contact' do
      # HACK: to reload conversation inbox members
      expect(conversation.inbox.reload.inbox_members.count).to eq(1)
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      listener.conversation_typing_on(event)

      expect(ActionCableBroadcastJob).to have_received(:perform_later).once.with(
        [admin.pubsub_token],
        'conversation.typing_on',
        { conversation: conversation.push_event_data, user: agent.push_event_data, account_id: account.id, is_private: false },
        widget_members: [conversation.contact_inbox.pubsub_token],
        widget_data: { conversation: conversation.widget_push_event_data, user: agent.push_event_data, account_id: account.id, is_private: false }
      )
    end
  end

  describe '#typing_on with contact' do
    let(:event_name) { :'conversation.typing_on' }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation, user: conversation.contact, is_private: false) }

    it 'sends the event to account admins and inbox agents only' do
      # HACK: to reload conversation inbox members
      expect(conversation.inbox.reload.inbox_members.count).to eq(1)
      expect(ActionCableBroadcastJob).to receive(:perform_later).once.with(
        a_collection_containing_exactly(admin.pubsub_token, agent.pubsub_token),
        'conversation.typing_on', { conversation: conversation.push_event_data,
                                    user: conversation.contact.push_event_data,
                                    account_id: account.id,
                                    is_private: false }
      )
      listener.conversation_typing_on(event)
    end
  end

  describe '#typing_on with agent bot' do
    let(:event_name) { :'conversation.typing_on' }
    let!(:agent_bot) { create(:agent_bot, account: account) }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation, user: agent_bot, is_private: false) }

    it 'sends the event to account admins, inbox agents and the contact' do
      expect(conversation.inbox.reload.inbox_members.count).to eq(1)
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      listener.conversation_typing_on(event)

      expect(ActionCableBroadcastJob).to have_received(:perform_later).once.with(
        a_collection_containing_exactly(admin.pubsub_token, agent.pubsub_token),
        'conversation.typing_on',
        { conversation: conversation.push_event_data, user: agent_bot.push_event_data, account_id: account.id, is_private: false },
        widget_members: [conversation.contact_inbox.pubsub_token],
        widget_data: { conversation: conversation.widget_push_event_data, user: agent_bot.push_event_data, account_id: account.id, is_private: false }
      )
    end
  end

  describe '#typing_off' do
    let(:event_name) { :'conversation.typing_off' }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation, user: agent, is_private: false) }

    it 'sends the full event to other agents and the widget payload to the contact' do
      # HACK: to reload conversation inbox members
      expect(conversation.inbox.reload.inbox_members.count).to eq(1)
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      listener.conversation_typing_off(event)

      expect(ActionCableBroadcastJob).to have_received(:perform_later).once.with(
        [admin.pubsub_token],
        'conversation.typing_off',
        { conversation: conversation.push_event_data, user: agent.push_event_data, account_id: account.id, is_private: false },
        widget_members: [conversation.contact_inbox.pubsub_token],
        widget_data: { conversation: conversation.widget_push_event_data, user: agent.push_event_data, account_id: account.id, is_private: false }
      )
    end
  end

  describe '#contact_deleted' do
    let(:event_name) { :'contact.deleted' }
    let!(:contact) { create(:contact, account: account) }
    let(:contact_data) { contact.push_event_data.merge(account_id: contact.account_id) }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, contact_data: contact_data) }

    it 'sends message to account admins, inbox agents' do
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        ["account_#{account.id}"],
        'contact.deleted',
        contact_data
      )
      listener.contact_deleted(event)
    end
  end

  describe '#notification_deleted' do
    let(:event_name) { :'notification.deleted' }
    let!(:notification) { create(:notification, account: account, user: agent) }
    let(:notification_data) do
      {
        id: notification.id,
        user_id: agent.id,
        account_id: account.id
      }
    end
    let!(:event) { Events::Base.new(event_name, Time.zone.now, notification_data: notification_data) }

    it 'sends message to account admins, inbox agents' do
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        [agent.pubsub_token],
        'notification.deleted',
        {
          account_id: notification.account_id,
          notification: {
            id: notification.id
          },
          unread_count: 1,
          count: 1
        }
      )

      listener.notification_deleted(event)
    end
  end

  describe '#notification_updated' do
    let(:event_name) { :'notification.updated' }
    let!(:notification) { create(:notification, account: account, user: agent) }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, notification: notification) }

    it 'sends notification to account admins, inbox agents' do
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        [agent.pubsub_token],
        'notification.updated',
        {
          account_id: notification.account_id,
          notification: notification.push_event_data,
          unread_count: 1,
          count: 1
        }
      )

      listener.notification_updated(event)
    end
  end

  describe '#conversation_updated' do
    let(:event_name) { :'conversation.updated' }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation, user: agent, is_private: false) }

    before do
      conversation.add_labels(['support'])
    end

    it 'sends the full conversation with label data to inbox members' do
      expect(conversation.inbox.reload.inbox_members.count).to eq(1)
      expect(conversation.reload.push_event_data[:labels]).to eq(conversation.labels.pluck(:name))
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      listener.conversation_updated(event)

      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        [agent.pubsub_token, admin.pubsub_token],
        'conversation.updated',
        conversation.push_event_data.merge(account_id: account.id)
      )
    end

    it 'does not send the update to the web widget session, which has no handler for it' do
      expect(ActionCableBroadcastJob).to receive(:perform_later).once.with(
        [agent.pubsub_token, admin.pubsub_token], 'conversation.updated', anything
      )

      listener.conversation_updated(event)
    end
  end

  describe '#conversation_status_changed' do
    let!(:event) { Events::Base.new(:'conversation.status_changed', Time.zone.now, conversation: conversation) }

    it 'sends the full conversation to agents and the widget payload to the web widget session in one job' do
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      listener.conversation_status_changed(event)

      expect(ActionCableBroadcastJob).to have_received(:perform_later).once.with(
        [agent.pubsub_token, admin.pubsub_token],
        'conversation.status_changed',
        conversation.push_event_data.merge(account_id: account.id),
        widget_members: [conversation.contact_inbox.pubsub_token],
        widget_data: conversation.widget_push_event_data.merge(account_id: account.id)
      )
    end
  end

  describe '#conversation_unread_count_changed' do
    let(:event_name) { :'conversation.unread_count_changed' }
    let!(:agent_without_inbox_access) { create(:user, account: account, role: :agent) }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation) }

    before do
      account.enable_features!(:conversation_unread_counts)
    end

    it 'sends a lightweight refresh event to inbox agents and admins' do
      expect(conversation.inbox.reload.inbox_members.count).to eq(1)

      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        a_collection_containing_exactly(agent.pubsub_token, admin.pubsub_token),
        'conversation.unread_count_changed',
        {
          account_id: account.id
        }
      )

      listener.conversation_unread_count_changed(event)
    end

    it 'does not broadcast unread count refresh to agents outside the inbox' do
      expect(ActionCableBroadcastJob).not_to receive(:perform_later).with(
        array_including(agent_without_inbox_access.pubsub_token),
        anything,
        anything
      )

      listener.conversation_unread_count_changed(event)
    end

    it 'does not broadcast when conversation unread counts feature is disabled' do
      account.disable_features!(:conversation_unread_counts)

      expect(ActionCableBroadcastJob).not_to receive(:perform_later)

      listener.conversation_unread_count_changed(event)
    end

    it 'supports deleted conversation data' do
      event = Events::Base.new(
        event_name,
        Time.zone.now,
        conversation_data: {
          id: conversation.id,
          account_id: account.id,
          inbox_id: conversation.inbox_id
        }
      )

      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        a_collection_containing_exactly(agent.pubsub_token, admin.pubsub_token),
        'conversation.unread_count_changed',
        {
          account_id: account.id
        }
      )

      listener.conversation_unread_count_changed(event)
    end
  end
end
