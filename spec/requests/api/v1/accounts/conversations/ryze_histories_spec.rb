require 'rails_helper'

RSpec.describe 'Ryze historical sync API', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:agent) { build_agent(inbox) }
  let(:contact) { create(:contact, account: account) }
  let(:jid) { '5511999999999@s.whatsapp.net' }
  let(:conversation) do
    create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      additional_attributes: { 'whatsapp_jid' => jid }
    )
  end
  let(:history_path) do
    api_v1_account_conversation_ryze_history_path(conversation.account_id, conversation.display_id)
  end

  around do |example|
    with_modified_env(
      RYZE_INSTANCE_NAME: 'test-instance',
      RYZE_EDIT_API_TOKEN: 'test-token',
      RYZE_WEBHOOK_SECRET: 'test-secret',
      RYZE_INBOX_ID: inbox.id.to_s,
      RYZE_PILOT_CHAT_JID: jid,
      RYZE_EDIT_CONVERSATION_ID: conversation.reload.display_id.to_s,
      RYZE_HISTORY_SYNC_ENABLED: 'true'
    ) { example.run }
  end

  def build_agent(member_inbox = nil)
    create(:user).tap do |user|
      create(:account_user, account: account, user: user, role: :agent)
      create(:inbox_member, inbox: member_inbox, user: user) if member_inbox
    end
  end

  describe 'POST /api/v1/accounts/:account_id/conversations/:conversation_id/ryze_history' do
    context 'with direct inbox mode enabled' do
      around { |example| with_modified_env(RYZE_DIRECT_INBOX_ENABLED: 'true', RYZE_HISTORY_BINDING_SECRET: 'test-only-binding-key') { example.run } }

      let(:attributes) { { whatsapp_jid: jid, ryze_history_binding: 'client-provided', referral: 'allowed' } }

      it 'reserves the provider binding on creation' do
        post api_v1_account_conversations_path(account), headers: agent.create_new_auth_token, as: :json,
                                                         params: { inbox_id: inbox.id, contact_id: contact.id, additional_attributes: attributes }
        expect(response).to have_http_status(:ok)
        created = account.conversations.find_by!(display_id: response.parsed_body.fetch('id'))
        expect(created.additional_attributes).to eq('referral' => 'allowed')
      end

      it 'does not allow updating the provider binding through the conversation API' do
        path = api_v1_account_conversation_path(account, conversation.display_id)
        patch path, headers: agent.create_new_auth_token, as: :json, params: { additional_attributes: attributes.merge(whatsapp_jid: 'another') }
        expect(response).to have_http_status(:ok)
        expect(conversation.reload.additional_attributes).to eq('whatsapp_jid' => jid)
      end

      it 'only syncs the attested conversation, not a legacy or copied binding in the same inbox' do
        post history_path, as: :json, headers: agent.create_new_auth_token
        expect(response).to have_http_status(:not_found)
        Rake::Task['ryze:bind_history'].execute(account_id: account.id, display_id: conversation.display_id.to_s, jid: jid)
        other = create(:conversation, account: account, inbox: inbox, additional_attributes: conversation.reload.additional_attributes)
        post api_v1_account_conversation_ryze_history_path(account, other.display_id), as: :json, headers: agent.create_new_auth_token
        expect(response).to have_http_status(:not_found)

        stub_request(:post, 'https://ryzeapi.cloud/api/chat/history/test-instance').to_return(body: { success: true, messages: [] }.to_json)
        post history_path, as: :json, headers: agent.create_new_auth_token
        expect(response).to have_http_status(:ok)
      end

      it 'fails closed without the binding secret, after rotation, or when the contact changes' do
        Ryze::HistoryBinding.bind!(conversation, jid)
        [nil, 'rotated-test-key'].each do |secret|
          with_modified_env(RYZE_HISTORY_BINDING_SECRET: secret) do
            post history_path, as: :json, headers: agent.create_new_auth_token
            expect(response).to have_http_status(:not_found)
          end
        end
        conversation.update!(contact: create(:contact, account: account))
        post history_path, as: :json, headers: agent.create_new_auth_token
        expect(response).to have_http_status(:not_found)
      end

      it 'preserves the binding when reopening the same conversation without changing its identity' do
        conversation.resolved!
        Ryze::HistoryBinding.bind!(conversation, jid)
        conversation.open!
        stub_request(:post, 'https://ryzeapi.cloud/api/chat/history/test-instance').to_return(body: { success: true, messages: [] }.to_json)
        post history_path, as: :json, headers: agent.create_new_auth_token
        expect(response).to have_http_status(:ok)
      end

      it 'rechecks the binding under lock if the contact changes while fetching history' do
        Ryze::HistoryBinding.bind!(conversation, jid)
        replacement = create(:contact, account: account)
        stub_request(:post, 'https://ryzeapi.cloud/api/chat/history/test-instance').to_return do
          Conversation.find(conversation.id).update!(contact: replacement)
          { body: { success: true, messages: [{ id: 'not-imported', type: 'text', content: 'test' }] }.to_json }
        end
        post history_path, as: :json, headers: agent.create_new_auth_token
        expect(response).to have_http_status(:not_found)
        expect(conversation.messages.exists?(source_id: 'not-imported')).to be(false)
      end
    end

    it 'repairs the fifth media from an exhausted page without fetching history or accepting a size mismatch' do
      items = Array.new(5) { |i| { id: "media-#{i}", type: 'image', mediaSize: 3 } }
      page = stub_request(:post, 'https://ryzeapi.cloud/api/chat/history/test-instance').to_return(body: { success: true, messages: items }.to_json)
      media = stub_request(:get, %r{/chat/base64/}).to_return(body: { success: true, base64: Base64.strict_encode64('abc') }.to_json)
      headers = agent.create_new_auth_token
      post history_path, as: :json, headers: headers
      expect(response.parsed_body.fetch('meta')).to include('has_more' => false, 'imported_count' => 5)
      pending = conversation.messages.find_by!(source_id: 'media-4')
      expect(response.parsed_body.fetch('payload').find { |m| m['id'] == pending.id }).to include('historical_media_pending' => true)
      expect(media).to have_been_requested.times(4)

      retry_path = "#{history_path}/media/#{pending.id}"
      stub_request(:get, %r{/chat/base64/}).to_return(
        { body: { success: true, base64: Base64.strict_encode64('short?') }.to_json },
        { body: { success: true, base64: Base64.strict_encode64('abc') }.to_json }
      )
      post retry_path, as: :json, headers: headers
      expect(response).to have_http_status(:bad_gateway)
      post retry_path, as: :json, headers: headers
      expect(response).to have_http_status(:ok)
      expect(pending.reload.attachments.sole.file.download).to eq('abc')
      expect(page).to have_been_requested.once
    end

    it 'does not allow repair outside the bound conversation or on a normal delivery' do
      headers = agent.create_new_auth_token
      live = create(:message, account: account, inbox: inbox, conversation: conversation)
      other = create(:conversation, account: account, inbox: inbox)
      historical = create(:message, account: account, inbox: inbox, conversation: other, additional_attributes: { ryze_historical_sync: true })
      [live, historical].each do |message|
        post "#{history_path}/media/#{message.id}", headers: headers
        expect(response).to have_http_status(:not_found)
      end
      with_modified_env(RYZE_DIRECT_INBOX_ENABLED: 'true', RYZE_HISTORY_BINDING_SECRET: 'test-only') do
        post "#{history_path}/media/#{live.id}", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end

    it 'returns 422 for malformed cursors without querying the provider' do
      ['not-a-time', {}, -1, 2.5, ''].each do |cursor|
        post history_path, params: { before: cursor }, as: :json, headers: agent.create_new_auth_token
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    it 'returns 404 when historical sync is disabled' do
      with_modified_env(RYZE_HISTORY_SYNC_ENABLED: 'false') do
        post history_path, as: :json, headers: agent.create_new_auth_token
        expect(response).to have_http_status(:not_found)
      end
    end

    it 'returns 404 for a conversation outside the pilot' do
      other_chat = create(:conversation, account: account, inbox: inbox, additional_attributes: { 'whatsapp_jid' => 'other@s.whatsapp.net' })
      other_path = api_v1_account_conversation_ryze_history_path(other_chat.account_id, other_chat.display_id)

      post other_path, as: :json, headers: agent.create_new_auth_token
      expect(response).to have_http_status(:not_found)
    end

    it 'returns 401 when unauthenticated' do
      post history_path, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns 200 with meta and payload on successful sync' do
      sync_service = instance_double(Ryze::HistoricalSync)
      next_before_time = 2.days.ago.to_i
      msg = create(
        :message,
        conversation: conversation,
        account: account,
        inbox: inbox,
        content: 'Historical message',
        source_id: 'hist-1',
        created_at: 2.days.ago
      )
      result = Ryze::HistoricalSync::Result.new(
        imported_messages: [msg],
        has_more: true,
        next_before: next_before_time
      )

      allow(Ryze::HistoricalSync).to receive(:new).with(
        conversation: conversation,
        before: nil,
        actor: agent
      ).and_return(sync_service)
      allow(sync_service).to receive(:perform).and_return(result)

      post history_path, as: :json, headers: agent.create_new_auth_token
      expect(response).to have_http_status(:ok)

      body = response.parsed_body
      expect(body['meta']).to eq(
        'has_more' => true,
        'next_before' => next_before_time,
        'imported_count' => 1
      )
      expect(body['payload']).to be_an(Array)
      expect(body['payload'].first['id']).to eq(msg.id)
      expect(body['payload'].first['content']).to eq('Historical message')
      expect(body['payload'].first['ryze_delete_scopes']).to be true
    end

    it 'returns 429 when Ryze hits rate limits' do
      sync_service = instance_double(Ryze::HistoricalSync)
      allow(Ryze::HistoricalSync).to receive(:new).and_return(sync_service)
      allow(sync_service).to receive(:perform).and_raise(Ryze::HistoricalSync::RateLimitError, 'Rate limit exceeded')

      post history_path, as: :json, headers: agent.create_new_auth_token
      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body['error']).to eq('Rate limit exceeded')
    end

    it 'returns 502 when Ryze upstream error occurs' do
      sync_service = instance_double(Ryze::HistoricalSync)
      allow(Ryze::HistoricalSync).to receive(:new).and_return(sync_service)
      allow(sync_service).to receive(:perform).and_raise(Ryze::HistoricalSync::UpstreamError, 'Upstream failure')

      post history_path, as: :json, headers: agent.create_new_auth_token
      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body['error']).to eq('Upstream failure')
    end

    it 'returns 502 when a network timeout occurs' do
      sync_service = instance_double(Ryze::HistoricalSync)
      allow(Ryze::HistoricalSync).to receive(:new).and_return(sync_service)
      allow(sync_service).to receive(:perform).and_raise(Net::ReadTimeout, 'Read timeout')

      post history_path, as: :json, headers: agent.create_new_auth_token
      expect(response).to have_http_status(:bad_gateway)
    end
  end
end
