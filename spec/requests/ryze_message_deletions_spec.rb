require 'rails_helper'

RSpec.describe 'Ryze pilot message deletion', type: :request do
  let(:inbox) { create(:channel_api).inbox }
  let(:account) { inbox.account }
  let(:agent) { create(:user, account: account, role: :administrator) }
  let(:other_agent) { create(:user, account: account, role: :administrator) }
  let(:jid) { '15550001234@s.whatsapp.net' }
  let(:source_id) { 'WA-SENT-1' }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, additional_attributes: { whatsapp_jid: jid }) }
  let(:message) do
    reply = build(:message, account: account, inbox: inbox, conversation: conversation, sender: agent,
                            message_type: :outgoing, content: 'original', source_id: source_id, status: :delivered)
    Ryze::OutboundDelivery.prepare(reply)
    reply.additional_attributes['ryze_outbound_delivery']['state'] = 'confirmed'
    reply.additional_attributes['ryze_outbound_message_id'] = source_id
    reply.tap(&:save!)
  end
  let(:path) { api_v1_account_conversation_message_path(account.id, conversation.display_id, message.id) }
  let(:provider) { 'https://ryzeapi.cloud/api/chat' }
  let(:confirmation) { { success: true, message_id: source_id, chat_jid: jid, delete_type: 'revoke', deleted_for_everyone: true } }
  let(:revoke) do
    stub_request(:delete, "#{provider}/delete/pilot").with(body: { messageId: source_id, deleteForEveryone: true }.to_json,
                                                           headers: { 'token' => 'test-token' })
  end

  around do |example|
    with_modified_env(RYZE_INBOX_ID: inbox.id.to_s, RYZE_EDIT_CONVERSATION_ID: conversation.display_id.to_s, RYZE_INSTANCE_NAME: 'pilot',
                      RYZE_PILOT_CHAT_JID: jid, RYZE_EDIT_API_TOKEN: 'test-token', RYZE_WEBHOOK_SECRET: 'test-secret',
                      RYZE_NATIVE_BRIDGE_USER_ID: agent.id.to_s) { example.run }
  end

  def delete_message(action = :delete_for_everyone, user: agent)
    post "#{path}/#{action}", headers: user.create_new_auth_token, as: :json
  end

  def stub_status(chat: jid)
    stub_request(:get, "#{provider}/status/pilot").with(query: { messageId: source_id }).to_return do
      yield if block_given?
      { body: { success: true, message_id: source_id, direction: 'sent', chat_jid: chat, status: 'delivered' }.to_json }
    end
  end

  def webhook(chat: jid, id: source_id, type: 'sender_revoke', token: 'test-secret')
    payload = { event: 'message.exchange', instanceData: { instance: 'pilot' },
                data: { direction: 'outgoing', id: id, chat: { jid: chat }, message: { type: 'message_revoke', revoke: { revokeType: type } } } }
    post '/webhooks/ryze', params: payload, headers: { Authorization: "Bearer #{token}" }, as: :json
  end

  it 'applies a correlated provider confirmation once to the original row' do
    stub_status
    revoke.to_return(body: confirmation.to_json)
    2.times do
      delete_message
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include('id' => message.id, 'content_attributes' => include('deleted' => true))
    end
    expect(revoke).to have_been_requested.once
  end

  context 'when Ryze acknowledges a revoke with a different ID' do
    let(:missing) { { status: 404, body: { success: false, error: { message: 'Mensagem não encontrada' } }.to_json } }
    let(:ack_chat) { jid }

    def snapshot
      @snapshot ||= stub_request(:get, "#{provider}/getMessage/pilot").with(query: { messageId: source_id })
    end

    before do
      stub_status
      revoke.to_return(body: confirmation.merge(message_id: 'WA-REVOKE-1', chat_jid: ack_chat).to_json)
    end

    it 'confirms the original, including after reopening, with one delete and a read of the original ID' do
      snapshot.to_return(missing)
      2.times { delete_message }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include('id' => message.id, 'content_attributes' => include('deleted' => true))
      get api_v1_account_conversation_messages_path(account, conversation.display_id), headers: agent.create_new_auth_token
      expect(response.parsed_body.fetch('payload')).to include(include('id' => message.id, 'content_attributes' => include('deleted' => true)))
      expect(snapshot).to have_been_requested.once
      expect(revoke).to have_been_requested.once
    end

    it 'rechecks a temporarily visible original using only reads' do
      snapshot.to_return(body: { success: true, messageId: source_id, data: { type: 'text', content: 'original' } }.to_json).then.to_return(missing)
      delete_message
      expect(response).to have_http_status(:accepted)
      expect(message.reload.content).to eq('original')
      perform_enqueued_jobs(only: Ryze::ConfirmOutgoingDeletionJob)
      expect(message.reload.deleted).to be(true)
      expect(snapshot).to have_been_requested.twice
      expect(revoke).to have_been_requested.once
    end

    it 'keeps the content if the read returns a generic 404' do
      snapshot.to_return(status: 404, body: 'Not Found')
      perform_enqueued_jobs(only: Ryze::ConfirmOutgoingDeletionJob) { delete_message }
      expect(response).to have_http_status(:accepted)
      expect(snapshot).to have_been_requested.times(3)
      expect(message.reload.content).to eq('original')
      expect(revoke).to have_been_requested.once
    end

    it 'skips a deferred read once an authenticated webhook confirmed the original' do
      snapshot.to_return(status: 503)
      delete_message
      expect(response).to have_http_status(:accepted)
      webhook
      perform_enqueued_jobs(only: Ryze::ConfirmOutgoingDeletionJob)
      expect(snapshot).to have_been_requested.once
      expect(revoke).to have_been_requested.once
      expect(message.reload.deleted).to be(true)
    end

    context 'with another chat in the acknowledgement' do
      let(:ack_chat) { 'another@lid' }

      it 'ignores an acknowledgement for another chat without starting readback' do
        delete_message
        expect(response).to have_http_status(:accepted)
        expect(message.reload.content).to eq('original')
        expect(WebMock).not_to have_requested(:get, %r{/chat/getMessage/})
      end
    end
  end

  context 'with a pending remote deletion' do
    before do
      stub_status
      revoke.to_timeout
      delete_message
    end

    it 'returns the same pending state and blocks conflicting edits and deletes' do
      delete_message
      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body).to eq('status' => 'pending')
      delete_message(:delete_only_in_chatwoot)
      expect(response).to have_http_status(:conflict)
      delete path, headers: agent.create_new_auth_token
      expect(response).to have_http_status(:conflict)
      post "#{path}/edit_content", params: { content: 'updated' }, headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:conflict)
      expect(message.reload.content).to eq('original')
      expect(revoke).to have_been_requested.once
    end

    it 'requires the authenticated outgoing sender revoke on the same chat and message' do
      webhook(chat: 'another@lid')
      webhook(id: 'another-id')
      webhook(type: 'admin_revoke')
      webhook(token: 'wrong')
      expect(message.reload.content).to eq('original')
      webhook
      expect(response).to have_http_status(:ok)
      expect(message.reload.deleted).to be(true)
      expect { webhook }.not_to(change { message.reload.updated_at })
      delete_message
      expect(response).to have_http_status(:ok)
      expect(revoke).to have_been_requested.once
    end
  end

  it 'requires every field of the documented revoke confirmation' do
    stub_status
    revoke.to_return(body: confirmation.merge(deleted_for_everyone: false, delete_type: 'delete_for_me').to_json)
    delete_message
    expect(response).to have_http_status(:accepted)
    expect(message.reload.content).to eq('original')
  end

  it 'preserves local content on a definitive rejection and allows a fresh request' do
    stub_status
    revoke.to_return(status: 503, body: { success: false, status: 'disconnected' }.to_json).then.to_return(body: confirmation.to_json)
    delete_message
    expect(response).to have_http_status(:bad_gateway)
    expect(message.reload.content).to eq('original')
    delete_message
    expect(response).to have_http_status(:ok)
  end

  it 'retains an ambiguous proxy 503 and never sends the revoke twice' do
    stub_status
    revoke.to_return(status: 503, body: '<html>Service unavailable</html>')
    2.times do
      delete_message
      expect(response).to have_http_status(:accepted)
    end
    expect(message.reload.content).to eq('original')
    expect(revoke).to have_been_requested.once
  end

  it 'rejects the exact time boundary and a different author' do
    freeze_time do
      delete_message(user: other_agent)
      expect(response).to have_http_status(:forbidden)
      message.update!(created_at: 15.minutes.ago)
      delete_message
      expect(response).to have_http_status(422)
      expect(response.parsed_body).to eq('error_code' => 'delete_expired')
    end
  end

  it 'rechecks the window after the provider lookup' do
    freeze_time do
      message.update!(created_at: 14.minutes.ago)
      stub_status { travel 1.minute }
      delete_message
      expect(response).to have_http_status(422)
      expect(response.parsed_body).to eq('error_code' => 'delete_expired')
      expect(WebMock).not_to have_requested(:delete, %r{/chat/delete/})
    end
  end

  it 'honors a racing authenticated confirmation even if the HTTP response reports an error' do
    stub_status
    revoke.to_return do
      webhook
      { status: 503, body: { success: false }.to_json }
    end
    delete_message
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('id' => message.id, 'content_attributes' => include('deleted' => true))
  end

  it 'does not revoke a message deleted locally during the preflight lookup' do
    stub_status { delete_message(:delete_only_in_chatwoot) }
    delete_message
    expect(response).to have_http_status(422)
    expect(WebMock).not_to have_requested(:delete, %r{/chat/delete/})
  end

  it 'rejects an unverified source ID and a different provider chat without sending' do
    stub_status(chat: 'another@lid')
    delete_message
    expect(response).to have_http_status(422)
    message.update!(additional_attributes: {})
    delete_message
    expect(response).to have_http_status(422)
    expect(message.reload.content).to eq('original')
    expect(WebMock).not_to have_requested(:delete, %r{/chat/delete/})
  end

  it 'blocks remote and local deletion during an edit' do
    claim = Ryze::EditClaim.new(message.id)
    claim.acquire('updated', original: message)
    [:delete_for_everyone, :delete_only_in_chatwoot].each do |action|
      delete_message(action)
      expect(response).to have_http_status(:conflict)
    end
    expect(message.reload.content).to eq('original')
  ensure
    claim&.release
  end

  it 'lets another agent remove an old untracked message locally without notifying the native bridge' do
    message.update!(created_at: 1.day.ago, additional_attributes: {})
    inbox.channel.update!(webhook_url: 'https://bridge.example.org/ryze')
    subscriber = create(:webhook, account: account, subscriptions: ['message_updated'])
    create(:webhook, account: account, url: inbox.channel.webhook_url, subscriptions: ['message_updated'])
    perform_enqueued_jobs(only: EventDispatcherJob)
    clear_enqueued_jobs

    perform_enqueued_jobs(only: EventDispatcherJob) do
      delete_message(:delete_only_in_chatwoot, user: other_agent)
    end
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('id' => message.id, 'content_attributes' => include('deleted' => true))
    webhooks = enqueued_jobs.select { |job| job[:job] == WebhookJob }.pluck(:args)
    expect(webhooks.map(&:first)).to eq([subscriber.url])
    recipients = enqueued_jobs.select { |job| job[:job] == ActionCableBroadcastJob && job[:args][1] == 'message.updated' }
                              .flat_map { |job| job[:args].first }
    expect(recipients).to include(other_agent.pubsub_token)
    expect(recipients).not_to include(agent.pubsub_token) # The bridge uses this user's token.
    expect(WebMock).not_to have_requested(:delete, %r{/chat/delete/})
  end

  it 'keeps a queued or in-flight original available for delivery' do
    %w[queued sending].each do |state|
      message.additional_attributes['ryze_outbound_delivery']['state'] = state
      message.save!
      delete_message(:delete_only_in_chatwoot)
      expect(response).to have_http_status(:conflict)
      expect(message.reload.content).to eq('original')
    end
  end

  it 'rejects the local route outside the pilot' do
    with_modified_env(RYZE_EDIT_CONVERSATION_ID: (conversation.display_id + 1).to_s) { delete_message(:delete_only_in_chatwoot) }
    expect(response).to have_http_status(422)
    expect(message.reload.content).to eq('original')
  end

  it 'marks old pilot messages in the seed and history for other agents' do
    message.update!(created_at: 2.hours.ago)
    headers = other_agent.create_new_auth_token
    get api_v1_account_conversation_path(account.id, conversation.display_id), headers: headers, as: :json
    expect(response.parsed_body.fetch('messages').sole).to include('ryze_delete_scopes' => true)
    get api_v1_account_conversation_messages_path(account.id, conversation.display_id), headers: headers, as: :json
    expect(response.parsed_body.fetch('payload').sole).to include('ryze_delete_scopes' => true)
    get public_api_v1_inbox_contact_conversation_messages_path(inbox.channel.identifier, conversation.contact_inbox.source_id,
                                                               conversation.display_id)
    expect(response.parsed_body.sole).not_to have_key('ryze_delete_scopes')
  end
end
