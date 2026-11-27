require 'rails_helper'
describe WebhookListener do
  let(:listener) { described_class.instance }
  let!(:account) { create(:account) }
  let(:report_identity) { Reports::UpdateAccountIdentity.new(account, Time.zone.now) }
  let!(:user) { create(:user, account: account) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:contact) { create(:contact, account: account) }
  let!(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: user) }
  let!(:message) do
    create(:message, message_type: 'outgoing',
                     account: account, inbox: inbox, conversation: conversation)
  end
  let!(:message_created_event) { Events::Base.new(event_name, Time.zone.now, message: message) }
  let!(:conversation_created_event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation) }
  let!(:contact_event) { Events::Base.new(event_name, Time.zone.now, contact: contact) }

  describe '#message_created' do
    let(:event_name) { :'message.created' }

    context 'when webhook is not configured' do
      it 'does not trigger webhook' do
        expect(WebhookJob).to receive(:perform_later).exactly(0).times
        listener.message_created(message_created_event)
      end
    end

    context 'when webhook is configured and event is subscribed' do
      it 'triggers the webhook event' do
        webhook = create(:webhook, inbox: inbox, account: account)
        expect(WebhookJob).to receive(:perform_later).with(
          webhook.url, message.webhook_data.merge(event: 'message_created'), :account_webhook,
          secret: webhook.secret, delivery_id: instance_of(String)
        ).once
        listener.message_created(message_created_event)
      end
    end

    context 'when webhook is configured and event is not subscribed' do
      it 'does not trigger the webhook event' do
        create(:webhook, subscriptions: ['conversation_created'], inbox: inbox, account: account)
        expect(WebhookJob).not_to receive(:perform_later)
        listener.message_created(message_created_event)
      end
    end

    context 'when API and webhook access is disabled for the account' do
      before do
        allow(account).to receive(:api_and_webhooks_enabled?).and_return(false)
        allow(message).to receive(:inbox).and_return(inbox)
        allow(inbox).to receive(:account).and_return(account)
      end

      it 'does not trigger account webhooks' do
        create(:webhook, inbox: inbox, account: account)
        expect(WebhookJob).not_to receive(:perform_later)
        listener.message_created(message_created_event)
      end

      it 'still triggers API inbox webhooks' do
        channel_api = create(:channel_api, account: account)
        api_inbox = channel_api.inbox
        api_conversation = create(:conversation, account: account, inbox: api_inbox, assignee: user)
        api_message = create(:message, message_type: 'outgoing', account: account, inbox: api_inbox, conversation: api_conversation)
        api_event = Events::Base.new(event_name, Time.zone.now, message: api_message)
        allow(api_message).to receive(:inbox).and_return(api_inbox)
        allow(api_inbox).to receive(:account).and_return(account)
        expect(WebhookJob).to receive(:perform_later).with(
          channel_api.webhook_url, api_message.webhook_data.merge(event: 'message_created'),
          :api_inbox_webhook, secret: channel_api.secret, delivery_id: instance_of(String)
        ).once
        listener.message_created(api_event)
      end
    end

    context 'when api_and_webhooks feature is disabled on self-hosted' do
      it 'still triggers account webhooks' do
        allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(false)
        account.disable_features!('api_and_webhooks')
        webhook = create(:webhook, inbox: inbox, account: account)

        expect(WebhookJob).to receive(:perform_later).with(
          webhook.url, message.webhook_data.merge(event: 'message_created'), :account_webhook,
          secret: webhook.secret, delivery_id: instance_of(String)
        ).once

        listener.message_created(message_created_event)
      end
    end

    context 'when inbox is an API Channel' do
      [true, false].each do |recorded|
        it "sends is_voice_message=#{recorded} for the same OGG depending on how it was attached" do
          channel = create(:channel_api, account: account)
          api_conversation = create(:conversation, account: account, inbox: channel.inbox)
          audio = Rack::Test::UploadedFile.new('spec/assets/sample.ogg', 'audio/ogg')
          params = ActionController::Parameters.new(attachments: [audio])
          params[:is_voice_message] = 'true' if recorded
          sent_message = Messages::MessageBuilder.new(user, api_conversation, params).perform
          event = Events::Base.new(event_name, Time.zone.now, message: sent_message.reload)
          attachment = hash_including(file_type: 'audio', is_voice_message: recorded, data_url: a_string_matching(/.+/))

          expect(WebhookJob).to receive(:perform_later).with(
            channel.webhook_url, hash_including(event: 'message_created', attachments: [attachment]),
            :api_inbox_webhook, secret: channel.secret, delivery_id: instance_of(String)
          )
          listener.message_created(event)
        end
      end

      it 'triggers webhook if webhook_url is present' do
        channel_api = create(:channel_api, account: account)
        api_inbox = channel_api.inbox
        api_conversation = create(:conversation, account: account, inbox: api_inbox, assignee: user)
        api_message = create(
          :message,
          message_type: 'outgoing',
          account: account,
          inbox: api_inbox,
          conversation: api_conversation
        )
        api_event = Events::Base.new(event_name, Time.zone.now, message: api_message)
        expect(WebhookJob).to receive(:perform_later).with(
          channel_api.webhook_url, api_message.webhook_data.merge(event: 'message_created'),
          :api_inbox_webhook, secret: channel_api.secret, delivery_id: instance_of(String)
        ).once
        listener.message_created(api_event)
      end

      it 'does not trigger webhook if webhook_url is not present' do
        channel_api = create(:channel_api, webhook_url: nil, account: account)
        api_inbox = channel_api.inbox
        api_conversation = create(:conversation, account: account, inbox: api_inbox, assignee: user)
        api_message = create(
          :message,
          message_type: 'outgoing',
          account: account,
          inbox: channel_api.inbox,
          conversation: api_conversation
        )
        api_event = Events::Base.new(event_name, Time.zone.now, message: api_message)
        expect(WebhookJob).not_to receive(:perform_later)
        listener.message_created(api_event)
      end
    end
  end

  describe '#message_updated for historical media' do
    let(:event_name) { :'message.updated' }
    let(:inbox) { create(:channel_api, account: account).inbox }

    it 'skips both bridge subscriptions but still notifies independent account subscribers' do
      message.update!(additional_attributes: { ryze_historical_sync: true })
      create(:webhook, inbox: inbox, account: account, url: inbox.channel.webhook_url, subscriptions: ['message_updated'])
      audit = create(:webhook, account: account, subscriptions: ['message_updated'])
      expect(WebhookJob).to receive(:perform_later).once.with(audit.url, hash_including(event: 'message_updated'), :account_webhook, anything)
      listener.message_updated(message_created_event)
    end
  end

  describe '#message_updated for Ryze audio delivery metadata' do
    let(:event_name) { :'message.updated' }
    let(:channel_api) { create(:channel_api, account: account) }
    let(:inbox) { channel_api.inbox }
    let(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: user) }
    let(:audio_message) do
      create(:message, message_type: :outgoing, private: false, account: account, inbox: inbox,
                       conversation: conversation).tap do |record|
        record.attachments.create!(account: account, file_type: :audio, external_url: 'https://example.com/audio.ogg')
      end
    end

    before do
      create(:webhook, inbox: inbox, account: account, url: channel_api.webhook_url,
                       subscriptions: ['message_updated'])
      allow(Ryze::AudioDelivery).to receive(:applies?).with(audio_message).and_return(true)
      allow(audio_message).to receive(:webhook_data).and_return({ id: audio_message.id })
    end

    def dispatch_update(changes)
      event = Events::Base.new(:'message.updated', Time.current, message: audio_message, previous_changes: changes)
      listener.message_updated(event)
    end

    def audit_webhook
      create(:webhook, account: account, subscriptions: ['message_updated'])
    end

    it 'suppresses an empty or timestamp-only snapshot from the bridge but keeps account webhooks' do
      audit = audit_webhook
      changes = [
        {},
        { 'updated_at' => [1, 2] }
      ]

      allow(WebhookJob).to receive(:perform_later)
      changes.each do |previous_changes|
        dispatch_update(previous_changes)
      end

      expect(WebhookJob).to have_received(:perform_later).exactly(changes.length).times
      expect(WebhookJob).to have_received(:perform_later).with(
        audit.url, hash_including(event: 'message_updated'), :account_webhook,
        secret: audit.secret, delivery_id: instance_of(String)
      ).twice
    end

    it 'suppresses provider status and error changes when they are limited to delivery metadata' do
      audit = audit_webhook
      marker_key = Ryze::AudioDelivery::STATUS_KEY
      previous_changes = {
        'status' => %w[sent failed],
        'source_id' => [nil, 'provider-id'],
        'additional_attributes' => [
          { 'existing' => 'value', marker_key => 'sent' },
          { 'existing' => 'value', marker_key => 'failed' }
        ],
        'content_attributes' => [
          { 'in_reply_to' => 'prior-message', 'external_error' => nil },
          { 'in_reply_to' => 'prior-message', 'external_error' => 'temporary delivery error' }
        ]
      }

      allow(WebhookJob).to receive(:perform_later)
      dispatch_update(previous_changes)
      expect(WebhookJob).to have_received(:perform_later).once
      expect(WebhookJob).to have_received(:perform_later).with(
        audit.url, hash_including(event: 'message_updated'), :account_webhook,
        secret: audit.secret, delivery_id: instance_of(String)
      ).once
    end

    it 'suppresses an unacknowledged status failure with its transport error' do
      audit = audit_webhook
      previous_changes = {
        'status' => %w[sent failed],
        'content_attributes' => [
          nil,
          { 'external_error' => 'transport timeout' }
        ]
      }

      allow(WebhookJob).to receive(:perform_later)
      dispatch_update(previous_changes)
      expect(WebhookJob).to have_received(:perform_later).once
      expect(WebhookJob).to have_received(:perform_later).with(
        audit.url, hash_including(event: 'message_updated'), :account_webhook,
        secret: audit.secret, delivery_id: instance_of(String)
      ).once
    end

    it 'allows a failed-to-sent retry through to the bridge when no callback marker exists' do
      audit = audit_webhook
      allow(WebhookJob).to receive(:perform_later)
      dispatch_update(
        {
          'status' => %w[failed sent],
          'content_attributes' => [
            { 'external_error' => 'temporary delivery error' },
            { 'external_error' => nil }
          ]
        }
      )

      expect(WebhookJob).to have_received(:perform_later).with(
        channel_api.webhook_url, hash_including(event: 'message_updated'), :api_inbox_webhook,
        secret: channel_api.secret, delivery_id: instance_of(String)
      ).once
      expect(WebhookJob).to have_received(:perform_later).with(
        audit.url, hash_including(event: 'message_updated'), :account_webhook,
        secret: audit.secret, delivery_id: instance_of(String)
      ).once
    end

    it 'allows nested content edits and deletions through to the bridge' do
      audit = audit_webhook
      allow(WebhookJob).to receive(:perform_later)
      edits = [
        { 'content' => %w[before after] },
        {
          'content_attributes' => [
            { 'external_error' => 'temporary delivery error' },
            { 'external_error' => 'temporary delivery error', 'deleted' => true }
          ]
        }
      ]

      edits.each do |previous_changes|
        dispatch_update(previous_changes)
      end
      expect(WebhookJob).to have_received(:perform_later).exactly(6).times
      expect(WebhookJob).to have_received(:perform_later).with(
        channel_api.webhook_url, hash_including(event: 'message_updated'), :api_inbox_webhook,
        secret: channel_api.secret, delivery_id: instance_of(String)
      ).twice
      expect(WebhookJob).to have_received(:perform_later).with(
        audit.url, hash_including(event: 'message_updated'), :account_webhook,
        secret: audit.secret, delivery_id: instance_of(String)
      ).twice
    end

    it 'preserves the bridge update when the event has no change snapshot' do
      audit = audit_webhook
      event = Events::Base.new(:'message.updated', Time.current, message: audio_message)

      allow(WebhookJob).to receive(:perform_later)
      listener.message_updated(event)

      expect(WebhookJob).to have_received(:perform_later).with(
        channel_api.webhook_url, hash_including(event: 'message_updated'), :api_inbox_webhook,
        secret: channel_api.secret, delivery_id: instance_of(String)
      ).once
      expect(WebhookJob).to have_received(:perform_later).with(
        audit.url, hash_including(event: 'message_updated'), :account_webhook,
        secret: audit.secret, delivery_id: instance_of(String)
      ).once
    end
  end

  describe '#conversation_created' do
    let(:event_name) { :'conversation.created' }

    context 'when webhook is not configured' do
      it 'does not trigger webhook' do
        expect(WebhookJob).to receive(:perform_later).exactly(0).times
        listener.conversation_created(conversation_created_event)
      end
    end

    context 'when webhook is configured' do
      it 'triggers webhook' do
        webhook = create(:webhook, inbox: inbox, account: account)
        expect(WebhookJob).to receive(:perform_later).with(
          webhook.url, conversation.webhook_data.merge(event: 'conversation_created'), :account_webhook,
          secret: webhook.secret, delivery_id: instance_of(String)
        ).once
        listener.conversation_created(conversation_created_event)
      end

      it 'includes account details in the conversation payload' do
        webhook = create(:webhook, inbox: inbox, account: account)
        expect(WebhookJob).to receive(:perform_later).with(
          webhook.url,
          hash_including(account: account.webhook_data),
          :account_webhook,
          hash_including(secret: webhook.secret)
        ).once
        listener.conversation_created(conversation_created_event)
      end
    end

    context 'when inbox is an API Channel' do
      it 'triggers webhook if webhook_url is present' do
        channel_api = create(:channel_api, account: account)
        api_inbox = channel_api.inbox
        api_conversation = create(:conversation, account: account, inbox: api_inbox, assignee: user)
        api_event = Events::Base.new(event_name, Time.zone.now, conversation: api_conversation)
        expect(WebhookJob).to receive(:perform_later).with(
          channel_api.webhook_url,
          api_conversation.webhook_data.merge(event: 'conversation_created'),
          :api_inbox_webhook, secret: channel_api.secret, delivery_id: instance_of(String)
        ).once
        listener.conversation_created(api_event)
      end

      it 'does not trigger webhook if webhook_url is not present' do
        channel_api = create(:channel_api, webhook_url: nil, account: account)
        api_inbox = channel_api.inbox
        api_conversation = create(:conversation, account: account, inbox: api_inbox, assignee: user)
        api_event = Events::Base.new(event_name, Time.zone.now, conversation: api_conversation)
        expect(WebhookJob).not_to receive(:perform_later)
        listener.conversation_created(api_event)
      end
    end
  end

  describe '#conversation_updated' do
    let(:custom_attributes) { { test: nil } }
    let!(:conversation_updated_event) do
      Events::Base.new(
        event_name, Time.zone.now,
        conversation: conversation.reload,
        changed_attributes: {
          custom_attributes: [{ test: nil }, { test: 'testing custom attri webhook' }]
        }
      )
    end
    let(:event_name) { :'conversation.updated' }

    context 'when webhook is not configured' do
      it 'does not trigger webhook' do
        expect(WebhookJob).to receive(:perform_later).exactly(0).times
        listener.conversation_updated(conversation_updated_event)
      end
    end

    context 'when webhook is configured' do
      it 'triggers webhook' do
        webhook = create(:webhook, inbox: inbox, account: account)

        conversation.update(custom_attributes: { test: 'testing custom attri webhook' })

        expect(WebhookJob).to receive(:perform_later).with(
          webhook.url,
          conversation.webhook_data.merge(
            event: 'conversation_updated',
            changed_attributes: [
              {
                custom_attributes: {
                  previous_value: { test: nil },
                  current_value: { test: 'testing custom attri webhook' }
                }
              }
            ]
          ),
          :account_webhook,
          secret: webhook.secret, delivery_id: instance_of(String)
        ).once

        listener.conversation_updated(conversation_updated_event)
      end
    end
  end

  describe '#contact_created' do
    let(:event_name) { :'contact.created' }

    context 'when webhook is not configured' do
      it 'does not trigger webhook' do
        expect(WebhookJob).to receive(:perform_later).exactly(0).times
        listener.contact_created(contact_event)
      end
    end

    context 'when webhook is configured' do
      it 'triggers webhook' do
        webhook = create(:webhook, account: account)
        expect(WebhookJob).to receive(:perform_later).with(
          webhook.url, contact.webhook_data.merge(event: 'contact_created'), :account_webhook,
          secret: webhook.secret, delivery_id: instance_of(String)
        ).once
        listener.contact_created(contact_event)
      end
    end
  end

  describe '#contact_updated' do
    let(:event_name) { :'contact.updated' }
    let!(:contact_updated_event) { Events::Base.new(event_name, Time.zone.now, contact: contact, changed_attributes: changed_attributes) }
    let(:changed_attributes) { { 'name' => ['Jane', 'Jane Doe'] } }

    context 'when webhook is not configured' do
      it 'does not trigger webhook' do
        expect(WebhookJob).to receive(:perform_later).exactly(0).times
        listener.contact_updated(contact_updated_event)
      end
    end

    context 'when webhook is configured and there is no changed attributes' do
      let(:changed_attributes) { {} }

      it 'triggers webhook' do
        create(:webhook, account: account)
        expect(WebhookJob).to receive(:perform_later).exactly(0).times
        listener.contact_updated(contact_updated_event)
      end
    end

    context 'when webhook is configured and there are changed attributes' do
      it 'triggers webhook' do
        webhook = create(:webhook, account: account)
        expect(WebhookJob).to receive(:perform_later).with(
          webhook.url,
          contact.webhook_data.merge(
            event: 'contact_updated',
            changed_attributes: [{ 'name' => { :current_value => 'Jane Doe', :previous_value => 'Jane' } }]
          ),
          :account_webhook,
          secret: webhook.secret, delivery_id: instance_of(String)
        ).once
        listener.contact_updated(contact_updated_event)
      end
    end
  end

  describe '#inbox_created' do
    let(:event_name) { :'inbox.created' }
    let!(:inbox_created_event) { Events::Base.new(event_name, Time.zone.now, inbox: inbox) }

    context 'when webhook is not configured' do
      it 'does not trigger webhook' do
        expect(WebhookJob).to receive(:perform_later).exactly(0).times
        listener.inbox_created(inbox_created_event)
      end
    end

    context 'when webhook is configured' do
      it 'triggers webhook' do
        inbox_data = Inbox::EventDataPresenter.new(inbox).webhook_data
        webhook = create(:webhook, account: account, subscriptions: ['inbox_created'])
        expect(WebhookJob).to receive(:perform_later).with(
          webhook.url, inbox_data.merge(event: 'inbox_created'), :account_webhook,
          secret: webhook.secret, delivery_id: instance_of(String)
        ).once
        listener.inbox_created(inbox_created_event)
      end

      it 'includes account details in the inbox payload' do
        webhook = create(:webhook, account: account, subscriptions: ['inbox_created'])
        expect(WebhookJob).to receive(:perform_later).with(
          webhook.url,
          hash_including(account: account.webhook_data),
          :account_webhook,
          hash_including(secret: webhook.secret)
        ).once
        listener.inbox_created(inbox_created_event)
      end
    end
  end

  describe '#inbox_updated' do
    let(:event_name) { :'inbox.updated' }
    let!(:inbox_updated_event) { Events::Base.new(event_name, Time.zone.now, inbox: inbox, changed_attributes: changed_attributes) }
    let(:changed_attributes) { {} }

    context 'when webhook is not configured' do
      it 'does not trigger webhook' do
        expect(WebhookJob).to receive(:perform_later).exactly(0).times
        listener.inbox_updated(inbox_updated_event)
      end
    end

    context 'when webhook is configured and there are no changed attributes' do
      it 'triggers webhook' do
        create(:webhook, account: account, subscriptions: ['inbox_updated'])
        expect(WebhookJob).to receive(:perform_later).exactly(0).times
        listener.inbox_updated(inbox_updated_event)
      end
    end

    context 'when webhook is configured' do
      let(:changed_attributes) { { 'name' => ['Inbox 1', inbox.name] } }

      it 'triggers webhook' do
        webhook = create(:webhook, account: account, subscriptions: ['inbox_updated'])

        inbox_data = Inbox::EventDataPresenter.new(inbox).webhook_data
        changed_attributes_data = [{ 'name' => { 'previous_value': 'Inbox 1', 'current_value': inbox.name } }]

        expect(WebhookJob).to receive(:perform_later).with(
          webhook.url,
          inbox_data.merge(event: 'inbox_updated', changed_attributes: changed_attributes_data),
          :account_webhook,
          secret: webhook.secret, delivery_id: instance_of(String)
        ).once

        listener.inbox_updated(inbox_updated_event)
      end
    end
  end

  describe '#conversation_typing_on' do
    let(:event_name) { :'conversation.typing_on' }
    let!(:typing_event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation, user: user) }

    context 'when webhook is not configured' do
      it 'does not trigger webhook' do
        expect(WebhookJob).not_to receive(:perform_later)
        listener.conversation_typing_on(typing_event)
      end
    end

    context 'when webhook is configured' do
      it 'triggers webhook' do
        webhook = create(:webhook, inbox: inbox, account: account, subscriptions: ['conversation_typing_on'])

        payload = {
          event: 'conversation_typing_on',
          user: user.webhook_data,
          conversation: conversation.webhook_data,
          is_private: false
        }

        expect(WebhookJob).to receive(:perform_later).with(
          webhook.url, payload, :account_webhook,
          secret: webhook.secret, delivery_id: instance_of(String)
        ).once
        listener.conversation_typing_on(typing_event)
      end
    end

    context 'when inbox is an API Channel' do
      it 'triggers webhook if webhook_url is present' do
        channel_api = create(:channel_api, account: account)
        api_inbox = channel_api.inbox
        api_conversation = create(:conversation, account: account, inbox: api_inbox, assignee: user)
        api_event = Events::Base.new(event_name, Time.zone.now, conversation: api_conversation, user: user, is_private: false)

        payload = {
          event: 'conversation_typing_on',
          user: user.webhook_data,
          conversation: api_conversation.webhook_data,
          is_private: false
        }

        expect(WebhookJob).to receive(:perform_later).with(
          channel_api.webhook_url, payload, :api_inbox_webhook,
          secret: channel_api.secret, delivery_id: instance_of(String)
        ).once
        listener.conversation_typing_on(api_event)
      end
    end
  end

  describe '#conversation_typing_off' do
    let(:event_name) { :'conversation.typing_off' }
    let!(:typing_event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation, user: user, is_private: false) }

    context 'when webhook is not configured' do
      it 'does not trigger webhook' do
        expect(WebhookJob).not_to receive(:perform_later)
        listener.conversation_typing_off(typing_event)
      end
    end

    context 'when webhook is configured' do
      it 'triggers webhook' do
        webhook = create(:webhook, inbox: inbox, account: account, subscriptions: ['conversation_typing_off'])

        payload = {
          event: 'conversation_typing_off',
          user: user.webhook_data,
          conversation: conversation.webhook_data,
          is_private: false
        }

        expect(WebhookJob).to receive(:perform_later).with(
          webhook.url, payload, :account_webhook,
          secret: webhook.secret, delivery_id: instance_of(String)
        ).once
        listener.conversation_typing_off(typing_event)
      end
    end
  end
end
