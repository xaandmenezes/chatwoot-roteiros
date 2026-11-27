require 'rails_helper'

RSpec.describe 'Assignment access for the restricted inbox', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:other_agent) { create(:user, account: account, role: :agent) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:outside_agent) { create(:user, account: account, role: :agent) }
  let(:headers) { agent.create_new_auth_token }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: agent) }
  let(:path) { "/api/v1/accounts/#{account.id}/conversations" }

  around do |example|
    with_modified_env(PSR_RESTRICTED_INBOX_ID: inbox.id.to_s, RYZE_GROUPS_INBOX_ENABLED: 'false', RYZE_INBOX_ID: inbox.id.to_s) { example.run }
  end

  before do
    inbox.inbox_members.create!(user: agent)
    inbox.inbox_members.create!(user: other_agent)
  end

  it 'transfers the conversation to another inbox member and removes access even for a former participant' do
    create(:conversation_participant, conversation: conversation, user: agent, account: account)
    expect do
      post "#{path}/#{conversation.display_id}/assignments", params: { assignee_id: other_agent.id }, headers: headers
    end.to have_enqueued_job(Conversations::ActivityMessageJob).with(
      conversation,
      hash_including(content_attributes: {
                       activity: hash_including(actor_id: agent.id, from_assignee_id: agent.id, to_assignee_id: other_agent.id)
                     })
    )
    expect(response).to have_http_status(:ok)

    get "#{path}/#{conversation.display_id}", headers: headers
    expect(response).to have_http_status(:unauthorized)
    get "#{path}/#{conversation.display_id}/messages", headers: other_agent.create_new_auth_token
    expect(response).to have_http_status(:ok)
  end

  it 'checks the current owner under lock when a transfer starts with a stale record' do
    old_record = Conversation.find(conversation.id)
    conversation.update!(assignee: other_agent)

    expect do
      Conversations::AssignmentService.new(conversation: old_record, assignee_id: agent.id, actor: agent).perform
    end.to raise_error(Pundit::NotAuthorizedError)
    expect(conversation.reload.assignee_id).to eq(other_agent.id)
  end

  it 'only lets an inbox bot hand off unassigned conversations to a member of the same inbox' do
    bot = create(:agent_bot, account: account)
    bot_headers = { api_access_token: bot.access_token.token }
    waiting = create(:conversation, account: account, inbox: inbox)
    assignment_path = "#{path}/#{waiting.display_id}/assignments"

    post assignment_path, params: { assignee_id: agent.id }, headers: bot_headers
    expect(response).to have_http_status(:unauthorized)

    create(:agent_bot_inbox, inbox: inbox, agent_bot: bot)
    post assignment_path, params: { assignee_id: outside_agent.id }, headers: bot_headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(waiting.reload.assignee_id).to be_nil

    post assignment_path, params: { assignee_id: agent.id }, headers: bot_headers
    expect(response).to have_http_status(:ok)
    post assignment_path, params: { assignee_id: other_agent.id }, headers: bot_headers
    expect(response).to have_http_status(:unauthorized)
    expect(waiting.reload.assignee_id).to eq(agent.id)
  end

  it 'preserves ownership if the requested recipient does not belong to the inbox' do
    post "#{path}/#{conversation.display_id}/assignments", params: { assignee_id: outside_agent.id }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(conversation.reload.assignee_id).to eq(agent.id)
  end

  it 'authorizes supervisors, administrators and peers in shared groups using the current membership' do
    staff_membership = inbox.inbox_members.find_by!(user: other_agent)
    staff_membership.update!(supervisor: true)
    group_jid = '120363000001@g.us'
    group_contact = create(:contact, account: account, identifier: group_jid)
    binding = create(:contact_inbox, contact: group_contact, inbox: inbox, source_id: group_jid)
    group = create(:conversation, account: account, inbox: inbox, contact: group_contact, contact_inbox: binding)
    staff_headers = other_agent.create_new_auth_token

    get "#{path}/#{conversation.display_id}", headers: staff_headers
    expect(response).to have_http_status(:ok)
    staff_membership.update!(supervisor: false)
    get "#{path}/#{conversation.display_id}", headers: staff_headers
    expect(response).to have_http_status(:unauthorized)

    get "#{path}/#{group.display_id}", headers: staff_headers
    expect(response).to have_http_status(:ok)
    get "#{path}/#{group.display_id}", headers: outside_agent.create_new_auth_token
    expect(response).to have_http_status(:unauthorized)
    get "#{path}/#{conversation.display_id}", headers: admin.create_new_auth_token
    expect(response).to have_http_status(:ok)
  end

  it 'scopes message search and the contact conversation history before returning results' do
    hidden = create(:conversation, account: account, inbox: inbox, contact: conversation.contact,
                                   contact_inbox: conversation.contact_inbox, assignee: other_agent)
    message = create(:message, conversation: conversation, inbox: inbox, account: account, content: 'pilot shared term own')
    create(:message, conversation: hidden, inbox: inbox, account: account, content: 'pilot shared term private')

    get "/api/v1/accounts/#{account.id}/search/messages", params: { q: 'pilot shared term' }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'messages').pluck('id')).to eq([message.id])

    get "/api/v1/accounts/#{account.id}/contacts/#{conversation.contact_id}/conversations", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('payload').pluck('id')).to eq([conversation.display_id])
  end

  it 'scopes unread inbox, team and label counts to visible conversations' do
    account.enable_features!('conversation_unread_counts')
    team = create(:team, account: account, members: [agent, other_agent])
    label = create(:label, account: account, title: 'pilot', show_on_sidebar: true)
    visible = create(:conversation, account: account, inbox: inbox, team: team, assignee: agent, label_list: [label.title])
    hidden = create(:conversation, account: account, inbox: inbox, team: team, assignee: other_agent, label_list: [label.title])
    [visible, hidden].each do |record|
      create(:message, conversation: record, inbox: inbox, account: account, message_type: :incoming, created_at: 1.second.from_now)
    end

    get "#{path}/unread_counts", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'all_count')).to eq(1)
    expect(response.parsed_body.dig('payload', 'inboxes', inbox.id.to_s)).to eq(1)
    expect(response.parsed_body.dig('payload', 'teams', team.id.to_s)).to eq(1)
    expect(response.parsed_body.dig('payload', 'labels', label.id.to_s)).to eq(1)
  end

  it 'requires a signed contact identity even when the legacy public API HMAC setting is off' do
    contact = conversation.contact
    contact.update!(identifier: 'verified-contact')
    public_path = "/public/api/v1/inboxes/#{inbox.channel.identifier}/contacts/#{conversation.contact_inbox.source_id}/conversations"
    get public_path
    expect(response).to have_http_status(:unauthorized)

    signature = OpenSSL::HMAC.hexdigest('sha256', inbox.channel.hmac_token, contact.identifier)
    get public_path, params: { identifier_hash: signature }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.pluck('id')).to include(conversation.display_id)
  end

  it 'binds a public contact signature to the resolved identity during contact creation' do
    contact = conversation.contact
    contact.update!(identifier: 'signed-contact-b', email: 'contact-b@example.test')
    binding = conversation.contact_inbox
    public_path = "/public/api/v1/inboxes/#{inbox.channel.identifier}/contacts"
    identifier = 'signed-contact-a'
    signature = OpenSSL::HMAC.hexdigest('sha256', inbox.channel.hmac_token, identifier)
    signed_params = { identifier: identifier, identifier_hash: signature }

    post public_path, params: signed_params.merge(source_id: binding.source_id)
    expect(response).to have_http_status(:unauthorized)
    expect(binding.reload.hmac_verified).to be(false)

    expect do
      post public_path, params: signed_params.merge(email: contact.email, source_id: 'fresh-binding')
    end.not_to change(inbox.contact_inboxes, :count)
    expect(response).to have_http_status(:unauthorized)

    post public_path, params: signed_params.merge(source_id: 'valid-signed-contact')
    expect(response).to have_http_status(:success)
    created = inbox.contact_inboxes.find_by!(source_id: 'valid-signed-contact')
    expect(created.contact.identifier).to eq(identifier)
    expect(created.hmac_verified).to be(true)
  end

  it 'protects pilot conversations from public API access through a verified contact in another inbox' do
    legacy_channel = create(:channel_api, account: account)
    binding = create(:contact_inbox, inbox: legacy_channel.inbox, contact: conversation.contact, hmac_verified: true)
    public_path = "/public/api/v1/inboxes/#{legacy_channel.identifier}/contacts/#{binding.source_id}/conversations/#{conversation.display_id}"
    get public_path

    expect(response).to have_http_status(:not_found)
  end

  it 'lets an authorized administrator integration create an unassigned inbound conversation and store its message' do
    binding = create(:contact_inbox, inbox: inbox, contact: create(:contact, account: account))
    integration = { api_access_token: admin.access_token.token }
    post path, headers: integration, as: :json, params: { inbox_id: inbox.id, source_id: binding.source_id }
    expect(response).to have_http_status(:success)

    created = account.conversations.find_by!(display_id: response.parsed_body.fetch('id'))
    expect(created.assignee_id).to be_nil
    post "#{path}/#{created.display_id}/messages", headers: integration, as: :json,
                                                   params: { message_type: 'incoming', content: 'bridge receipt', source_id: 'bridge-incoming-test' }
    expect(response).to have_http_status(:success)
    expect(created.messages.incoming.pluck(:content)).to eq(['bridge receipt'])
  end

  it 'filters hidden conversations before calculating pagination counts' do
    conversation
    create(:conversation, account: account, inbox: inbox, assignee: other_agent)
    create(:conversation, account: account, inbox: inbox)

    get path, params: { inbox_id: inbox.id }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('data', 'meta', 'all_count')).to eq(1)
  end
end
