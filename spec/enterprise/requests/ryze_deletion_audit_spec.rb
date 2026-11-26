require 'rails_helper'

RSpec.describe 'Ryze agent deletion audit', type: :request do
  let(:inbox) { create(:channel_api).inbox }
  let(:account) { inbox.account }
  let(:jid) { '15550001234@s.whatsapp.net' }
  let(:agent) { create(:user, account: account, role: :administrator) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, additional_attributes: { whatsapp_jid: jid }) }
  let(:message) do
    reply = build(:message, account: account, inbox: inbox, conversation: conversation, sender: agent,
                            message_type: :outgoing, content: 'Original text', source_id: 'WA-1', status: :delivered)
    Ryze::OutboundDelivery.prepare(reply)
    reply.additional_attributes['ryze_outbound_delivery']['state'] = 'confirmed'
    reply.additional_attributes['ryze_outbound_message_id'] = reply.source_id
    reply.tap(&:save!)
  end
  let(:path) { api_v1_account_conversation_message_path(account.id, conversation.display_id, message.id) }
  let(:audits) { Enterprise::AuditLog.where(auditable: message, action: 'destroy') }

  around do |example|
    with_modified_env(RYZE_INBOX_ID: inbox.id.to_s, RYZE_EDIT_CONVERSATION_ID: conversation.display_id.to_s, RYZE_INSTANCE_NAME: 'pilot',
                      RYZE_PILOT_CHAT_JID: jid, RYZE_EDIT_API_TOKEN: 'test-token', RYZE_WEBHOOK_SECRET: 'test-secret',
                      RYZE_NATIVE_BRIDGE_USER_ID: agent.id.to_s) { example.run }
  end

  it 'records one audit for the agent who removes the local message' do
    colleague = create(:user, account: account, role: :administrator)
    2.times { post "#{path}/delete_only_in_chatwoot", headers: colleague.create_new_auth_token, as: :json }
    expect(audits.sole).to have_attributes(user: colleague, associated: account, remote_address: be_present,
                                           audited_changes: include('content' => 'Original text'))
  end

  it 'records the original author only at confirmation, even when a webhook arrives after the request' do
    stub_request(:get, 'https://ryzeapi.cloud/api/chat/status/pilot').with(query: { messageId: 'WA-1' })
                                                                     .to_return(body: { success: true, message_id: 'WA-1', chat_jid: jid,
                                                                                        direction: 'sent', status: 'delivered' }.to_json)
    stub_request(:delete, 'https://ryzeapi.cloud/api/chat/delete/pilot').to_timeout
    post "#{path}/delete_for_everyone", headers: agent.create_new_auth_token, as: :json
    delete path, headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:conflict)
    expect(audits).to be_empty

    revoke = { type: 'message_revoke', revoke: { revokeType: 'sender_revoke' } }
    event = { event: 'message.exchange', instanceData: { instance: 'pilot' },
              data: { direction: 'outgoing', id: 'WA-1', chat: { jid: jid }, message: revoke } }
    2.times { post '/webhooks/ryze', params: event, headers: { Authorization: 'Bearer test-secret' }, as: :json }
    expect(audits.sole).to have_attributes(user: agent, associated: account, audited_changes: include('content' => 'Original text'))
  end
end
