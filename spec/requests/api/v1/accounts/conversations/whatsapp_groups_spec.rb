require 'rails_helper'

RSpec.describe 'WhatsApp group conversation lists', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:group_id) { '120363000000000001@g.us' }
  let(:direct_id) { '5511999999999@s.whatsapp.net' }
  let(:headers) { agent.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/conversations" }

  around do |example|
    with_modified_env(RYZE_GROUPS_INBOX_ENABLED: 'true', RYZE_INBOX_ID: inbox.id.to_s,
                      RYZE_DIRECT_INBOX_ENABLED: 'true') { example.run }
  end

  before { create(:inbox_member, inbox: inbox, user: agent) }

  def create_conversation(source_id, target_inbox: inbox, identifier: source_id, whatsapp_jid: nil, **attributes)
    contact = create(:contact, account: account, identifier: identifier)
    contact_inbox = create(:contact_inbox, inbox: target_inbox, contact: contact, source_id: source_id)
    create(:conversation, account: account, inbox: target_inbox, contact: contact, contact_inbox: contact_inbox,
                          additional_attributes: { 'whatsapp_jid' => whatsapp_jid }.compact, **attributes)
  end

  def list(scope = nil, **params)
    get path, headers: headers, params: { whatsapp_scope: scope, **params }.compact, as: :json
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch('data')
  end

  it 'keeps scopes disjoint and applies them to totals and assignment tabs' do
    group = create_conversation(group_id, assignee: agent, whatsapp_jid: group_id)
    direct = create_conversation(direct_id)
    inconclusive = create_conversation('120363000000000002@g.us', identifier: 'inconclusive', whatsapp_jid: direct_id)

    groups = list('groups', inbox_id: inbox.id, assignee_type: 'me')
    expect(groups.fetch('payload')).to contain_exactly(include('id' => group.display_id, 'whatsapp_group' => true))
    expect(groups.fetch('meta')).to include('all_count' => 1, 'mine_count' => 1, 'unassigned_count' => 0)

    inbox_results = list('inbox')
    expect(inbox_results.fetch('payload')).to contain_exactly(
      include('id' => direct.display_id, 'whatsapp_group' => false),
      include('id' => inconclusive.display_id, 'whatsapp_group' => false)
    )
    expect(inbox_results.fetch('meta')).to include('all_count' => 2, 'mine_count' => 0, 'unassigned_count' => 2)
    expect(list.fetch('payload').pluck('id')).to contain_exactly(group.display_id, direct.display_id, inconclusive.display_id)

    get "#{path}/meta", headers: headers, params: { whatsapp_scope: 'groups', inbox_id: inbox.id }, as: :json
    expect(response.parsed_body.fetch('meta')).to include('all_count' => 1, 'mine_count' => 1, 'unassigned_count' => 0)
  end

  it 'paginates the two scopes independently and recognizes legacy group JIDs' do
    activity_time = 1.hour.ago
    first = create_conversation(group_id, last_activity_at: activity_time)
    second = create_conversation('5511000000000-1592046600@g.us', last_activity_at: activity_time)
    direct = create_conversation(direct_id)

    with_modified_env(CONVERSATION_RESULTS_PER_PAGE: '1') do
      page_one = list('groups', page: 1)
      page_two = list('groups', page: 2)

      expect(page_one.fetch('payload').pluck('id')).to eq([second.display_id])
      expect(page_two.fetch('payload').pluck('id')).to eq([first.display_id])
      expect(list('inbox', page: 1).fetch('payload').pluck('id')).to eq([direct.display_id])
    end
  end

  it 'classifies newly created bridge conversations through their contact binding' do
    contact = create(:contact, account: account, identifier: group_id)
    create(:contact_inbox, inbox: inbox, contact: contact, source_id: group_id)

    post path, params: { inbox_id: inbox.id, contact_id: contact.id, source_id: group_id }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    conversation = account.conversations.find_by!(display_id: response.parsed_body.fetch('id'))
    expect(conversation.additional_attributes).not_to have_key('whatsapp_jid')
    expect(conversation.push_event_data).to include(whatsapp_group: true)

    get "#{path}/#{conversation.display_id}", headers: headers, as: :json
    expect(response.parsed_body).to include('id' => conversation.display_id, 'whatsapp_group' => true)
  end

  it 'refreshes groups and unread counts after correcting a conflicting conversation JID' do
    account.disable_features!('unread_count_for_filters')
    conversation = create_conversation(group_id, whatsapp_jid: direct_id)
    expect(conversation.push_event_data).to include(whatsapp_group: false)
    allow(ActionCableBroadcastJob).to receive(:perform_later)

    conversation.update!(additional_attributes: { 'whatsapp_jid' => group_id })

    expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
      [agent.pubsub_token], Events::Types::CONVERSATION_WHATSAPP_GROUP_CLASSIFICATION_CHANGED, inbox_id: inbox.id, account_id: account.id
    ).once
    expect(list('groups').fetch('payload')).to contain_exactly(include('id' => conversation.display_id, 'whatsapp_group' => true))
  end

  it 'refreshes the inbox when a linked contact identifier changes' do
    group = create_conversation(group_id)
    create(:user, account: account, role: :agent)
    allow(ActionCableBroadcastJob).to receive(:perform_later)

    group.contact.update!(identifier: direct_id)

    expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
      [agent.pubsub_token], Events::Types::CONVERSATION_WHATSAPP_GROUP_CLASSIFICATION_CHANGED, inbox_id: inbox.id, account_id: account.id
    ).once
    expect(list('groups').fetch('payload')).to eq([])
    expect(list('inbox').fetch('payload').pluck('id')).to eq([group.display_id])
  end

  it 'refreshes the inbox when an existing group binding no longer points to the group' do
    group = create_conversation(group_id)
    allow(ActionCableBroadcastJob).to receive(:perform_later)

    group.contact_inbox.update!(source_id: direct_id)

    expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
      [agent.pubsub_token], Events::Types::CONVERSATION_WHATSAPP_GROUP_CLASSIFICATION_CHANGED, inbox_id: inbox.id, account_id: account.id
    ).once
    expect(list('groups').fetch('payload')).to eq([])
    expect(list('inbox').fetch('payload').pluck('id')).to eq([group.display_id])
  end

  it 'combines the group scope with advanced filters and keeps non-pilot boxes visible in the operational queue' do
    open_group = create_conversation(group_id)
    create_conversation('120363000000000002@g.us', status: :resolved)
    other_inbox = create(:channel_api, account: account).inbox
    create(:inbox_member, inbox: other_inbox, user: agent)
    other = create_conversation('120363000000000003@g.us', target_inbox: other_inbox)

    post "#{path}/filter", headers: headers, params: {
      whatsapp_scope: 'groups', payload: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['open'] }]
    }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('payload').pluck('id')).to eq([open_group.display_id])
    expect(response.parsed_body.fetch('meta')).to include('all_count' => 1)
    expect(list('inbox').fetch('payload').pluck('id')).to eq([other.display_id])
  end

  it 'returns an empty scope for a user without access to the inbox' do
    group = create_conversation(group_id)
    outsider = create(:user, account: account, role: :agent)
    get path, headers: outsider.create_new_auth_token, params: { whatsapp_scope: 'groups' }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('data')).to include(
      'payload' => [], 'meta' => include('all_count' => 0)
    )
    get "#{path}/#{group.display_id}", headers: outsider.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'requires inbox membership for group links while retaining team access elsewhere' do
    team_user = create(:user, account: account, role: :agent)
    team = create(:team, account: account)
    create(:team_member, user: team_user, team: team)
    group = create_conversation(group_id, team: team)
    direct = create_conversation(direct_id, team: team)
    team_headers = team_user.create_new_auth_token

    get "#{path}/#{group.display_id}", headers: team_headers, as: :json
    expect(response).to have_http_status(:unauthorized)
    get "#{path}/#{direct.display_id}", headers: team_headers, as: :json
    expect(response).to have_http_status(:ok)

    get "/api/v1/accounts/#{account.id}/search/conversations", headers: team_headers, params: { q: group_id }
    expect(response.parsed_body.dig('payload', 'conversations')).to eq([])

    with_modified_env(RYZE_GROUPS_INBOX_ENABLED: 'false') do
      get "#{path}/#{group.display_id}", headers: team_headers, as: :json
      expect(response).to have_http_status(:ok)
    end
  end

  it 'restores the operational queue when the rollout is disabled' do
    group = create_conversation(group_id)

    with_modified_env(RYZE_GROUPS_INBOX_ENABLED: 'false') do
      expect(list('groups').fetch('payload')).to eq([])
      expect(list('inbox').fetch('payload').pluck('id')).to eq([group.display_id])
    end
  end

  it 'rejects unsupported scope values before querying conversations' do
    get path, headers: headers, params: { whatsapp_scope: 'unsupported' }
    expect(response).to have_http_status(:unprocessable_entity)

    post "#{path}/filter", headers: headers, params: { whatsapp_scope: ['groups'] }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
