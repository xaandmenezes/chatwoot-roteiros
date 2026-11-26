require 'rails_helper'

RSpec.describe 'Ryze outgoing edit confirmations', type: :request do
  let(:inbox) { create(:channel_api).reload.inbox }
  let(:account) { inbox.account }
  let(:agent) { create(:user, account: account) }
  let(:jid) { '15550001111@s.whatsapp.net' }
  let(:source_id) { 'WA-OUTGOING-1' }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, additional_attributes: { whatsapp_jid: jid }) }
  let(:revision) { Time.current.change(usec: 0) }
  let(:original) do
    message = build(:message, account: account, inbox: inbox, conversation: conversation, sender: agent, message_type: :outgoing,
                              content: 'antes', source_id: source_id)
    Ryze::OutboundDelivery.prepare(message)
    message.additional_attributes['ryze_outbound_delivery']['state'] = 'confirmed'
    message.additional_attributes['ryze_outbound_message_id'] = source_id
    message.save!
    message
  end

  around do |example|
    with_modified_env(RYZE_WEBHOOK_SECRET: 'test-secret', RYZE_INSTANCE_NAME: 'pilot', RYZE_INBOX_ID: inbox.id.to_s,
                      RYZE_PILOT_CHAT_JID: jid, RYZE_EDIT_CONVERSATION_ID: conversation.display_id.to_s,
                      RYZE_EDIT_API_TOKEN: 'test-instance-token', RYZE_NATIVE_BRIDGE_USER_ID: '987654') { example.run }
  end

  def confirm(content: 'depois', at: revision, chat: jid, token: 'test-secret')
    payload = { event: 'message.exchange', instanceData: { instance: 'pilot' },
                data: { id: source_id, direction: 'outgoing', chat: { jid: chat },
                        message: { type: 'message_edit', isEdit: true, content: content, edit: { timestamp: at.iso8601(6) } } } }
    post '/webhooks/ryze', params: payload, headers: { 'Authorization' => "Bearer #{token}" }, as: :json
  end

  it 'updates the same bound outgoing message and clears only the confirmed edit claim' do
    claim = Ryze::EditClaim.new(original.id)
    expect(claim.acquire('depois', original: original)).to be_truthy
    expect { confirm }.not_to change(Message, :count)
    expect(response).to have_http_status(:ok)
    expect(original.reload).to have_attributes(content: 'depois', content_attributes: include('edited' => true))
    expect(original.additional_attributes.fetch('ryze_edited_at')).to eq(revision.utc.iso8601(9))
    expect(claim.acquire('again', original: original)).to be_truthy
  end

  it 'skips the provider lookup when the webhook already confirmed the pending edit' do
    claim = Ryze::EditClaim.new(original.id)
    claim.acquire('depois', original: original)
    confirm
    Ryze::ConfirmOutgoingEditJob.perform_now(original.id, claim.token, revision.to_i)
    expect(WebMock).not_to have_requested(:get, %r{/chat/status/})
    expect(original.reload.content).to eq('depois')
  end

  it 'preserves a newer revision across delayed and repeated confirmations' do
    original
    confirm
    expect do
      confirm
      confirm(content: 'atrasada', at: revision - 3.seconds)
    end.not_to(change { original.reload.updated_at })
    expect(original.content).to eq('depois')
  end

  it 'ignores caller-supplied IDs without a matching trusted delivery binding' do
    original.update!(additional_attributes: {})
    confirm
    expect(response).to have_http_status(:ok)
    expect(original.reload.content).to eq('antes')
  end

  it 'rejects invalid credentials and ignores another chat or missing pilot without changing the original' do
    original
    confirm(token: 'invalid')
    expect(response).to have_http_status(:unauthorized)
    confirm(chat: 'other@lid')
    with_modified_env(RYZE_PILOT_CHAT_JID: nil) { confirm }
    with_modified_env(RYZE_EDIT_CONVERSATION_ID: (conversation.display_id + 1).to_s) { confirm }
    with_modified_env(RYZE_EDIT_API_TOKEN: 'rotated-pilot-token') { confirm }
    expect(original.reload.content).to eq('antes')
  end

  it 'reports conflicting bindings instead of changing either row' do
    duplicate = original.dup
    duplicate.save!
    confirm
    expect(response).to have_http_status(:conflict)
    expect([original.reload.content, duplicate.reload.content]).to eq(%w[antes antes])
  end

  context 'when an agent sends and edits a new message from the dashboard' do
    let(:bridge_user) { create(:user, account: account) }
    let(:messages_path) { api_v1_account_conversation_messages_path(account_id: account.id, conversation_id: conversation.display_id) }

    around { |example| with_modified_env(RYZE_NATIVE_BRIDGE_USER_ID: bridge_user.id.to_s) { example.run } }

    it 'sends one text, edits its verified ID, and reopens the confirmed text in the same row' do
      create(:inbox_member, inbox: inbox, user: agent)
      headers = agent.create_new_auth_token
      text_send = stub_request(:post, 'https://ryzeapi.cloud/api/message/text/pilot').to_return do |request|
        sent = JSON.parse(request.body)
        expect(sent).to include('number' => jid, 'message' => 'antes')
        { body: { success: true, status: 'sent', data: { source: sent.fetch('source'), messageId: source_id, direction: 'outgoing',
                                                         messageType: 'text', content: sent.fetch('message'), chat: { jid: jid } } }.to_json }
      end
      perform_enqueued_jobs(only: [EventDispatcherJob, Ryze::DeliverOutboundMessageJob]) do
        post messages_path, params: { content: 'antes', message_type: 'outgoing', private: false }, headers: headers, as: :json
      end
      original_id = response.parsed_body.fetch('id')

      stub_request(:get, 'https://ryzeapi.cloud/api/chat/status/pilot').with(query: { messageId: source_id }).to_return(
        body: { success: true, message_id: source_id, direction: 'sent', status: 'delivered', chat_jid: jid }.to_json
      )
      stub_request(:get, 'https://ryzeapi.cloud/api/chat/getMessage/pilot').with(query: { messageId: source_id }).to_return(
        body: { success: true, messageId: source_id, data: { type: 'text', content: 'antes' } }.to_json
      )
      edit = stub_request(:post, 'https://ryzeapi.cloud/api/chat/edit/pilot').with(body: { messageId: source_id, content: 'depois' }).to_return(
        body: { success: true, messageId: source_id, chatJid: jid, oldContent: 'antes', newContent: 'depois' }.to_json
      )
      post "#{messages_path}/#{original_id}/edit_content", params: { content: 'depois' }, headers: headers, as: :json
      expect(response).to have_http_status(:accepted)
      expect(conversation.messages.find(original_id).content).to eq('antes')
      confirm
      expect(response).to have_http_status(:ok)

      get messages_path, headers: headers
      messages = response.parsed_body.fetch('payload').select { |entry| entry['message_type'].to_i == 1 }
      expect(messages).to contain_exactly(include('id' => original_id, 'source_id' => source_id,
                                                  'content' => 'depois', 'content_attributes' => include('edited' => true)))
      expect(text_send).to have_been_requested.once
      expect(edit).to have_been_requested.once
    end
  end

  it 'keeps delayed signed events in provider order after a readback with no provider timestamp' do
    submitted_at = Time.current.utc.change(usec: 500_000)
    claim = Ryze::EditClaim.new(original.id)
    claim.acquire('snapshot', original: original)
    provider = instance_double(Ryze::EditProvider, text: 'snapshot')
    allow(Ryze::EditProvider).to receive(:new).and_return(provider)

    Ryze::ConfirmOutgoingEditJob.perform_now(original.id, claim.token, submitted_at.to_i)
    confirm(content: 'older webhook', at: submitted_at - 2.seconds)
    expect(original.reload.content).to eq('snapshot')

    # Ryze can report a later edit in the same second with whole-second precision.
    confirm(content: 'signed correction', at: submitted_at.change(usec: 0))
    expect(original.reload.content).to eq('signed correction')
  end

  it 'advances the previous signed revision when the command shares its timestamp' do
    original
    confirm(content: 'previous edit', at: revision)
    expect(original.reload.content).to eq('previous edit')
    claim = Ryze::EditClaim.new(original.id)
    claim.acquire('next edit', original: original)
    provider = instance_double(Ryze::EditProvider, text: 'next edit')
    allow(Ryze::EditProvider).to receive(:new).and_return(provider)

    Ryze::ConfirmOutgoingEditJob.perform_now(original.id, claim.token, revision.to_i)
    confirm(content: 'previous edit', at: revision)
    expect(original.reload.content).to eq('next edit')
  end

  it 'does not restore a locally deleted team message' do
    original.mark_deleted!
    expect { confirm }.not_to(change { original.reload.content })
  end
end
