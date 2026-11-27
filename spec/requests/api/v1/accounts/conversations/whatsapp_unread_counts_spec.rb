require 'rails_helper'

RSpec.describe 'WhatsApp group unread counts' do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_api, account: account)) }
  let(:label) { create(:label, account: account, show_on_sidebar: true) }
  let(:team) { create(:team, account: account, allow_auto_assign: false) }
  let(:url) { "/api/v1/accounts/#{account.id}/conversations/unread_counts" }
  let(:headers) { agent.create_new_auth_token }
  let(:group_jid) { '120363123456789012@g.us' }

  before do
    account.enable_features!(:conversation_unread_counts)
    create(:inbox_member, user: agent, inbox: inbox)
    create(:team_member, user: agent, team: team)
  end

  after do
    Conversations::UnreadCounts::Store.clear_account!(account.id)
  end

  around do |example|
    with_modified_env(RYZE_GROUPS_INBOX_ENABLED: 'true', RYZE_INBOX_ID: inbox.id.to_s) { example.run }
  end

  def create_unread_group(jid = group_jid)
    conversation = create_unread_conversation(account: account, inbox: inbox, labels: [label.title], team: team)
    conversation.contact.update!(identifier: jid)
    conversation.contact_inbox.update!(source_id: jid)
    conversation.update!(additional_attributes: { 'whatsapp_jid' => jid })
    conversation
  end

  it 'splits the main counts, preserves transverse counts and keeps the legacy response' do
    group = create_unread_group
    create(:message, account: account, inbox: inbox, conversation: group, message_type: :incoming)
    create_unread_conversation(account: account, inbox: inbox)

    get url, headers: headers, as: :json
    expect(response.parsed_body['payload']).to eq(
      'all_count' => 2, 'inboxes' => { inbox.id.to_s => 2 },
      'labels' => { label.id.to_s => 1 }, 'teams' => { team.id.to_s => 1 }
    )

    get "#{url}?whatsapp_scope=inbox", headers: headers, as: :json
    expect(response.parsed_body['payload']).to eq(
      'all_count' => 1, 'inboxes' => { inbox.id.to_s => 1 }, 'whatsapp_groups_count' => 1,
      'labels' => { label.id.to_s => 1 }, 'teams' => { team.id.to_s => 1 }
    )

    with_modified_env(RYZE_GROUPS_INBOX_ENABLED: 'false') do
      get "#{url}?whatsapp_scope=inbox", headers: headers, as: :json
      expect(response.parsed_body['payload']).to include('all_count' => 2, 'whatsapp_groups_count' => 0)
    end

    post "/api/v1/accounts/#{account.id}/conversations/#{group.display_id}/update_last_seen", headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    get "#{url}?whatsapp_scope=inbox", headers: headers, as: :json
    expect(response.parsed_body['payload']).to include('all_count' => 1, 'whatsapp_groups_count' => 0)
  end

  it 'retains counts across accessible inboxes when only a group is unread in the separated inbox' do
    create_unread_group
    other_inbox = create(:inbox, account: account)
    create(:inbox_member, inbox: other_inbox, user: agent)
    create_unread_conversation(account: account, inbox: other_inbox)

    get "#{url}?whatsapp_scope=inbox", headers: headers, as: :json

    expect(response.parsed_body['payload']).to include(
      'all_count' => 1, 'inboxes' => { other_inbox.id.to_s => 1 }, 'whatsapp_groups_count' => 1
    )
  end

  it 'does not expose groups in an inbox the agent cannot access' do
    create_unread_group
    inbox.inbox_members.find_by!(user: agent).destroy!

    get "#{url}?whatsapp_scope=inbox", headers: headers, as: :json

    expect(response.parsed_body['payload']).to include('all_count' => 0, 'inboxes' => {}, 'whatsapp_groups_count' => 0)
  end
end
