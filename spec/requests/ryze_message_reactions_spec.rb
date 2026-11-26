require 'rails_helper'

RSpec.describe 'Ryze message reactions', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:agent) { create(:user, account: account, role: :administrator) }
  let(:jid) { '15550001111@s.whatsapp.net' }
  let(:session_jid) { '15550002222@s.whatsapp.net' }
  let(:conversation) { create(:conversation, inbox: inbox, account: account, additional_attributes: { whatsapp_jid: jid }) }
  let(:message) do
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: conversation.contact,
                     message_type: :incoming, source_id: 'ORIGINAL_ID', content: 'Original text')
  end
  let(:messages_path) { api_v1_account_conversation_messages_path(account.id, conversation.display_id) }
  let(:provider_url) { 'https://ryzeapi.cloud/api/message/reaction/psr-test' }

  around do |example|
    with_modified_env(RYZE_REACTIONS_ENABLED: 'true', RYZE_INBOX_ID: inbox.id.to_s, RYZE_INSTANCE_NAME: 'psr-test',
                      RYZE_PILOT_CHAT_JID: jid, RYZE_EDIT_CONVERSATION_ID: conversation.display_id.to_s,
                      RYZE_EDIT_API_TOKEN: 'test-api-token', RYZE_WEBHOOK_SECRET: 'test-webhook-secret',
                      RYZE_NATIVE_BRIDGE_USER_ID: agent.id.to_s) { example.run }
  end

  def submit_reaction(emoji, target: message, user: agent)
    post "#{messages_path}/#{target.id}/reaction", params: { emoji: emoji }, headers: user.create_new_auth_token, as: :json
  end

  def history
    get messages_path, headers: agent.create_new_auth_token
    response.parsed_body.fetch('payload').find { |entry| entry['id'] == message.id }
  end

  def post_event(payload, bearer: 'test-webhook-secret')
    post '/webhooks/ryze', params: payload, headers: { 'Authorization' => "Bearer #{bearer}" }, as: :json
  end

  # Synthetic webhook derived from Ryze's event catalog and whatsmeow's MessageKey schema.
  def event(id:, emoji:, at:, direction: 'incoming', source: '')
    {
      event: 'message.exchange',
      instanceData: { instance: 'psr-test' },
      data: {
        id: id, direction: direction, timestamp: at,
        chat: { jid: jid, type: 'private' },
        sender: { jid: direction == 'incoming' ? jid : session_jid, name: 'Reaction author' },
        message: { type: 'reaction', source: source, reaction: { emoji: emoji, targetMessageId: { ID: message.source_id, remoteJID: jid } } }
      }
    }
  end

  # Synthetic success response following the public Ryze reaction endpoint example.
  def provider_accepts(id:, emoji:, at:, from_me: false, &before_response)
    stub_request(:post, provider_url).with(
      headers: { 'token' => 'test-api-token' },
      body: hash_including('number' => jid, 'messageId' => message.source_id, 'reaction' => emoji.presence || 'remove', 'fromMe' => from_me)
    ).to_return do |request|
      source = JSON.parse(request.body).fetch('source')
      before_response&.call(source)
      {
        status: 200,
        body: {
          success: true, status: 'sent',
          data: {
            messageId: id, direction: 'sent', messageType: 'reaction', content: emoji, source: source, timestamp: at,
            chat: { jid: jid, isGroup: false }, sender: { jid: session_jid, instance: 'psr-test' }, replyTo: { messageId: message.source_id }
          }
        }.to_json
      }
    end
  end

  it 'keeps one reaction per side on the original and treats an empty emoji as removal' do
    older = event(id: 'INCOMING_ONE', emoji: '👍', at: '2026-11-26T18:00:00Z')
    external = event(id: 'OUTGOING_ONE', emoji: '👍', at: '2026-11-26T18:00:01Z', direction: 'outgoing')
    removal = event(id: 'INCOMING_REMOVE', emoji: '', at: '2026-11-26T18:00:02Z')

    expect { [older, external, older].each { |payload| post_event(payload) } }.not_to change(Message, :count)
    initial = history.fetch('ryze_reactions')
    expect(initial).to include('incoming' => include('emoji' => '👍', 'author' => 'Reaction author'), 'outgoing' => include('emoji' => '👍'))

    [removal, older, removal].each { |payload| post_event(payload) }
    expect(history).to include('content' => 'Original text', 'ryze_reactions' => include('incoming' => nil, 'outgoing' => include('emoji' => '👍')))
  end

  it 'keeps a removal received before the corresponding addition' do
    post_event(event(id: 'REMOVAL', emoji: '', at: '2026-11-26T18:00:02Z'))
    post_event(event(id: 'ADDITION', emoji: '❤️', at: '2026-11-26T18:00:00Z'))

    expect(history.fetch('ryze_reactions')).to include('incoming' => nil)
  end

  it 'ignores an event for a different chat and rejects a mismatched target key and sender' do
    data = event(id: 'REACTION_ONE', emoji: '👍', at: '2026-11-26T18:00:00Z')
    out_of_scope = data.deep_dup
    out_of_scope[:data][:chat][:jid] = '15550003333@s.whatsapp.net'
    post_event(out_of_scope)
    expect(response).to have_http_status(:ok)

    data[:data][:message][:reaction][:targetMessageId][:remoteJID] = '15550003333@s.whatsapp.net'
    post_event(data)
    expect(response).to have_http_status(:bad_request)

    data[:data][:message][:reaction][:targetMessageId][:remoteJID] = jid
    data[:data][:sender][:jid] = '15550003333@s.whatsapp.net'
    post_event(data)
    expect(response).to have_http_status(:bad_request)
    expect(history['ryze_reactions']).to be_nil
  end

  it 'rejects missing identifiers and preserves a generic bridge message' do
    generic = create(:message, account: account, inbox: inbox, conversation: conversation, content: '💬 Reagiu a uma mensagem')
    payload = event(id: 'REACTION_ONE', emoji: '👍', at: '2026-11-26T18:00:00Z')
    payload[:data][:message][:reaction].delete(:targetMessageId)
    post_event(payload)

    expect(response).to have_http_status(:bad_request)
    expect(generic.reload.content).to eq('💬 Reagiu a uma mensagem')
    expect(history['ryze_reactions']).to be_nil
  end

  it 'requests retry when the original has not reached the pilot inbox and rejects ambiguity' do
    payload = event(id: 'REACTION_ONE', emoji: '👍', at: '2026-11-26T18:00:00Z')
    wrong_inbox = create(:channel_api, account: account).inbox
    wrong_conversation = create(:conversation, inbox: wrong_inbox, account: account, additional_attributes: { whatsapp_jid: jid })
    create(:message, source_id: message.source_id, conversation: wrong_conversation, account: account, inbox: wrong_inbox, message_type: :incoming)
    message.destroy!

    post_event(payload)
    expect(response).to have_http_status(:service_unavailable)

    create_list(:message, 2, source_id: message.source_id, conversation: conversation, account: account, inbox: inbox, message_type: :incoming)
    post_event(payload)
    expect(response).to have_http_status(:conflict)
  end

  it 'disables reactions when another original with the same provider ID is outside the history page' do
    duplicate = create(:message, account: account, inbox: inbox, conversation: conversation, sender: conversation.contact,
                                 message_type: :incoming, source_id: message.source_id)
    get messages_path, params: { after: duplicate.id, before: duplicate.id + 1 }, headers: agent.create_new_auth_token

    expect(response.parsed_body.fetch('payload')).to contain_exactly(include('id' => duplicate.id, 'can_react' => false))
    expect(message.agent_view_data({})).to include(can_react: false)
    submit_reaction('👍', target: duplicate)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it 'sends a single command for each desired state and displays the agent who sent it' do
    addition = provider_accepts(id: 'ADD_ID', emoji: '👍', at: '2026-11-26T18:00:00Z')
    submit_reaction('👍')

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('ryze_reactions')).to include('outgoing' => { 'emoji' => '👍', 'author' => agent.name })
    submit_reaction('👍')
    expect(response).to have_http_status(:ok)

    removal = provider_accepts(id: 'REMOVE_ID', emoji: '', at: '2026-11-26T18:00:01Z')
    submit_reaction('')
    expect(response).to have_http_status(:ok)
    expect(history.fetch('ryze_reactions')).to include('outgoing' => nil)
    expect(addition).to have_been_requested.once
    expect(removal).to have_been_requested.once
  end

  it 'can react to a verified message sent by the connected account' do
    message.update!(
      sender: agent, message_type: :outgoing, additional_attributes: { ryze_outbound_message_id: message.source_id }
    )
    request = provider_accepts(id: 'OWN_ADD', emoji: '👍', at: '2026-11-26T18:00:00Z', from_me: true)
    submit_reaction('👍')

    expect(response).to have_http_status(:ok)
    expect(request).to have_been_requested.once
  end

  it 'does not resend a command whose transport timed out and reconciles a matching event' do
    captured_source = nil
    request = stub_request(:post, provider_url).with do |incoming|
      captured_source = JSON.parse(incoming.body).fetch('source')
      true
    end.to_raise(Ryze::Client::ConnectionError)
    submit_reaction('👍')
    expect(response).to have_http_status(:accepted)
    submit_reaction('👍')
    expect(response).to have_http_status(:accepted)
    expect(request).to have_been_requested.once

    post_event(event(id: 'OUTGOING_LATE', emoji: '👍', at: '2026-11-26T18:00:01Z', direction: 'outgoing', source: captured_source))
    expect(history.fetch('ryze_reactions')).to include('outgoing' => include('emoji' => '👍', 'author' => agent.name))
  end

  it 'applies a matching webhook that arrives during the POST only once' do
    provider_accepts(id: 'RACE_ID', emoji: '👍', at: '2026-11-26T18:00:00Z') do |source|
      data = event(id: 'RACE_ID', emoji: '👍', at: '2026-11-26T18:00:00Z', direction: 'outgoing', source: source).fetch(:data)
      reaction = Ryze::ReactionEvent.new(ActionController::Parameters.new(data))
      Ryze::ReactionWebhook.new(inbox: inbox, event: reaction).perform
    end

    submit_reaction('👍')
    expect(response).to have_http_status(:ok)
    expect(history.fetch('ryze_reactions')).to include('revision' => 2, 'outgoing' => include('author' => agent.name))
  end

  it 'keeps an ambiguous response pending when the remote target cannot be verified' do
    request = stub_request(:post, provider_url).to_return(body: { success: true, data: { replyTo: { messageId: 'SOME_OTHER_ID' } } }.to_json)
    submit_reaction('👍')
    expect(response).to have_http_status(:accepted)
    submit_reaction('❤️')
    expect(response.parsed_body.fetch('ryze_reactions')).to include('pending' => true, 'outgoing' => nil)
    expect(request).to have_been_requested.once
  end

  it 'releases a definitively rejected command for a later retry' do
    stub_request(:post, provider_url).to_return(status: 400)
    submit_reaction('👍')
    expect(response).to have_http_status(:bad_gateway)
    expect(history.fetch('ryze_reactions')).to include('pending' => false, 'outgoing' => nil)

    request = provider_accepts(id: 'ADD_ID', emoji: '❤️', at: '2026-11-26T18:00:00Z')
    submit_reaction('❤️')
    expect(response).to have_http_status(:ok)
    expect(request).to have_been_requested.once
  end

  it 'does not expose reaction state to contact or bridge message payloads' do
    post_event(event(id: 'ADD_ID', emoji: '👍', at: '2026-11-26T18:00:00Z'))
    expect(history.fetch('ryze_reactions')).to include('incoming' => include('emoji' => '👍'))
    expect(message.reload.webhook_data[:additional_attributes]).not_to have_key('ryze_reactions')
    expect(message.widget_push_event_data[:additional_attributes]).not_to have_key('ryze_reactions')
  end

  it 'broadcasts a replayed reaction only once to authorized agents' do
    payload = event(id: 'ADD_ID', emoji: '👍', at: '2026-11-26T18:00:00Z')
    update = hash_including(id: message.id, conversation_id: conversation.display_id,
                            ryze_reactions: hash_including(revision: 1, incoming: { 'emoji' => '👍', 'author' => 'Reaction author' }))
    expect do
      2.times { post_event(payload) }
    end.to have_enqueued_job(ActionCableBroadcastJob).with([agent.pubsub_token], 'message.ryze_reactions_changed', update).once
  end

  it 'does not process reactions when the pilot feature is off or the request has no valid signature' do
    payload = event(id: 'ADD_ID', emoji: '👍', at: '2026-11-26T18:00:00Z')

    post_event(payload, bearer: 'wrong')
    expect(response).to have_http_status(:unauthorized)

    with_modified_env(RYZE_REACTIONS_ENABLED: 'false') do
      post_event(payload)
      expect(response).to have_http_status(:ok)
      submit_reaction('👍')
      expect(response).to have_http_status(:unprocessable_entity)
    end
    expect(history).not_to have_key('ryze_reactions')
    expect(WebMock).not_to have_requested(:post, provider_url)
  end

  it 'does not send reactions for notes, invalid emoji or agents without conversation access' do
    outsider = create(:user, account: account, role: :agent)
    submit_reaction('👍', user: outsider)
    expect(response).to have_http_status(:unauthorized)

    submit_reaction('plain text')
    expect(response).to have_http_status(:unprocessable_entity)
    message.update!(private: true)
    submit_reaction('👍')
    expect(response).to have_http_status(:unprocessable_entity)
    expect(WebMock).not_to have_requested(:post, provider_url)
  end

  it 'does not send when multiple messages have the same provider ID in the conversation' do
    create(:message, source_id: message.source_id, conversation: conversation, account: account, inbox: inbox, message_type: :incoming)
    submit_reaction('👍')

    expect(response).to have_http_status(:unprocessable_content)
    expect(WebMock).not_to have_requested(:post, provider_url)
  end
end
