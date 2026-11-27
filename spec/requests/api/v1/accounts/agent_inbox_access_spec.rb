require 'rails_helper'

RSpec.describe 'Agent inbox access API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:pilot) { create(:inbox, account: account) }
  let(:other_inbox) { create(:inbox, account: account) }
  let(:path) { "/api/v1/accounts/#{account.id}/agents/#{agent.id}/inbox_access" }
  let(:headers) { admin.create_new_auth_token }

  around do |example|
    with_modified_env PSR_RESTRICTED_INBOX_ID: pilot.id.to_s do
      example.run
    end
  end

  def set_access(inbox, level)
    patch path, headers: headers, params: { inbox_id: inbox.id, access_level: level }, as: :json
  end

  it 'lists membership and where supervision is supported for the account administrator' do
    pilot.inbox_members.create!(user: agent)
    other_inbox

    get path, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to contain_exactly(
      a_hash_including('id' => pilot.id, 'access_level' => 'agent', 'supervision_available' => true),
      a_hash_including('id' => other_inbox.id, 'access_level' => 'none', 'supervision_available' => false)
    )
  end

  it 'grants, downgrades and removes membership and broadcasts the committed change' do
    allow(Rails.configuration.dispatcher).to receive(:dispatch).and_call_original

    set_access(pilot, 'supervisor')
    expect(response).to have_http_status(:ok)
    expect(pilot.inbox_members.find_by!(user: agent)).to be_supervisor

    set_access(pilot, 'agent')
    expect(response).to have_http_status(:ok)
    expect(pilot.inbox_members.find_by!(user: agent)).not_to be_supervisor

    set_access(pilot, 'none')
    expect(response).to have_http_status(:ok)
    expect(pilot.inbox_members.find_by(user: agent)).to be_nil
    expect(Rails.configuration.dispatcher).to have_received(:dispatch).with(
      Events::Types::INBOX_MEMBER_ACCESS_CHANGED, kind_of(Time), inbox: pilot, user: agent
    ).exactly(3).times
  end

  it 'records the administrator and the old and new levels' do
    allow(Rails.logger).to receive(:info).and_call_original

    set_access(pilot, 'supervisor')

    expect(Rails.logger).to have_received(:info).with(
      a_string_including('"event":"inbox_member_access_changed"', %("actor_id":#{admin.id}), %("user_id":#{agent.id}),
                         '"previous_level":"none"', '"access_level":"supervisor"', '"occurred_at":')
    )
  end

  it 'keeps ordinary membership available for another inbox and rejects supervision there' do
    set_access(other_inbox, 'agent')
    expect(response).to have_http_status(:ok)
    expect(other_inbox.inbox_members.find_by!(user: agent)).not_to be_supervisor

    set_access(other_inbox, 'supervisor')
    expect(response).to have_http_status(:unprocessable_content)
    expect(other_inbox.inbox_members.find_by!(user: agent)).not_to be_supervisor
  end

  it 'denies a supervisor from editing access, including their own' do
    pilot.inbox_members.create!(user: agent, supervisor: true)

    get path, headers: agent.create_new_auth_token
    expect(response).to have_http_status(:unauthorized)

    patch path, headers: agent.create_new_auth_token, params: { inbox_id: pilot.id, access_level: 'none' }, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(pilot.inbox_members.find_by!(user: agent)).to be_supervisor
  end

  it 'denies an ordinary agent from granting themselves supervision' do
    membership = pilot.inbox_members.create!(user: agent)

    patch path, headers: agent.create_new_auth_token, params: { inbox_id: pilot.id, access_level: 'supervisor' }, as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(membership.reload).not_to be_supervisor
  end

  it 'rejects inboxes and agents outside the account' do
    foreign_inbox = create(:inbox)
    foreign_agent = create(:user, account: foreign_inbox.account)

    set_access(foreign_inbox, 'agent')
    expect(response).to have_http_status(:not_found)

    get "/api/v1/accounts/#{account.id}/agents/#{foreign_agent.id}/inbox_access", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it 'rejects invalid roles without editing membership' do
    set_access(pilot, 'administrator')

    expect(response).to have_http_status(:unprocessable_content)
    expect(pilot.inbox_members.find_by(user: agent)).to be_nil
  end

  it 'keeps the interface inactive when there is no configured pilot in the account' do
    with_modified_env PSR_RESTRICTED_INBOX_ID: nil do
      get path, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to be_empty

      set_access(pilot, 'agent')
      expect(response).to have_http_status(:not_found)
    end
  end
end
