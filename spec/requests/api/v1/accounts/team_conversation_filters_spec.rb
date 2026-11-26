require 'rails_helper'

RSpec.describe 'Team conversation filters', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, :administrator, account: account) }
  let(:agent) { create(:user, account: account) }
  let(:colleague) { create(:user, account: account) }
  let(:path) { "/api/v1/accounts/#{account.id}/custom_filters" }
  let(:query) do
    { payload: [{ attribute_key: 'booking', custom_attribute_type: 'conversation_attribute', filter_operator: 'is_not_present', values: [] }] }
  end
  let(:attributes) { { name: 'Missing booking', filter_type: 0, query: query } }

  def create_folder(actor, **options)
    post path, params: attributes.merge(options), headers: actor.create_new_auth_token, as: :json
    expect(response).to have_http_status(:success)
    response.parsed_body
  end

  it 'shares only team conversation filters, alongside each member’s own folders' do
    team = create_folder(admin, visibility: 'team')
    mine = create_folder(agent)
    create_folder(colleague)
    segment = create_folder(agent, filter_type: 1)

    expect(team['visibility']).to eq('team')
    expect(mine['visibility']).to eq('personal')
    get path, headers: agent.create_new_auth_token
    expect(response.parsed_body.pluck('id')).to contain_exactly(team['id'], mine['id'])
    get path, params: { filter_type: 'contact' }, headers: agent.create_new_auth_token
    expect(response.parsed_body.pluck('id')).to contain_exactly(segment['id'])

    [admin, colleague].each do |actor|
      get "#{path}/#{mine['id']}", headers: actor.create_new_auth_token
      expect(response).to have_http_status(:not_found)
    end
  end

  it 'keeps personal ownership on create and update even when the request includes another owner' do
    folder = create_folder(agent, user_id: colleague.id)
    patch "#{path}/#{folder['id']}", params: { user_id: colleague.id, name: 'My bookings' }, headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:success)
    expect(CustomFilter.find(folder['id'])).to have_attributes(name: 'My bookings', user_id: agent.id)
  end

  it 'allows another admin to edit and delete team filters and keeps ownership at the account' do
    team = create_folder(admin, visibility: 'team', user_id: agent.id)
    manager = create(:user, :administrator, account: account)
    new_query = { payload: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['open'] }] }
    patch "#{path}/#{team['id']}", params: { name: 'Open', query: new_query, user_id: manager.id },
                                   headers: manager.create_new_auth_token, as: :json
    expect(response).to have_http_status(:success)
    expect(response.parsed_body).to include('visibility' => 'team', 'name' => 'Open', 'query' => new_query.deep_stringify_keys)
    expect(CustomFilter.find(team['id']).user_id).to be_nil
    delete "#{path}/#{team['id']}", headers: manager.create_new_auth_token
    expect(response).to have_http_status(:no_content)
    get "#{path}/#{team['id']}", headers: agent.create_new_auth_token
    expect(response).to have_http_status(:not_found)
  end

  it 'denies agent writes to team filters including through a different account membership' do
    team = create_folder(admin, visibility: 'team')
    other = create(:account)
    create(:account_user, user: agent, account: other, role: :administrator)
    post path, params: attributes.merge(visibility: 'team'), headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)
    patch "#{path}/#{team['id']}", params: { name: 'Changed', visibility: 'personal' }, headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)
    delete "#{path}/#{team['id']}", headers: agent.create_new_auth_token
    expect(response).to have_http_status(:unauthorized)
    expect(CustomFilter.find(team['id']).name).to eq('Missing booking')
  end

  it 'isolates team filters across account memberships even for administrators' do
    team = create_folder(admin, visibility: 'team')
    other = create(:account)
    create(:account_user, user: agent, account: other, role: :administrator)
    other_path = "/api/v1/accounts/#{other.id}/custom_filters"
    get other_path, headers: agent.create_new_auth_token
    expect(response.parsed_body).to be_empty
    get "#{other_path}/#{team['id']}", headers: agent.create_new_auth_token
    expect(response).to have_http_status(:not_found)
    delete "#{other_path}/#{team['id']}", headers: agent.create_new_auth_token
    expect(response).to have_http_status(:not_found)
  end

  it 'retains the original visibility of both team and personal filters' do
    personal = create_folder(admin)
    team = create_folder(admin, visibility: 'team')
    [[personal, 'team'], [team, 'personal']].each do |folder, visibility|
      patch "#{path}/#{folder['id']}", params: { visibility: visibility }, headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  it 'rejects unknown visibility and sharing contact or report filters' do
    team = create_folder(admin, visibility: 'team')
    %w[contact report].each do |type|
      post path, params: attributes.merge(visibility: 'team', filter_type: type), headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      patch "#{path}/#{team['id']}", params: { filter_type: type }, headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end
    post path, params: attributes.merge(visibility: 'public'), headers: admin.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end

  it 'applies the saved absence condition to pre-existing conversations within each reader’s inboxes' do
    expected_ids = [agent, colleague].map do |actor|
      inbox = create(:inbox, account: account)
      create(:inbox_member, inbox: inbox, user: actor)
      missing = create(:conversation, account: account, inbox: inbox, custom_attributes: {})
      null_value = create(:conversation, account: account, inbox: inbox, custom_attributes: { booking: nil })
      create(:conversation, account: account, inbox: inbox, custom_attributes: { booking: 'confirmed' })
      [missing.display_id, null_value.display_id]
    end
    create(:conversation, custom_attributes: {})
    create(:custom_attribute_definition, account: account, attribute_model: :conversation_attribute,
                                         attribute_display_type: :text, attribute_key: 'booking')
    folder = create_folder(admin, visibility: 'team')

    [agent, colleague, admin].zip([*expected_ids, expected_ids.flatten]).each do |actor, ids|
      get "#{path}/#{folder['id']}", headers: actor.create_new_auth_token
      expect(response).to have_http_status(:success)
      post "/api/v1/accounts/#{account.id}/conversations/filter",
           params: response.parsed_body.fetch('query'), headers: actor.create_new_auth_token, as: :json
      expect(response).to have_http_status(:success)
      expect(response.parsed_body.fetch('payload').pluck('id')).to match_array(ids)
      expect(response.parsed_body.dig('meta', 'all_count')).to eq(ids.size)
    end
  end
end
