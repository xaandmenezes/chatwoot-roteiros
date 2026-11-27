require 'rails_helper'

RSpec.describe 'Ryze direct inbox rollout', type: :request do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:bridge_user) { create(:user) }
  let(:agent) do
    create(:user).tap do |user|
      create(:account_user, account: account, user: user, role: :agent)
      create(:inbox_member, inbox: inbox, user: user)
    end
  end
  let(:pilot_jid) { '5511999990001@s.whatsapp.net' }
  let(:other_jid) { '5511999990002@s.whatsapp.net' }
  let(:group_jid) { '120363000000000001@g.us' }
  let!(:pilot_conversation) { create(:conversation, inbox: inbox, account: account, additional_attributes: { whatsapp_jid: pilot_jid }) }
  let!(:other_conversation) { create(:conversation, inbox: inbox, account: account, additional_attributes: { whatsapp_jid: other_jid }) }
  let!(:group_conversation) { create(:conversation, inbox: inbox, account: account, additional_attributes: { whatsapp_jid: group_jid }) }
  let(:base_env) do
    {
      RYZE_DIRECT_INBOX_ENABLED: 'true',
      RYZE_WEBHOOK_SECRET: 'direct-secret',
      RYZE_INSTANCE_NAME: 'PSR-Direct',
      RYZE_INBOX_ID: inbox.id.to_s,
      RYZE_EDIT_API_TOKEN: 'direct-token',
      RYZE_NATIVE_BRIDGE_USER_ID: bridge_user.id.to_s,
      RYZE_REACTIONS_ENABLED: 'true',
      RYZE_OUTBOUND_PRESENCE_ENABLED: 'true',
      RYZE_PROFILE_AVATAR_SYNC: 'true',
      RYZE_PILOT_CHAT_JID: pilot_jid,
      RYZE_EDIT_CONVERSATION_ID: pilot_conversation.display_id.to_s
    }
  end

  around do |example|
    create(:account_user, account: account, user: bridge_user, role: :administrator)
    create(:inbox_member, inbox: inbox, user: bridge_user)
    with_modified_env(**base_env) { example.run }
  end

  it 'excludes group conversations from direct inbox features' do
    get api_v1_account_conversation_path(account.id, other_conversation.display_id), headers: agent.create_new_auth_token
    expect(response.parsed_body['ryze_presence_enabled']).to be(true)

    get api_v1_account_conversation_path(account.id, group_conversation.display_id), headers: agent.create_new_auth_token
    expect(response.parsed_body['ryze_presence_enabled']).to be(false)

    group_msg = create(:message, account: account, inbox: inbox, conversation: group_conversation, sender: agent,
                                 message_type: :outgoing, content: 'Msg grupo')
    expect(Ryze::OutboundDelivery.direct?(group_msg)).to be(false)
  end

  def deliver_direct_message(content = 'Olá cliente')
    send_stub = stub_request(:post, 'https://ryzeapi.cloud/api/message/text/PSR-Direct')
                .with(body: hash_including('number' => other_jid, 'message' => content))
                .to_return(
                  status: 200,
                  body: lambda { |req|
                    src = JSON.parse(req.body)['source']
                    {
                      success: true, status: 'sent',
                      data: { direction: 'outgoing', messageType: 'text', messageId: 'WA-DIRECT-1',
                              source: src, content: content, chat: { jid: other_jid } }
                    }.to_json
                  }
                )
    perform_enqueued_jobs(only: [EventDispatcherJob, Ryze::DeliverOutboundMessageJob]) do
      post api_v1_account_conversation_messages_path(account.id, other_conversation.display_id),
           as: :json, headers: agent.create_new_auth_token, params: { content: content }
    end
    [send_stub, other_conversation.messages.last]
  end

  it 'delivers, edits, and deletes messages for any direct conversation' do
    send_stub, message = deliver_direct_message
    expect(response).to have_http_status(:ok)
    expect(send_stub).to have_been_requested.once

    stub_request(:get, 'https://ryzeapi.cloud/api/chat/status/PSR-Direct')
      .with(query: { messageId: 'WA-DIRECT-1' })
      .to_return(body: { success: true, message_id: 'WA-DIRECT-1', chat_jid: other_jid, direction: 'sent', status: 'delivered' }.to_json)
    stub_request(:get, 'https://ryzeapi.cloud/api/chat/getMessage/PSR-Direct')
      .with(query: { messageId: 'WA-DIRECT-1' })
      .to_return(body: { success: true, messageId: 'WA-DIRECT-1', data: { type: 'text', content: 'Olá cliente' } }.to_json)
    stub_request(:post, 'https://ryzeapi.cloud/api/chat/edit/PSR-Direct')
      .with(body: { messageId: 'WA-DIRECT-1', content: 'Olá corrigido' })
      .to_return(body: { success: true }.to_json)

    post edit_content_api_v1_account_conversation_message_path(account.id, other_conversation.display_id, message.id),
         as: :json, headers: agent.create_new_auth_token, params: { content: 'Olá corrigido' }
    expect(response).to have_http_status(:accepted)

    edit_ts = 1.second.from_now.utc.iso8601(6)
    post '/webhooks/ryze',
         params: {
           event: 'message.exchange', instanceData: { instance: 'PSR-Direct' },
           data: {
             id: 'WA-DIRECT-1', direction: 'outgoing', timestamp: edit_ts,
             chat: { jid: other_jid, type: 'private' },
             message: {
               type: 'message_edit', content: 'Olá corrigido', isEdit: true,
               edit: { timestamp: edit_ts, attribute: 'message_edit' }
             }
           }
         },
         as: :json, headers: { 'Authorization' => 'Bearer direct-secret' }
    expect(message.reload.content).to eq('Olá corrigido')

    stub_request(:delete, 'https://ryzeapi.cloud/api/chat/delete/PSR-Direct')
      .with(body: { messageId: 'WA-DIRECT-1', deleteForEveryone: true })
      .to_return(body: { success: true, message_id: 'WA-DIRECT-1', chat_jid: other_jid, delete_type: 'revoke',
                         deleted_for_everyone: true }.to_json)

    post delete_for_everyone_api_v1_account_conversation_message_path(account.id, other_conversation.display_id, message.id),
         as: :json, headers: agent.create_new_auth_token
    expect(response).to have_http_status(:ok)
    expect(message.reload.deleted).to be(true)
  end

  it 'routes incoming and outgoing reactions to the matching direct conversation and ignores unknown chats' do
    target = create(:message, account: account, inbox: inbox, conversation: other_conversation, sender: other_conversation.contact,
                              message_type: :incoming, source_id: 'WA-RX-1', content: 'Oi')

    post '/webhooks/ryze',
         params: {
           event: 'message.exchange', instanceData: { instance: 'PSR-Direct' },
           data: {
             id: 'RX-IN-1', direction: 'incoming', timestamp: '2026-11-27T12:00:00Z',
             chat: { jid: other_jid, type: 'private' }, sender: { jid: other_jid, name: 'Cliente' },
             message: { type: 'reaction', reaction: { targetMessageId: 'WA-RX-1', emoji: '👍' } }
           }
         },
         as: :json, headers: { 'Authorization' => 'Bearer direct-secret' }

    expect(response).to have_http_status(:ok)
    expect(target.reload.additional_attributes.dig('ryze_reactions', 'incoming', 'emoji')).to eq('👍')

    react_stub = stub_request(:post, 'https://ryzeapi.cloud/api/message/reaction/PSR-Direct')
                 .with(body: hash_including('number' => other_jid, 'messageId' => 'WA-RX-1', 'reaction' => '❤️'))
                 .to_return(
                   body: lambda { |req|
                     src = JSON.parse(req.body)['source']
                     {
                       success: true, status: 'sent',
                       data: {
                         direction: 'sent', messageType: 'reaction', messageId: 'RX-OUT-1', source: src, content: '❤️',
                         timestamp: '2026-11-27T12:01:00Z', chat: { jid: other_jid, isGroup: false },
                         sender: { instance: 'PSR-Direct' }, replyTo: { messageId: 'WA-RX-1' }
                       }
                     }.to_json
                   }
                 )

    post "/api/v1/accounts/#{account.id}/conversations/#{other_conversation.display_id}/messages/#{target.id}/reaction",
         params: { emoji: '❤️' }, as: :json, headers: agent.create_new_auth_token

    expect(response).to have_http_status(:ok)
    expect(react_stub).to have_been_requested.once
    expect(target.reload.additional_attributes.dig('ryze_reactions', 'outgoing', 'emoji')).to eq('❤️')

    post '/webhooks/ryze',
         params: {
           event: 'message.exchange', instanceData: { instance: 'PSR-Direct' },
           data: {
             id: 'RX-UNKNOWN', direction: 'incoming', timestamp: '2026-11-27T12:02:00Z',
             chat: { jid: '5511888887777@s.whatsapp.net', type: 'private' },
             sender: { jid: '5511888887777@s.whatsapp.net', name: 'Desconhecido' },
             message: { type: 'reaction', reaction: { targetMessageId: 'WA-NOPE', emoji: '👍' } }
           }
         },
         as: :json, headers: { 'Authorization' => 'Bearer direct-secret' }

    expect(response).to have_http_status(:ok)
  end

  it 'isolates outbound presence state and syncs profile avatar per direct conversation' do
    p1 = stub_request(:post, 'https://ryzeapi.cloud/api/chat/presence/PSR-Direct')
         .with(body: { number: pilot_jid, state: 'typing' }).to_return(body: { success: true }.to_json)
    p2 = stub_request(:post, 'https://ryzeapi.cloud/api/chat/presence/PSR-Direct')
         .with(body: { number: other_jid, state: 'recording' }).to_return(body: { success: true }.to_json)

    post api_v1_account_conversation_ryze_presence_path(account.id, pilot_conversation.display_id),
         as: :json, headers: agent.create_new_auth_token, params: { state: 'typing', composer_id: 'abcdef123456' }
    post api_v1_account_conversation_ryze_presence_path(account.id, other_conversation.display_id),
         as: :json, headers: agent.create_new_auth_token, params: { state: 'recording', composer_id: 'abcdef123456' }

    perform_enqueued_jobs(only: Ryze::DispatchPresenceJob, at: Time.current)
    expect(p1).to have_been_requested.once
    expect(p2).to have_been_requested.once

    avatar_body = File.binread(Rails.root.join('spec/assets/avatar.png'))
    avatar_url = 'https://pps.whatsapp.net/direct-avatar.png?sig=1'
    allow(Resolv).to receive(:getaddresses).and_call_original
    allow(Resolv).to receive(:getaddresses).with('pps.whatsapp.net').and_return(['93.184.216.34'])
    profile_req = stub_request(:get, 'https://ryzeapi.cloud/api/profile/getAccount/PSR-Direct')
                  .with(query: { number: '5511999990002' }, headers: { 'token' => 'direct-token' })
                  .to_return(body: { success: true, profile: { profilePicture: avatar_url } }.to_json)
    stub_request(:get, avatar_url).to_return(body: avatar_body, headers: { 'Content-Type' => 'image/png' })

    perform_enqueued_jobs(only: Ryze::SyncProfileAvatarJob) do
      post '/webhooks/ryze',
           params: {
             event: 'message.exchange', instanceData: { instance: 'PSR-Direct' },
             data: { id: 'WA-AV-1', direction: 'incoming', chat: { jid: other_jid, type: 'private' }, message: { type: 'text', content: 'Oi' } }
           },
           as: :json, headers: { 'Authorization' => 'Bearer direct-secret' }
    end

    expect(profile_req).to have_been_requested.once
    expect(other_conversation.contact.reload.avatar).to be_attached
  ensure
    Redis::Alfred.delete("RYZE_PROFILE_AVATAR:#{inbox.id}:#{other_conversation.display_id}")
  end

  it 'reverts immediately to pilot-only mode when RYZE_DIRECT_INBOX_ENABLED is turned off' do
    with_modified_env(RYZE_DIRECT_INBOX_ENABLED: 'false') do
      expect(Ryze::OutgoingEditEligibility.pilot_conversation?(pilot_conversation)).to be(true)
      expect(Ryze::OutgoingEditEligibility.pilot_conversation?(other_conversation)).to be(false)
      expect(Ryze::Presence.enabled?(other_conversation)).to be(false)
    end
  end
end
