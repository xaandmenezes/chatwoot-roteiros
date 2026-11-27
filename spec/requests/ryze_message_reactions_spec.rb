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
  let(:echo_id) { 'NATIVE_REACTION_ID' }
  let(:bridge_placeholder) { '💬 Reagiu a uma mensagem' }

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

  def post_echo(content: bridge_placeholder, user: agent, source_id: echo_id)
    post messages_path, params: { content: content, source_id: source_id, external_created_at: 1_795_738_838 },
                        headers: { api_access_token: user.access_token.token }, as: :json
  end

  def provider_snapshot(type: 'reaction', chat: jid, id: echo_id)
    stub_request(:get, 'https://ryzeapi.cloud/api/chat/getMessage/psr-test').with(query: { messageId: echo_id }).to_return(
      body: { success: true, status: 'found', messageId: id, data: { type: type, from: session_jid, to: jid, chat: chat, isGroup: false } }.to_json
    )
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

  it 'treats nil or omitted emoji in incoming and outgoing webhooks as removal' do
    post_event(event(id: 'INCOMING_ADD', emoji: '👍', at: '2026-11-26T18:00:00Z'))
    nil_removal = event(id: 'INCOMING_REMOVE_NIL', emoji: nil, at: '2026-11-26T18:00:01Z')
    post_event(nil_removal)
    expect(response).to have_http_status(:ok)
    expect(history.fetch('ryze_reactions')).to include('incoming' => nil)

    omitted_removal = event(id: 'INCOMING_REMOVE_OMITTED', emoji: '', at: '2026-11-26T18:00:02Z')
    omitted_removal[:data][:message][:reaction].delete(:emoji)
    post_event(omitted_removal)
    expect(response).to have_http_status(:ok)

    outgoing_nil = event(id: 'OUTGOING_REMOVE_NIL', emoji: nil, at: '2026-11-26T18:00:03Z', direction: 'outgoing')
    post_event(outgoing_nil)
    expect(response).to have_http_status(:ok)
    expect(history.fetch('ryze_reactions')).to include('outgoing' => nil)
  end

  it 'rejects invalid non-string or non-emoji webhook values' do
    logs = []
    allow(Rails.logger).to receive(:info) { |message| logs << message }

    [123, 'abc'].each_with_index do |invalid_emoji, index|
      invalid_event = event(id: "INVALID_EMOJI_#{index}", emoji: invalid_emoji, at: '2026-11-26T18:00:00Z')
      post_event(invalid_event)
      expect(response).to have_http_status(:bad_request)
      expect(logs.grep(/reaction rejected/).last).to eq(
        'Ryze pilot reaction rejected field=emoji target_shape=object:id,chat'
      )
    end
  end

  it 'normalizes the two WhatsApp key spellings and a device JID before applying a removal' do
    post_event(event(id: 'OUTGOING_ADD', emoji: '👍', at: '2026-11-26T18:00:00Z', direction: 'outgoing'))
    payload = event(id: 'OUTGOING_REMOVE', emoji: '', at: '2026-11-26T18:00:01Z', direction: 'outgoing')
    payload[:data][:sender][:jid] = session_jid.sub('@', ':4@')
    payload[:data][:message][:reaction][:targetMessageId] = { id: message.source_id, remoteJid: jid }

    post_event(payload)
    expect(response).to have_http_status(:ok)
    expect(history.fetch('ryze_reactions')).to include('outgoing' => nil, 'revision' => 2)

    payload[:data][:message][:reaction][:targetMessageId][:ID] = 'OTHER_TARGET'
    post_event(payload)
    expect(response).to have_http_status(:bad_request)
  end

  it 'accepts the target as a bare message id or with a differently cased provider key' do
    payload = event(id: 'INCOMING_BARE', emoji: '👍', at: '2026-11-26T18:00:00Z')
    payload[:data][:message][:reaction][:targetMessageId] = message.source_id
    post_event(payload)
    expect(response).to have_http_status(:ok)
    expect(history.fetch('ryze_reactions')).to include('incoming' => include('emoji' => '👍'))

    payload = event(id: 'INCOMING_CASED', emoji: '❤️', at: '2026-11-26T18:00:01Z')
    payload[:data][:message][:reaction][:targetMessageId] = { 'Id' => message.source_id, 'RemoteJid' => jid }
    post_event(payload)
    expect(response).to have_http_status(:ok)
    expect(history.fetch('ryze_reactions')).to include('incoming' => include('emoji' => '❤️'))
  end

  it 'accepts a target key that omits the chat' do
    payload = event(id: 'INCOMING_NO_CHAT', emoji: '😂', at: '2026-11-26T18:00:00Z')
    payload[:data][:message][:reaction][:targetMessageId] = { ID: message.source_id }
    post_event(payload)

    expect(response).to have_http_status(:ok)
    expect(history.fetch('ryze_reactions')).to include('incoming' => include('emoji' => '😂'))
  end

  it 'distinguishes an absent target from a provided one that cannot be used' do
    allow(Rails.logger).to receive(:info)

    payload = event(id: 'ABSENT_TARGET', emoji: '👍', at: '2026-11-26T18:00:00Z')
    payload[:data][:message][:reaction].delete(:targetMessageId)
    post_event(payload)
    expect(response).to have_http_status(:bad_request)
    expect(Rails.logger).to have_received(:info).with(
      'Ryze pilot reaction rejected field=target_missing target_shape=absent'
    )

    payload = event(id: 'EMPTY_TARGET', emoji: '👍', at: '2026-11-26T18:00:00Z')
    payload[:data][:message][:reaction][:targetMessageId] = {}
    post_event(payload)
    expect(response).to have_http_status(:bad_request)
    expect(Rails.logger).to have_received(:info).with(
      'Ryze pilot reaction rejected field=target_invalid target_shape=object:empty'
    )
  end

  it 'rejects a provided target that cannot be used instead of treating it as absent' do
    logs = []
    allow(Rails.logger).to receive(:info) { |message| logs << message }

    cases = [
      [{ unexpected: 'value' }, :target_invalid, 'object:unknown=1'],
      [{ chatJid: jid }, :target_id_missing, 'object:chat'],
      [{ ID: '' }, :target_id_invalid, 'object:id'],
      [{ ID: 123 }, :target_id_invalid, 'object:id'],
      [{ ID: message.source_id, id: 'OTHER_TARGET' }, :target_id_invalid, 'object:id'],
      [{ ID: message.source_id, remoteJID: 'not-a-jid' }, :target_chat_invalid, 'object:id,chat'],
      [{ ID: message.source_id, remoteJID: jid, jid: '15550003333@s.whatsapp.net' }, :target_chat_invalid, 'object:id,chat'],
      [%w[not an id], :target_invalid, 'invalid'],
      ['not a provider id', :target_id_invalid, 'bare_id']
    ]

    cases.each_with_index do |(target, field, shape), index|
      payload = event(id: "UNUSABLE_TARGET_#{index}", emoji: '👍', at: '2026-11-26T18:00:00Z')
      payload[:data][:message][:reaction][:targetMessageId] = target
      post_event(payload)

      expect(response).to have_http_status(:bad_request)
      expect(logs.grep(/reaction rejected/).last).to eq(
        "Ryze pilot reaction rejected field=#{field} target_shape=#{shape}"
      )
    end
  end

  it 'accepts a usable target that also carries unknown fields' do
    payload = event(id: 'INCOMING_UNKNOWN_FIELD', emoji: '🤔', at: '2026-11-26T18:00:00Z')
    payload[:data][:message][:reaction][:targetMessageId] = { ID: message.source_id, remoteJID: jid, groupingKey: 'key' }
    post_event(payload)

    expect(response).to have_http_status(:ok)
    expect(history.fetch('ryze_reactions')).to include('incoming' => include('emoji' => '🤔'))
  end

  it 'logs only fixed target categories and the unknown key count' do
    allow(Rails.logger).to receive(:info)
    payload = event(id: 'SHAPELESS_TARGET', emoji: '👍', at: '2026-11-26T18:00:00Z')
    payload[:data][:message][:reaction][:targetMessageId] = {
      ID: message.source_id, id: 'OTHER_TARGET', remoteJID: '15550009999@s.whatsapp.net', custom_field: 'sensitive'
    }
    post_event(payload)

    expect(response).to have_http_status(:bad_request)
    expect(Rails.logger).to have_received(:info).with(
      'Ryze pilot reaction rejected field=target_id_invalid target_shape=object:id,chat,unknown=1'
    )
  end

  it 'ignores an out-of-scope event and rejects an invalid sender' do
    data = event(id: 'REACTION_ONE', emoji: '👍', at: '2026-11-26T18:00:00Z')
    out_of_scope = data.deep_dup
    out_of_scope[:data][:chat][:jid] = '15550003333@s.whatsapp.net'
    post_event(out_of_scope)
    expect(response).to have_http_status(:ok)
    expect(history['ryze_reactions']).to be_nil

    data[:data][:sender][:jid] = '15550003333@s.whatsapp.net'
    post_event(data)
    expect(response).to have_http_status(:bad_request)
    expect(history['ryze_reactions']).to be_nil
  end

  it 'accepts a valid target chat differing from data[:chat] for both @s.whatsapp.net and @lid' do
    differing_jid = event(id: 'DIFFERING_JID', emoji: '👍', at: '2026-11-26T18:00:00Z')
    differing_jid[:data][:message][:reaction][:targetMessageId][:remoteJID] = '15550003333@s.whatsapp.net'
    post_event(differing_jid)
    expect(response).to have_http_status(:ok)
    expect(history.fetch('ryze_reactions')).to include('incoming' => include('emoji' => '👍'))

    differing_lid = event(id: 'DIFFERING_LID', emoji: '😂', at: '2026-11-26T18:00:01Z')
    differing_lid[:data][:chat][:lid] = '123456789012345@lid'
    differing_lid[:data][:message][:reaction][:targetMessageId] = {
      ID: message.source_id, remoteJID: '999999999999999@lid', fromMe: false
    }
    post_event(differing_lid)
    expect(response).to have_http_status(:ok)
    expect(history.fetch('ryze_reactions')).to include('incoming' => include('emoji' => '😂'))
  end

  it 'accepts an @lid target chat when chat.lid is absent or empty' do
    lid = '123456789012345@lid'

    blank_lid = event(id: 'INCOMING_BLANK_LID', emoji: '👍', at: '2026-11-26T18:00:00Z')
    blank_lid[:data][:chat][:lid] = ''
    blank_lid[:data][:message][:reaction][:targetMessageId] = { ID: message.source_id, remoteJID: lid, fromMe: false }
    post_event(blank_lid)
    expect(response).to have_http_status(:ok)
    expect(history.fetch('ryze_reactions')).to include('incoming' => include('emoji' => '👍'))

    absent_lid = event(id: 'OUTGOING_ABSENT_LID', emoji: '❤️', at: '2026-11-26T18:00:01Z', direction: 'outgoing')
    absent_lid[:data][:message][:reaction][:targetMessageId] = { ID: message.source_id, remoteJID: lid.sub('@', ':0@'), fromMe: true }
    post_event(absent_lid)
    expect(response).to have_http_status(:ok)
    expect(history.fetch('ryze_reactions')).to include('outgoing' => include('emoji' => '❤️'))
  end

  it 'rejects a reaction targeting its own event ID' do
    allow(Rails.logger).to receive(:info)
    payload = event(id: 'SELF_TARGET_ID', emoji: '👍', at: '2026-11-26T18:00:00Z')
    payload[:data][:message][:reaction][:targetMessageId] = { ID: 'SELF_TARGET_ID', remoteJID: jid }
    post_event(payload)

    expect(response).to have_http_status(:bad_request)
    expect(Rails.logger).to have_received(:info).with(
      'Ryze pilot reaction rejected field=target_self target_shape=object:id,chat'
    )
    expect(history['ryze_reactions']).to be_nil
  end

  it 'does not mutate messages when the target message belongs to another conversation' do
    other_conv = create(:conversation, account: account, inbox: inbox, additional_attributes: { whatsapp_jid: '15550009999@s.whatsapp.net' })
    other_msg = create(:message, account: account, inbox: inbox, conversation: other_conv,
                                 message_type: :incoming, source_id: 'OTHER_CONV_MSG', content: 'Other conv text')

    payload = event(id: 'CROSS_CONV_REACTION', emoji: '👍', at: '2026-11-26T18:00:00Z')
    payload[:data][:message][:reaction][:targetMessageId] = { ID: other_msg.source_id, remoteJID: jid }
    post_event(payload)

    expect(response).to have_http_status(:service_unavailable)
    expect(other_msg.reload.additional_attributes&.fetch('ryze_reactions', nil)).to be_nil
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

  it 'suppresses a bridge-first reaction before message creation or notifications, including on replay' do
    lookup = provider_snapshot

    expect do
      2.times do
        post_echo
        expect(response).to have_http_status(:no_content)
      end
    end.not_to change(Message, :count)

    expect(lookup).to have_been_requested.once
    expect(ActionCableBroadcastJob).not_to have_been_enqueued.with(anything, 'message.created', anything)
  end

  it 'suppresses a late bridge copy by exact ID after a verified webhook, independent of its text' do
    post_event(event(id: echo_id, emoji: '👍', at: '2026-11-26T18:00:00Z', direction: 'outgoing'))

    expect { post_echo(content: 'Provider copy') }.not_to change(Message, :count)
    expect(response).to have_http_status(:no_content)
  end

  it 'preserves real text that matches the placeholder' do
    provider_snapshot(type: 'text')

    expect { post_echo }.to change(Message, :count).by(1)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('content' => bridge_placeholder, 'source_id' => echo_id)
  end

  it 'does not suppress a copy using an untrusted user token even if its ID is known' do
    outsider = create(:user, account: account, role: :administrator)
    post_event(event(id: echo_id, emoji: '👍', at: '2026-11-26T18:00:00Z', direction: 'outgoing'))

    expect { post_echo(user: outsider) }.to change(Message, :count).by(1)
    expect(response).to have_http_status(:ok)
  end

  it 'keeps an ordinary message when the provider lookup points to a different conversation' do
    provider_snapshot(chat: '15550003333@s.whatsapp.net')

    expect { post_echo }.to change(Message, :count).by(1)
    expect(response).to have_http_status(:ok)
  end

  it 'does not remove an ordinary message with a colliding provider ID' do
    ordinary = create(:message, conversation: conversation, account: account, inbox: inbox, sender: agent, source_id: echo_id)
    payload = event(id: echo_id, emoji: '👍', at: '2026-11-26T18:00:00Z', direction: 'outgoing')

    expect { post_event(payload) }.not_to change(Message, :count)

    expect(response).to have_http_status(:conflict)
    expect(ordinary.reload).to be_persisted
    expect(history['ryze_reactions']).to be_nil
  end

  it 'rejects contradictory webhooks and does not advance the original when an old ID is replayed' do
    data = event(id: echo_id, emoji: '👍', at: '2026-11-26T18:00:00Z', direction: 'outgoing')
    post_event(data)
    post_event(event(id: 'REACTION_REMOVED', emoji: '', at: '2026-11-26T18:00:01Z', direction: 'outgoing'))

    data[:data][:timestamp] = '2026-11-26T18:00:02Z'
    post_event(data)
    expect(response).to have_http_status(:ok)

    data[:data][:message][:reaction][:emoji] = '❤️'
    post_event(data)
    expect(response).to have_http_status(:conflict)

    expect(history.fetch('ryze_reactions')).to include('outgoing' => nil, 'revision' => 2)
  end

  it 'removes a previously stored native echo and restores the last message when the webhook arrives' do
    message
    legacy = create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :outgoing,
                              sender: agent, source_id: echo_id,
                              additional_attributes: { ryze_native_bridge_mirror: true, ryze_reactions: { revision: 2 } })
    payload = event(id: echo_id, emoji: '👍', at: '2026-11-26T18:00:00Z', direction: 'outgoing')

    expect do
      2.times { post_event(payload) }
    end.to have_enqueued_job(ActionCableBroadcastJob).with([agent.pubsub_token], 'message.ryze_reaction_echo_removed',
                                                           hash_including(id: legacy.id, account_id: account.id,
                                                                          last_non_activity_message: hash_including(id: message.id))).once

    expect(Message.exists?(legacy.id)).to be(false)
    expect(conversation.reload.last_activity_at).to eq(message.created_at)
    expect(history.fetch('ryze_reactions')).to include('outgoing' => include('emoji' => '👍'))
  end

  it 'reconciles a legacy echo without a webhook and removes notifications tied to that row only' do
    provider_snapshot
    legacy = create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :outgoing,
                              sender: agent, source_id: echo_id, content: 'Previously mirrored',
                              additional_attributes: { ryze_native_bridge_mirror: true, ryze_reactions: { revision: 2 } })
    old_notification = create(:notification, account: account, user: agent, primary_actor: conversation, secondary_actor: legacy)
    other_notification = create(:notification, account: account, user: agent, primary_actor: conversation, secondary_actor: message)

    mirror = Ryze::ReactionMirror.new(conversation: conversation, provider_id: legacy.source_id)
    expect(mirror.reconcile!).to eq(:recorded)

    expect(Message.exists?(legacy.id)).to be(false)
    expect(Notification.exists?(old_notification.id)).to be(false)
    expect(Notification.exists?(other_notification.id)).to be(true)
    expect(history['ryze_reactions']).to be_nil
    expect(WebMock).not_to have_requested(:post, provider_url)
  end

  it 'applies the original reaction while retaining a native echo that another message references' do
    legacy = create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :outgoing,
                              sender: agent, source_id: echo_id, additional_attributes: { ryze_native_bridge_mirror: true })
    reply = create(:message, account: account, inbox: inbox, conversation: conversation, content_attributes: { in_reply_to: legacy.id })

    post_event(event(id: echo_id, emoji: '👍', at: '2026-11-26T18:00:00Z', direction: 'outgoing'))

    expect(response).to have_http_status(:ok)
    expect(history.fetch('ryze_reactions')).to include('outgoing' => include('emoji' => '👍'))
    expect(legacy.reload).to be_persisted
    expect(reply.reload.in_reply_to).to eq(legacy.id)
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

  it 'confirms an explicit removal receipt whose empty content is absent' do
    provider_accepts(id: 'ADD_ID', emoji: '👍', at: '2026-11-26T18:00:00Z')
    submit_reaction('👍')

    stub_request(:post, provider_url).to_return do |request|
      source = JSON.parse(request.body).fetch('source')
      {
        body: {
          success: true, status: 'sent', message: 'Reaction removed successfully',
          data: {
            messageId: 'REMOVE_ID', direction: 'sent', messageType: 'reaction', source: source, timestamp: '2026-11-26T18:00:01Z',
            chat: { jid: jid, isGroup: false }, sender: { instance: 'psr-test' }, replyTo: { messageId: message.source_id }
          }
        }.to_json
      }
    end

    submit_reaction('')

    expect(response).to have_http_status(:ok)
    expect(history.fetch('ryze_reactions')).to include('pending' => false, 'outgoing' => nil, 'revision' => 4)
  end

  it 'does not clear a pending removal when an explicit receipt with null content names another target' do
    provider_accepts(id: 'ADD_ID', emoji: '👍', at: '2026-11-26T18:00:00Z')
    submit_reaction('👍')

    stub_request(:post, provider_url).to_return do |request|
      source = JSON.parse(request.body).fetch('source')
      {
        body: {
          success: true, status: 'sent', message: 'Reaction removed successfully',
          data: {
            messageId: 'REMOVE_ID', direction: 'sent', messageType: 'reaction', source: source, timestamp: '2026-11-26T18:00:01Z',
            chat: { jid: jid, isGroup: false }, sender: { instance: 'psr-test' }, replyTo: { messageId: 'OTHER_TARGET' }, content: nil
          }
        }.to_json
      }
    end

    submit_reaction('')

    expect(response).to have_http_status(:accepted)
    expect(history.fetch('ryze_reactions')).to include('pending' => true, 'outgoing' => include('emoji' => '👍'), 'revision' => 3)
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
