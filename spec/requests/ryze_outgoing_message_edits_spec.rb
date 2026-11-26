require 'rails_helper'

RSpec.describe 'Ryze outgoing message edits', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:agent) { create(:user, account: account, role: :administrator) }
  let(:jid) { '15550001111@s.whatsapp.net' }
  let(:conversation) { create(:conversation, inbox: inbox, account: account, additional_attributes: { whatsapp_jid: jid }) }
  let(:source_id) { 'ORIGINAL_MESSAGE_ID' }
  let(:content) { 'Corrected text' }
  let(:message) do
    reply = build(:message, account: account, inbox: inbox, conversation: conversation, sender: agent,
                            message_type: :outgoing, content: 'Original text', status: :delivered, source_id: source_id,
                            additional_attributes: { ryze_outbound_message_id: source_id })
    Ryze::OutboundDelivery.prepare(reply)
    reply.additional_attributes[Ryze::OutboundDelivery::DELIVERY_KEY]['state'] = 'confirmed'
    reply.tap(&:save!)
  end
  let(:endpoint) do
    edit_content_api_v1_account_conversation_message_path(account_id: account.id, conversation_id: conversation.display_id, id: message.id)
  end
  let(:provider) { 'https://ryzeapi.cloud/api/chat' }

  around do |example|
    with_modified_env(RYZE_INBOX_ID: inbox.id.to_s, RYZE_INSTANCE_NAME: 'Pilot / Dev',
                      RYZE_PILOT_CHAT_JID: jid, RYZE_EDIT_CONVERSATION_ID: conversation.display_id.to_s,
                      RYZE_EDIT_API_TOKEN: 'test-edit-token', RYZE_WEBHOOK_SECRET: 'test-webhook-secret',
                      RYZE_NATIVE_BRIDGE_USER_ID: agent.id.to_s) { example.run }
  end

  after do
    Redis::Alfred.delete("RYZE_OUTGOING_EDIT:#{message.id}")
  end

  def submit_edit(value: content, user: agent)
    post endpoint, params: { content: value }, headers: user.create_new_auth_token, as: :json
  end

  def stub_verified_message(snapshot: 'Original text', status: {}, snapshot_id: source_id, type: 'text')
    stub_request(:get, "#{provider}/status/Pilot%20%2F%20Dev")
      .with(query: { messageId: source_id }, headers: { 'token' => 'test-edit-token' })
      .to_return(body: { success: true, message_id: source_id, chat_jid: jid, direction: 'sent', status: 'delivered' }.merge(status).to_json)
    stub_request(:get, "#{provider}/getMessage/Pilot%20%2F%20Dev")
      .with(query: { messageId: source_id }, headers: { 'token' => 'test-edit-token' })
      .to_return(body: { success: true, messageId: snapshot_id, data: { type: type, content: snapshot } }.to_json)
  end

  def stub_edit
    stub_request(:post, "#{provider}/edit/Pilot%20%2F%20Dev")
      .with(body: { messageId: source_id, content: content }.to_json, headers: { 'token' => 'test-edit-token' })
  end

  it 'accepts a provider edit and waits for confirmation before changing the message' do
    message
    stub_verified_message
    edit = stub_edit.to_return(body: { success: true, messageId: source_id, chatJid: jid, newContent: content }.to_json)

    expect { submit_edit }.not_to change(Message, :count)

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body['status']).to eq('pending')
    expect(message.reload.content).to eq('Original text')
    expect(message.additional_attributes.keys).to match_array(%w[ryze_outbound_message_id ryze_outbound_delivery])
    expect(edit).to have_been_requested.once
  end

  it 'reopens the corrected message after a verified read when the edit webhook never arrives' do
    stub_verified_message
    edit = stub_edit.to_return(body: { success: true }.to_json)
    submit_edit
    expect(response).to have_http_status(:accepted)
    expect(message.reload.content).to eq('Original text')

    stub_verified_message(snapshot: content)
    perform_enqueued_jobs(only: Ryze::ConfirmOutgoingEditJob)

    get api_v1_account_conversation_messages_path(account.id, conversation.display_id), headers: agent.create_new_auth_token
    expect(response.parsed_body.fetch('payload')).to contain_exactly(include('id' => message.id, 'source_id' => source_id, 'content' => content,
                                                                             'content_attributes' => include('edited' => true)))
    expect(edit).to have_been_requested.once
  end

  describe 'pending edit readback' do
    let(:timed_out_edit) { stub_edit.to_timeout }

    before do
      stub_verified_message
      timed_out_edit
      submit_edit
    end

    def run_readback
      perform_enqueued_jobs(only: Ryze::ConfirmOutgoingEditJob)
    end

    it 'rechecks stale text once after an ambiguous POST and confirms a later matching snapshot' do
      run_readback
      expect(message.reload.content).to eq('Original text')

      stub_verified_message(snapshot: content)
      run_readback
      expect(message.reload.content).to eq(content)
      expect(timed_out_edit).to have_been_requested.once
    end

    it 'bounds attempts when the provider keeps timing out' do
      status = stub_request(:get, %r{/chat/status/}).to_timeout
      3.times { run_readback }
      expect(status).to have_been_requested.times(3) # One preflight and two readbacks.
      expect(message.reload.content).to eq('Original text')
      expect(timed_out_edit).to have_been_requested.once
    end

    {
      'destination' => { status: { chat_jid: 'another@lid' } },
      'direction' => { status: { direction: 'received' } },
      'status ID' => { status: { message_id: 'OTHER' } },
      'snapshot ID' => { snapshot_id: 'OTHER' },
      'message type' => { type: 'image' }
    }.each do |field, mismatch|
      it "rejects matching text with a different #{field}" do
        stub_verified_message(snapshot: content, **mismatch)
        expect { run_readback }.not_to(change { message.reload.content })
        expect(enqueued_jobs.pluck(:job)).not_to include(Ryze::ConfirmOutgoingEditJob)
      end
    end

    it 'drops a delayed job after its claim expires' do
      Redis::Alfred.expire("RYZE_OUTGOING_EDIT:#{message.id}", 0)
      run_readback
      expect(WebMock).to have_requested(:get, %r{/chat/status/}).once
      expect(message.reload.content).to eq('Original text')
    end

    it 'skips a read after the pilot credentials change' do
      with_modified_env(RYZE_EDIT_API_TOKEN: 'rotated-token') { run_readback }
      expect(WebMock).to have_requested(:get, %r{/chat/status/}).once
      expect(message.reload.content).to eq('Original text')
    end

    it 'binds the pending edit to its original provider even if the delivery is rebound' do
      with_modified_env(RYZE_INSTANCE_NAME: 'replacement-instance') do
        Ryze::OutboundDelivery.prepare(message)
        message.additional_attributes[Ryze::OutboundDelivery::DELIVERY_KEY]['state'] = 'confirmed'
        message.save!
        run_readback
      end
      expect(WebMock).not_to have_requested(:get, %r{/replacement-instance})
      expect(message.reload.content).to eq('Original text')
    end

    it 'preserves a deletion committed while the snapshot was being read' do
      stub_request(:get, %r{/chat/getMessage/}).to_return do
        message.mark_deleted!
        { body: { success: true, messageId: source_id, data: { type: 'text', content: content } }.to_json }
      end
      run_readback
      expect(message.reload.deleted).to be(true)
      expect(message.content).to eq(I18n.t('conversations.messages.deleted'))
    end

    it 'preserves a webhook revision committed while the snapshot was being read' do
      stub_request(:get, %r{/chat/getMessage/}).to_return do
        message.with_lock { Ryze::MessageEdit.apply(message, content: 'Webhook revision', edited_at: 1.second.from_now) }
        { body: { success: true, messageId: source_id, data: { type: 'text', content: content } }.to_json }
      end
      run_readback
      expect(message.reload.content).to eq('Webhook revision')
    end

    it 'discards the snapshot if another attempt has acquired the expired claim during the read' do
      replacement = Ryze::EditClaim.new(message.id)
      stub_request(:get, %r{/chat/getMessage/}).to_return do
        Redis::Alfred.delete("RYZE_OUTGOING_EDIT:#{message.id}")
        expect(replacement.acquire(content, original: message)).to be_truthy
        { body: { success: true, messageId: source_id, data: { type: 'text', content: content } }.to_json }
      end
      run_readback
      expect(message.reload.content).to eq('Original text')
      expect(replacement.active?).to be(true)
    end
  end

  it 'waits for the webhook if normalization made the requested text indistinguishable from the preflight' do
    message.update!(content: "Original text\n")
    stub_verified_message
    stub_request(:post, %r{/chat/edit/}).to_return(body: { success: true }.to_json)
    expect { submit_edit(value: 'Original text') }.not_to have_enqueued_job(Ryze::ConfirmOutgoingEditJob)
    expect(response).to have_http_status(:accepted)
    expect(message.reload.content_attributes).not_to include('edited')
  end

  it 'blocks a second request while the original command is pending' do
    stub_verified_message
    edit = stub_edit.to_return(body: { success: true, messageId: source_id, chatJid: jid, newContent: content }.to_json)
    submit_edit
    submit_edit

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['error_code']).to eq('edit_pending')
    expect(edit).to have_been_requested.once
  end

  it 'returns the confirmed message when the provider event already updated it' do
    stub_verified_message
    stub_edit.to_return do
      message.update!(content: content, content_attributes: { edited: true },
                      additional_attributes: message.additional_attributes.merge('ryze_edited_at' => Time.current.utc.iso8601(9)))
      { body: { success: true, messageId: source_id, chatJid: jid, newContent: content }.to_json }
    end

    submit_edit

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('id' => message.id, 'content' => content, 'can_edit_content' => true)
  end

  it 'returns an expired result for the provider error and preserves local text' do
    stub_verified_message
    stub_edit.to_return(status: 400, body: { success: false, error: { message: 'message too old to edit' } }.to_json)
    submit_edit

    expect(response).to have_http_status(422)
    expect(response.parsed_body).to eq('error_code' => 'edit_expired')
    expect(message.reload.content).to eq('Original text')
  end

  it 'does not retry a timed out POST or falsely confirm delivery' do
    stub_verified_message
    edit = stub_edit.to_timeout
    submit_edit

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body['status']).to eq('pending')
    expect(message.reload.content).to eq('Original text')
    expect(edit).to have_been_requested.once
  end

  it 'rejects a caller-supplied source ID without a trusted provider binding' do
    message.update!(additional_attributes: {})
    submit_edit

    expect(response).to have_http_status(422)
    expect(response.parsed_body['error_code']).to eq('edit_unavailable')
  end

  it 'rejects the old provider binding after the configured token changes' do
    message
    with_modified_env(RYZE_EDIT_API_TOKEN: 'different-instance-token') { submit_edit }

    expect(response).to have_http_status(422)
    expect(response.parsed_body).to eq('error_code' => 'edit_unavailable')
  end

  it 'rejects a provider message from another chat before sending an edit' do
    stub_verified_message(status: { chat_jid: 'unrelated@lid' })
    submit_edit

    expect(response).to have_http_status(422)
    expect(response.parsed_body['error_code']).to eq('edit_unavailable')
    expect(WebMock).not_to have_requested(:post, "#{provider}/edit/Pilot%20%2F%20Dev")
  end

  it 'fails closed when a previous edit changed the provider text without a local event' do
    stub_verified_message(snapshot: 'A different provider revision')
    submit_edit

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['error_code']).to eq('edit_pending')
    expect(WebMock).not_to have_requested(:post, "#{provider}/edit/Pilot%20%2F%20Dev")
  end

  it 'rejects a different agent even with access to the conversation' do
    submit_edit(user: create(:user, account: account, role: :administrator))

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['error_code']).to eq('edit_unavailable')
  end

  it 'rejects messages past the local edit window before contacting the provider' do
    message.update!(created_at: 15.minutes.ago)
    submit_edit

    expect(response).to have_http_status(422)
    expect(response.parsed_body).to eq('error_code' => 'edit_expired')
  end

  it 'rejects messages outside the configured pilot before contacting the provider' do
    conversation.update!(additional_attributes: { whatsapp_jid: 'different@lid' })
    submit_edit

    expect(response).to have_http_status(422)
    expect(response.parsed_body).to eq('error_code' => 'edit_unavailable')
  end

  it 'rejects another conversation with the same inbox and WhatsApp ID' do
    other_conversation = create(:conversation, inbox: inbox, account: account, additional_attributes: { whatsapp_jid: jid })
    message.update!(conversation: other_conversation)
    other_path = edit_content_api_v1_account_conversation_message_path(account.id, other_conversation.display_id, message.id)

    post other_path, params: { content: content }, headers: agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(422)
    expect(response.parsed_body).to eq('error_code' => 'edit_unavailable')
  end

  it 'advertises the edit capability only to the original agent in the account history' do
    endpoint_url = api_v1_account_conversation_messages_path(account.id, conversation.display_id)
    message

    get endpoint_url, headers: agent.create_new_auth_token, as: :json

    expect(response.parsed_body.fetch('payload').sole).to include('can_edit_content' => true)

    viewer = create(:user, account: account, role: :administrator)
    get endpoint_url, headers: viewer.create_new_auth_token, as: :json

    expect(response.parsed_body.fetch('payload').sole).not_to have_key('can_edit_content')

    get public_api_v1_inbox_contact_conversation_messages_path(
      inbox.channel.identifier, conversation.contact_inbox.source_id, conversation.display_id
    )

    expect(response.parsed_body.sole).not_to have_key('can_edit_content')
  end

  describe 'retrying an original delivery' do
    let(:retry_endpoint) { retry_api_v1_account_conversation_message_path(account.id, conversation.display_id, message.id) }

    def failed_delivery(state)
      Ryze::OutboundDelivery.prepare(message)
      attributes = message.additional_attributes.slice(Ryze::OutboundDelivery::DELIVERY_KEY)
      attributes[Ryze::OutboundDelivery::DELIVERY_KEY]['state'] = state
      message.update!(source_id: nil, additional_attributes: attributes, status: :failed)
    end

    it 'queues one tracked retry after definitive rejection' do
      failed_delivery('rejected')

      expect do
        post retry_endpoint, headers: agent.create_new_auth_token, as: :json
      end.to have_enqueued_job(Ryze::DeliverOutboundMessageJob).with(message.id, 2).once

      expect(response).to have_http_status(:accepted)
      post retry_endpoint, headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:conflict)
    end

    it 'leaves an ambiguous delivery untouched by the generic retry route' do
      failed_delivery('unknown')

      expect do
        post retry_endpoint, headers: agent.create_new_auth_token, as: :json
      end.not_to have_enqueued_job(Ryze::DeliverOutboundMessageJob)

      expect(response).to have_http_status(:conflict)
      expect(message.reload.status).to eq('failed')
    end
  end

  it 'rejects a request with a non-string replacement' do
    submit_edit(value: { 'arbitrary' => 'object' })

    expect(response).to have_http_status(422)
    expect(response.parsed_body['error_code']).to eq('invalid_content')
  end
end
