require 'rails_helper'

RSpec.describe 'WhatsApp group conversation permissions', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:path) { "/api/v1/accounts/#{account.id}/conversations" }

  around do |example|
    with_modified_env(RYZE_GROUPS_INBOX_ENABLED: 'true', RYZE_INBOX_ID: inbox.id.to_s) { example.run }
  end

  before do
    role = create(:custom_role, account: account, permissions: ['conversation_participating_manage'])
    account.account_users.find_by!(user: agent).update!(custom_role: role)
    create(:inbox_member, user: agent, inbox: inbox)
  end

  def create_group(jid)
    contact = create(:contact, account: account, identifier: jid)
    binding = create(:contact_inbox, contact: contact, inbox: inbox, source_id: jid)
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: binding)
  end

  it 'lists and counts only the groups the agent is allowed to open' do
    visible = create_group('120363000000000001@g.us')
    hidden = create_group('120363000000000002@g.us')
    create(:conversation_participant, account: account, user: agent, conversation: visible)

    get path, headers: agent.create_new_auth_token, params: { whatsapp_scope: 'groups' }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('data')).to include(
      'payload' => [include('id' => visible.display_id, 'whatsapp_group' => true)],
      'meta' => include('all_count' => 1)
    )

    get "#{path}/#{hidden.display_id}", headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'keeps hidden groups and their messages out of dashboard search' do
    visible = create_group('120363000000000001@g.us')
    hidden = create_group('120363000000000002@g.us')
    create(:conversation_participant, account: account, user: agent, conversation: visible)
    visible_message = create(:message, account: account, inbox: inbox, conversation: visible, content: 'ticket-alpha')
    create(:message, account: account, inbox: inbox, conversation: hidden, content: 'ticket-alpha')
    search = "/api/v1/accounts/#{account.id}/search"

    get "#{search}/conversations", headers: agent.create_new_auth_token, params: { q: '@g.us' }
    expect(response.parsed_body.dig('payload', 'conversations').pluck('id')).to eq([visible.display_id])

    get "#{search}/messages", headers: agent.create_new_auth_token, params: { q: 'ticket-alpha' }
    expect(response.parsed_body.dig('payload', 'messages').pluck('id')).to eq([visible_message.id])
  end

  context 'with search indexing enabled', if: Message.respond_to?(:search) do
    let(:search_path) { "/api/v1/accounts/#{account.id}/search/messages" }
    let(:fields) { %w[content attachments.transcribed_text content_attributes.email.subject] }

    before do
      account.enable_features!('advanced_search')
      account.disable_features!('search_with_gin')
      allow(ChatwootApp).to receive(:advanced_search_allowed?).and_return(true)
    end

    it 'keeps indexed fields and excludes hidden group IDs for pilot inbox queries' do
      hidden = create_group('120363000000000001@g.us')
      visible = create_group('120363000000000002@g.us')
      create(:conversation_participant, account: account, user: agent, conversation: visible)
      allow(Message).to receive(:search).and_return(Message.none)

      get search_path, headers: agent.create_new_auth_token, params: { q: 'ticket-alpha', inbox_id: inbox.id }

      expect(response).to have_http_status(:ok)
      expect(Message).to have_received(:search).with(
        'ticket-alpha', hash_including(fields: fields, where: hash_including(inbox_id: inbox.id, conversation_id: { not: [hidden.id] }))
      )
    end

    it 'keeps the original indexed query for another authorized inbox' do
      create_group('120363000000000001@g.us')
      other_inbox = create(:inbox, account: account)
      create(:inbox_member, user: agent, inbox: other_inbox)
      allow(Message).to receive(:search).and_return(Message.none)

      get search_path, headers: agent.create_new_auth_token, params: { q: 'ticket-alpha', inbox_id: other_inbox.id }

      expect(response).to have_http_status(:ok)
      expect(Message).to have_received(:search).with(
        'ticket-alpha', hash_including(fields: fields, where: satisfy { |where| where[:inbox_id] == other_inbox.id && !where.key?(:conversation_id) })
      )
    end

    it 'uses permission-scoped SQL when hidden group IDs exceed the indexed query budget' do
      stub_const('Enterprise::SearchService::ADVANCED_SEARCH_GROUP_DENIAL_LIMIT', 1)
      hidden_jids = %w[120363000000000001@g.us 120363000000000002@g.us]
      hidden_jids.each do |jid|
        create(:message, account: account, inbox: inbox, conversation: create_group(jid), content: 'ticket-alpha')
      end
      visible = create_group('120363000000000003@g.us')
      create(:conversation_participant, account: account, user: agent, conversation: visible)
      message = create(:message, account: account, inbox: inbox, conversation: visible, content: 'ticket-alpha')
      allow(Message).to receive(:search).and_return(Message.none)

      get search_path, headers: agent.create_new_auth_token, params: { q: 'ticket-alpha' }

      expect(response.parsed_body.dig('payload', 'messages').pluck('id')).to eq([message.id])
      expect(Message).not_to have_received(:search)
    end
  end
end
