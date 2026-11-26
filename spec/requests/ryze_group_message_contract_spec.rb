require 'rails_helper'

RSpec.describe 'Ryze native bridge group message contract', type: :request do
  let(:account) { create(:account) }
  let(:bridge_url) { 'https://bridge.example.test/chatwoot' }
  let(:inbox) { create(:channel_api, account: account, webhook_url: bridge_url).inbox }
  let(:agent) { create(:user, account: account, role: :administrator) }
  let(:bridge_user) { create(:user, account: account, role: :administrator) }
  let(:group_jid) { '120363000000000001@g.us' }
  let(:other_group_jid) { '120363000000000002@g.us' }
  let(:group) { create_group(group_jid, 'Grupo A') }
  let(:other_group) { create_group(other_group_jid, 'Grupo B') }
  let(:original_id) { 'WA_ORIGINAL_ID' }
  let(:mention_text) { '@15550100201 e @100000000000002@lid, podem confirmar?' }

  before do
    allow(Webhooks::Trigger).to receive(:execute)
  end

  def create_group(jid, name)
    contact = create(:contact, account: account, name: name)
    contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: jid)
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end

  def messages_path(conversation)
    api_v1_account_conversation_messages_path(account.id, conversation.display_id)
  end

  def receive_message(conversation, content:, source_id:, reply_to: nil)
    post messages_path(conversation), as: :json, headers: { api_access_token: bridge_user.access_token.token },
                                      params: { content: content, source_id: source_id, message_type: 'incoming',
                                                content_attributes: { in_reply_to_external_id: reply_to }.compact }
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch('id')
  end

  def send_from_panel(conversation, params)
    perform_enqueued_jobs(only: [EventDispatcherJob, WebhookJob]) do
      post messages_path(conversation), params: params, headers: agent.create_new_auth_token, as: :json
    end
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch('id')
  end

  it 'keeps the bridge-provided author text and resolves an incoming quote within its own group' do
    original = receive_message(group, content: "Participant A\nOriginal", source_id: original_id)
    receive_message(other_group, content: "Participant A\nOther group", source_id: original_id)
    reply = receive_message(group, content: "Participant B\nResposta", source_id: 'WA_REPLY_ID', reply_to: original_id)

    get messages_path(group), headers: agent.create_new_auth_token
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('payload')).to contain_exactly(
      include('id' => original, 'content' => "Participant A\nOriginal", 'sender' => include('id' => group.contact_id)),
      include('id' => reply, 'content' => "Participant B\nResposta", 'sender' => include('id' => group.contact_id),
              'content_attributes' => include('in_reply_to' => original, 'in_reply_to_external_id' => original_id))
    )
  end

  it 'sends literal mention text and the quoted transport ID to the native bridge once' do
    original = receive_message(group, content: "Participant A\nOriginal", source_id: original_id)
    reply = send_from_panel(group, { content: mention_text, content_attributes: { in_reply_to: original } })

    expect(Webhooks::Trigger).to have_received(:execute).with(
      bridge_url,
      hash_including(id: reply, event: 'message_created', private: false, message_type: 'outgoing', content: mention_text,
                     conversation: hash_including(id: group.display_id, contact_inbox: group.contact_inbox),
                     sender: hash_including(id: agent.id),
                     content_attributes: hash_including(in_reply_to: original, in_reply_to_external_id: original_id)),
      :api_inbox_webhook, secret: inbox.channel.secret, delivery_id: a_kind_of(String)
    ).once
  end

  it 'removes a reference to a message in another group' do
    original = receive_message(other_group, content: 'Outro grupo', source_id: original_id)
    send_from_panel(group, { content: 'Resposta', content_attributes: { in_reply_to: original } })

    expect(response.parsed_body.fetch('content_attributes')).to include('in_reply_to' => nil, 'in_reply_to_external_id' => nil)
  end

  it 'marks a note with mention text as private in the API-inbox event' do
    note = send_from_panel(group, { content: mention_text, private: true })

    expect(Webhooks::Trigger).to have_received(:execute).with(
      bridge_url, hash_including(id: note, event: 'message_created', private: true, content: mention_text),
      :api_inbox_webhook, secret: inbox.channel.secret, delivery_id: a_kind_of(String)
    ).once
  end
end
