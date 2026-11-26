require 'rails_helper'

RSpec.describe Ryze::OutboundDelivery do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:author) { create(:user, account: account) }
  let(:bridge) { create(:user, account: account) }
  let(:chat_id) { '5511999999999@s.whatsapp.net' }
  let(:content) { 'Text from the team' }
  let(:provider_id) { '3EB012345678' }
  let(:client) { instance_double(Ryze::Client) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, additional_attributes: { 'whatsapp_jid' => chat_id }) }
  let(:message) { build_from(author, api_token_request: false) }

  around do |example|
    with_modified_env(
      RYZE_INSTANCE_NAME: 'test-instance', RYZE_WEBHOOK_SECRET: 'test-secret',
      RYZE_EDIT_API_TOKEN: 'test-token', RYZE_INBOX_ID: inbox.id.to_s,
      RYZE_PILOT_CHAT_JID: chat_id, RYZE_NATIVE_BRIDGE_USER_ID: bridge.id.to_s, RYZE_EDIT_CONVERSATION_ID: conversation.reload.display_id.to_s
    ) { example.run }
  end

  before do
    allow(Ryze::Client).to receive(:new).with(instance: 'test-instance', token: 'test-token').and_return(client)
  end

  def build_from(sender, api_token_request:, **params)
    attributes = ActionController::Parameters.new({ content: content }.merge(params))
    Messages::MessageBuilder.new(sender, conversation.reload, attributes, api_token_request: api_token_request).perform
  end

  def event(id = provider_id, source: tracking_source, text: content, chats: [chat_id])
    instance_double(Ryze::WebhookEvent, source_id: id, tracking_source: source, content: text, chat_ids: chats)
  end

  def tracking_source
    Ryze::OutboundMessageCorrelation.new(message).tracking_source
  end

  def send_message
    Ryze::DeliverOutboundMessageJob.perform_now(message.id, 1)
  end

  def successful_response
    data = {
      messageId: provider_id, direction: 'outgoing', messageType: 'text', source: tracking_source,
      content: content, chat: { jid: chat_id }
    }
    instance_double(Net::HTTPResponse, code: '200', body: { success: true, status: 'sent', data: data }.to_json)
  end

  it 'uses a single Ryze POST, stores the ID on the original and ignores duplicate jobs' do
    expect(described_class.direct?(message)).to be(true)
    payload = { number: chat_id, message: content, source: tracking_source }
    expect(client).to receive(:post).once.with('message/text', payload).and_return(successful_response)

    2.times { send_message }

    expect(message.reload.source_id).to eq(provider_id)
    expect(message.additional_attributes).to include(described_class::VERIFIED_ID_KEY => provider_id)
    expect(message.sender).to eq(author)
    expect(message.status).to eq('sent')
    expect(JSON.generate(message.additional_attributes)).not_to include(tracking_source)
  end

  it 'uses the same record when the native mirror arrives after acknowledgment' do
    allow(client).to receive(:post).and_return(successful_response)
    send_message

    expect do
      mirrored = build_from(bridge, api_token_request: true, source_id: provider_id)
      expect(mirrored.id).to eq(message.id)
    end.not_to change(Message, :count)
  end

  it 'reconciles an authenticated native mirror arriving before acknowledgment and its redelivery' do
    mirror = nil
    allow(client).to receive(:post) do
      mirror = build_from(bridge, api_token_request: true, source_id: provider_id)
      expect(build_from(bridge, api_token_request: true, source_id: provider_id).id).to eq(mirror.id)
      successful_response
    end

    expect(message).to be_persisted
    expect { send_message }.not_to(change { conversation.messages.outgoing.count })

    expect(Message.exists?(mirror.id)).to be(false)
    expect(message.reload.additional_attributes).to include(described_class::REPLACED_ID_KEY => mirror.id)
  end

  it 'preserves an unrelated existing row with the same provider ID' do
    untrusted = build_from(author, api_token_request: true, source_id: provider_id)
    allow(client).to receive(:post).and_return(successful_response)

    expect { send_message }.not_to(change { untrusted.reload.attributes })

    expect(message.reload.source_id).to be_nil
    expect(message.external_error).to eq('ryze_delivery_unknown')
  end

  it 'keeps a native record that already has a reply referencing it' do
    mirror = build_from(bridge, api_token_request: true, source_id: provider_id)
    reply = create(:message, account: account, inbox: inbox, conversation: conversation, content_attributes: { in_reply_to: mirror.id })
    expect(reply.reload.in_reply_to).to eq(mirror.id)
    allow(client).to receive(:post).and_return(successful_response)

    send_message

    expect(Message.exists?(mirror.id)).to be(true)
    expect(message.reload.external_error).to eq('ryze_delivery_unknown')
  end

  it 'waits for trusted signed webhook evidence after a transport timeout, without sending twice' do
    expect(client).to receive(:post).once.and_raise(Ryze::Client::ConnectionError)
    send_message
    send_message

    expect(message.reload.external_error).to eq('ryze_delivery_unknown')
    expect(described_class.retry_rejected!(message)).to be(false)
    expect(described_class.confirm_event!(inbox: inbox, event: event(source: 'psr-cw-forged'), pilot_chat_id: chat_id)).to eq(:ignored)
    expect(described_class.confirm_event!(inbox: inbox, event: event(chats: ['wrong-chat']), pilot_chat_id: chat_id)).to eq(:ignored)

    2.times do
      expect(described_class.confirm_event!(inbox: inbox, event: event, pilot_chat_id: chat_id)).to eq(:confirmed)
    end
    expect(message.reload).to have_attributes(source_id: provider_id, status: 'sent', external_error: nil)
  end

  it 'allows one explicit retry after a definitive provider rejection' do
    rejection = instance_double(Net::HTTPResponse, code: '400', body: { success: false, error: { message: 'Invalid input' } }.to_json)
    expect(client).to receive(:post).once.and_return(rejection)
    send_message

    expect(message.reload.external_error).to eq('ryze_delivery_failed')
    expect { described_class.retry_rejected!(message) }.to have_enqueued_job(Ryze::DeliverOutboundMessageJob).with(message.id, 2)
    expect(described_class.retry_rejected!(message)).to be(false)
  end

  it 'marks an abandoned in-flight attempt uncertain and still accepts authoritative confirmation' do
    allow(client).to receive(:post).and_raise(Interrupt)
    expect { send_message }.to raise_error(Interrupt)
    Ryze::OutboundDeliveryTimeoutJob.perform_now(message.id, 1)

    expect(message.reload.external_error).to eq('ryze_delivery_unknown')
    expect(described_class.confirm_event!(inbox: inbox, event: event, pilot_chat_id: chat_id)).to eq(:confirmed)
  end

  it 'ignores the original watchdog after an explicit retry starts' do
    Ryze::OutboundDeliveryTimeoutJob.perform_now(message.id, 1)
    expect(described_class.retry_rejected!(message)).to be(true)

    Ryze::OutboundDeliveryTimeoutJob.perform_now(message.id, 1)

    expect(message.reload.failed?).to be(false)
  end

  it 'refuses to redirect a queued text to another instance after reconfiguration' do
    expect(message).to be_persisted
    expect(client).not_to receive(:post)
    with_modified_env(RYZE_INSTANCE_NAME: 'another-instance') { send_message }

    expect(message.reload.external_error).to eq('ryze_delivery_failed')
  end

  it 'keeps private notes, quotes and non-dashboard sends on the existing path' do
    referenced = create(:message, account: account, inbox: inbox, conversation: conversation)
    private_note = build_from(author, api_token_request: false, private: true)
    token_send = build_from(author, api_token_request: true)
    quoted = build_from(author, api_token_request: false, content_attributes: { in_reply_to: referenced.id })
    expect([private_note, token_send, quoted].any? { |item| described_class.direct?(item) }).to be(false)
  end

  it 'routes only pilot text through the new job and keeps the independent account webhook' do
    webhook = create(:webhook, account: account, subscriptions: %w[message_created message_updated])
    message_created = Events::Base.new('message.created', Time.current, message: message)
    message_updated = Events::Base.new('message.updated', Time.current, message: message)
    allow(account).to receive(:api_and_webhooks_enabled?).and_return(true)
    allow(inbox).to receive(:account).and_return(account)

    expect(WebhookJob).to receive(:perform_later).twice.with(
      webhook.url, anything, :account_webhook, secret: webhook.secret, delivery_id: instance_of(String)
    )
    expect { WebhookListener.instance.message_created(message_created) }.to have_enqueued_job(Ryze::DeliverOutboundMessageJob).with(message.id, 1)
    expect { WebhookListener.instance.message_updated(message_updated) }.not_to have_enqueued_job(Ryze::DeliverOutboundMessageJob)
  end
end
