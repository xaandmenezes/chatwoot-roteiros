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
        before: nil
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
