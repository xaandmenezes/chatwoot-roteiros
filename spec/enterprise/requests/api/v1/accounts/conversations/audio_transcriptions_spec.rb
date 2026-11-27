require 'rails_helper'

RSpec.describe 'Ryze audio transcription access with a custom role', type: :request do
  it 'requires participation when the agent has a participating-only role' do
    account = create(:account)
    inbox = create(:channel_api, account: account).inbox
    agent = create(:user, account: account, role: :agent)
    role = create(:custom_role, account: account, permissions: ['conversation_participating_manage'])
    account.account_users.find_by!(user: agent).update!(custom_role: role)
    create(:inbox_member, user: agent, inbox: inbox)
    conversation = create(:conversation, account: account, inbox: inbox).reload
    headers = agent.create_new_auth_token
    path = api_v1_account_conversation_audio_transcriptions_path(account, conversation.display_id)

    with_modified_env(RYZE_AUDIO_TRANSCRIPTION_ENABLED: 'true', RYZE_INBOX_ID: inbox.id.to_s, RYZE_AUDIO_TRANSCRIPTION_CONVERSATION_ID: 'all') do
      get path, headers: headers, params: { attachment_ids: [1] }
      expect(response).to have_http_status(:unauthorized)

      create(:conversation_participant, account: account, user: agent, conversation: conversation)
      get path, headers: headers, params: { attachment_ids: [1] }
      expect(response).to have_http_status(:ok)
    end
  end
end
