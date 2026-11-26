require 'rails_helper'

RSpec.describe 'Ryze inbound message changes', type: :request do
  let(:secret) { 'ryze-test-secret' }
  let(:instance_name) { 'psr-test-instance' }
  let(:channel) { create(:channel_api) }
  let(:inbox) { channel.reload.inbox }
  let(:account) { inbox.account }
  let(:jid) { '5511999999999@s.whatsapp.net' }
  let(:lid) { '100200300400500@lid' }
  let(:source_id) { 'ryze-message-123' }
  let(:edit_timestamp) { '2026-11-25T18:20:30Z' }
  let(:payload) do
    {
      event: 'message.exchange',
      instanceData: { instance: instance_name },
      data: {
        id: source_id,
        direction: 'incoming',
        timestamp: '2026-11-25T18:20:00Z',
        chat: { jid: jid, lid: lid, type: 'private' },
        message: {
          type: 'message_edit',
          content: 'Texto atualizado',
          isEdit: true,
          edit: {
            timestamp: edit_timestamp,
            attribute: 'message_edit',
            originalTimestamp: '2026-11-25T18:19:00Z',
            originalContent: 'Texto original'
          }
        }
      }
    }
  end

  def post_event(event_payload, token: secret)
    headers = { 'CONTENT_TYPE' => 'application/json', 'Authorization' => "Bearer #{token}" }
    with_modified_env(
      RYZE_WEBHOOK_SECRET: secret,
      RYZE_INSTANCE_NAME: instance_name,
      RYZE_INBOX_ID: inbox.id.to_s
    ) do
      post '/webhooks/ryze', params: event_payload.to_json, headers: headers
    end
  end

  def stub_change_service(perform_result: true)
    service = instance_double(Ryze::IncomingMessageChange, perform: perform_result)
    allow(Ryze::IncomingMessageChange).to receive(:new).and_return(service)
    service
  end

  it 'applies an incoming edit to the original message using both WhatsApp chat identifiers' do
    service = stub_change_service

    post_event(payload)

    expect(response).to have_http_status(:ok)
    expect(Ryze::IncomingMessageChange).to have_received(:new).with(
      inbox: inbox, event: have_attributes(source_id: source_id, chat_ids: [jid, lid], content: 'Texto atualizado',
                                           edited_at: Time.iso8601(edit_timestamp), customer_revoked?: false)
    )
    expect(service).to have_received(:perform)
  end

  it 'applies an incoming revocation to the original message' do
    service = stub_change_service
    revoked_payload = payload.deep_dup
    revoked_payload.dig(:data, :message).merge!(type: 'message_revoke', content: '', isEdit: false)
    revoked_payload.dig(:data, :message).delete(:edit)
    revoked_payload.dig(:data, :message)[:revoke] = { revokeType: 'sender_revoke', participant: nil }

    post_event(revoked_payload)

    expect(response).to have_http_status(:ok)
    expect(Ryze::IncomingMessageChange).to have_received(:new).with(
      inbox: inbox, event: have_attributes(source_id: source_id, chat_ids: [jid, lid], content: nil,
                                           edited_at: nil, customer_revoked?: true)
    )
    expect(service).to have_received(:perform)
  end

  it 'updates and then revokes the persisted original message through authenticated requests' do
    conversation = create(:conversation, account: account, inbox: inbox, additional_attributes: { whatsapp_jid: jid })
    original_message = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      message_type: :incoming,
      private: false,
      source_id: source_id,
      content: 'Texto original'
    )

    post_event(payload)

    expect(response).to have_http_status(:ok)
    expect(original_message.reload).to have_attributes(content: 'Texto atualizado', deleted: nil)

    revoked_payload = payload.deep_dup
    revoked_payload.dig(:data, :message).merge!(type: 'message_revoke', content: '', isEdit: false)
    revoked_payload.dig(:data, :message).delete(:edit)
    revoked_payload.dig(:data, :message)[:revoke] = { revokeType: 'sender_revoke', participant: nil }

    post_event(revoked_payload)

    expect(response).to have_http_status(:ok)
    expect(original_message.reload).to have_attributes(
      content: I18n.t('conversations.messages.deleted'),
      deleted: true,
      content_attributes: include('deleted' => true, 'deleted_by_customer' => true)
    )
    expect(original_message.agent_view_data(original_message.push_event_data)).to include(content: 'Texto atualizado')
    expect(original_message.customer_revocation).to have_attributes(content: 'Texto atualizado', edited: true)
    expect(conversation.messages.incoming.count).to eq(1)
  end

  it 'acknowledges unrelated Ryze events without processing them' do
    allow(Ryze::IncomingMessageChange).to receive(:new)

    post_event(payload.merge(event: 'message.status'))

    expect(response).to have_http_status(:ok)
    expect(Ryze::IncomingMessageChange).not_to have_received(:new)
  end

  it 'acknowledges outgoing edits without processing them' do
    allow(Ryze::IncomingMessageChange).to receive(:new)
    outgoing_payload = payload.deep_dup
    outgoing_payload[:data][:direction] = 'outgoing'

    post_event(outgoing_payload)

    expect(response).to have_http_status(:ok)
    expect(Ryze::IncomingMessageChange).not_to have_received(:new)
  end

  it 'acknowledges events for a different configured instance without processing them' do
    allow(Ryze::IncomingMessageChange).to receive(:new)
    other_instance_payload = payload.deep_dup
    other_instance_payload[:instanceData][:instance] = 'another-instance'

    post_event(other_instance_payload)

    expect(response).to have_http_status(:ok)
    expect(Ryze::IncomingMessageChange).not_to have_received(:new)
  end

  it 'acknowledges an event outside the configured pilot chat without processing it' do
    allow(Ryze::IncomingMessageChange).to receive(:new)
    other_chat_payload = payload.deep_dup
    other_chat_payload.dig(:data, :chat)[:jid] = '5511888888888@s.whatsapp.net'

    with_modified_env(
      RYZE_WEBHOOK_SECRET: secret,
      RYZE_INSTANCE_NAME: instance_name,
      RYZE_INBOX_ID: inbox.id.to_s,
      RYZE_PILOT_CHAT_JID: jid
    ) do
      post '/webhooks/ryze', params: other_chat_payload.to_json,
                             headers: { 'CONTENT_TYPE' => 'application/json', 'Authorization' => "Bearer #{secret}" }
    end

    expect(response).to have_http_status(:ok)
    expect(Ryze::IncomingMessageChange).not_to have_received(:new)
  end

  it 'records a safe correlation for an ignored pilot event without logging other chats' do
    logs = []
    allow(Rails.logger).to receive(:info).and_call_original
    allow(Rails.logger).to receive(:info).with(/Ryze pilot/) { |line| logs << line }
    ignored = payload.deep_dup
    ignored[:data][:direction] = 'outgoing'
    ignored[:data][:message][:type] = 'private-provider-value'
    with_modified_env(RYZE_PILOT_CHAT_JID: jid) do
      post_event(ignored, token: 'invalid')
      post_event(ignored.deep_merge(data: { chat: { jid: 'other@lid' } }))
      post_event(ignored)
    end

    expect(logs).to eq(["Ryze pilot type=other direction=outgoing id_hash=#{Digest::SHA256.hexdigest(source_id).first(16)}"])
  end

  it 'returns service unavailable while the integration is not configured' do
    with_modified_env RYZE_WEBHOOK_SECRET: nil, RYZE_INSTANCE_NAME: nil, RYZE_INBOX_ID: nil do
      post '/webhooks/ryze', params: payload.to_json,
                             headers: { 'CONTENT_TYPE' => 'application/json', 'Authorization' => "Bearer #{secret}" }
    end

    expect(response).to have_http_status(:service_unavailable)
  end

  it 'rejects a request with an invalid bearer token' do
    post_event(payload, token: 'invalid-token')

    expect(response).to have_http_status(:unauthorized)
  end

  it 'filters message content and provider credentials from request parameter logs' do
    stub_change_service
    logged_parameters = []
    capture_start_processing = lambda do |_name, _started, _finished, _id, event_payload|
      next unless event_payload[:controller] == 'Webhooks::RyzeController'

      logged_parameters << event_payload[:params]
    end
    payload_with_provider_token = payload.deep_dup
    payload_with_provider_token[:instanceData][:token] = 'provider-instance-token'

    ActiveSupport::Notifications.subscribed(capture_start_processing, 'start_processing.action_controller') do
      post_event(payload_with_provider_token)
    end

    expect(response).to have_http_status(:ok)
    expect(logged_parameters).to be_present
    logged_request = logged_parameters.first.to_json
    expect(logged_request).not_to include('Texto atualizado', 'Texto original', secret, 'provider-instance-token', jid, lid)
  end

  it 'returns service unavailable when the configured inbox is not an API inbox' do
    non_api_inbox = create(:inbox)
    headers = { 'CONTENT_TYPE' => 'application/json', 'Authorization' => "Bearer #{secret}" }

    with_modified_env(
      RYZE_WEBHOOK_SECRET: secret,
      RYZE_INSTANCE_NAME: instance_name,
      RYZE_INBOX_ID: non_api_inbox.id.to_s
    ) do
      post '/webhooks/ryze', params: payload.to_json, headers: headers
    end

    expect(response).to have_http_status(:service_unavailable)
  end

  it 'rejects a relevant event without the original message identifier' do
    stub_change_service
    malformed_payload = payload.deep_dup
    malformed_payload[:data].delete(:id)

    post_event(malformed_payload)

    expect(response).to have_http_status(:bad_request)
  end

  it 'rejects an edit without valid text and edit timestamp' do
    stub_change_service
    malformed_payload = payload.deep_dup
    malformed_payload.dig(:data, :message)[:content] = nil
    malformed_payload.dig(:data, :message, :edit)[:timestamp] = 'not-a-timestamp'
    malformed_payload[:data][:timestamp] = 'also-not-a-timestamp'

    post_event(malformed_payload)

    expect(response).to have_http_status(:bad_request)
  end

  it 'rejects a relevant event without WhatsApp chat identifiers' do
    stub_change_service
    malformed_payload = payload.deep_dup
    malformed_payload[:data][:chat] = { jid: '', lid: '' }

    post_event(malformed_payload)

    expect(response).to have_http_status(:bad_request)
  end

  it 'asks Ryze to retry when the original message has not arrived in Chatwoot yet' do
    service = instance_double(Ryze::IncomingMessageChange)
    allow(service).to receive(:perform).and_raise(ActiveRecord::RecordNotFound)
    allow(Ryze::IncomingMessageChange).to receive(:new).and_return(service)

    post_event(payload)

    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers['Retry-After']).to be_present
  end

  it 'returns conflict when the original message identifier is ambiguous' do
    service = instance_double(Ryze::IncomingMessageChange)
    allow(service).to receive(:perform).and_raise(ActiveRecord::SoleRecordExceeded)
    allow(Ryze::IncomingMessageChange).to receive(:new).and_return(service)

    post_event(payload)

    expect(response).to have_http_status(:conflict)
  end
end
