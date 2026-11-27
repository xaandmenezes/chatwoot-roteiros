require 'rails_helper'

RSpec.describe 'Resending restricted attachments', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:other_agent) { create(:user, account: account, role: :agent) }
  let(:headers) { agent.create_new_auth_token }
  let(:source) { create(:conversation, account: account, inbox: inbox, assignee: agent) }
  let(:destination) { create(:conversation, account: account, inbox: inbox, assignee: agent) }
  let(:source_blob) do
    source_message = source.messages.create!(account: account, inbox: inbox, content: 'source', message_type: :outgoing)
    source_message.attachments.create!(account: account, file_type: :audio).tap do |file|
      file.file.attach(new_audio)
    end.file.blob
  end

  around do |example|
    with_modified_env(PSR_RESTRICTED_INBOX_ID: inbox.id.to_s) { example.run }
  end

  before do
    inbox.inbox_members.create!(user: agent)
    inbox.inbox_members.create!(user: other_agent)
  end

  def new_audio
    { io: StringIO.new('surrogate audio'), filename: 'test.ogg', content_type: 'audio/ogg', identify: false }
  end

  def resend(blob)
    params = { content: 'forward', attachments: [blob.signed_id] }
    post "/api/v1/accounts/#{account.id}/conversations/#{destination.display_id}/messages", headers: headers, params: params, as: :json
  end

  it 'rejects uploading a pilot blob into another owned conversation after transferring the source' do
    blob = source_blob
    source.update!(assignee: other_agent)

    expect { resend(blob) }.not_to change(destination.messages, :count)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it 'allows reuse when the current owner can access both conversations' do
    resend(source_blob)

    expect(response).to have_http_status(:ok)
    expect(destination.messages.outgoing.last.attachments.sole.file.blob).to eq(source_blob)
  end

  context 'when sharing to another inbox the agent can access' do
    let(:ordinary_inbox) { create(:channel_api, account: account).inbox }
    let(:destination) { create(:conversation, account: account, inbox: ordinary_inbox, assignee: agent) }

    before { ordinary_inbox.inbox_members.create!(user: agent) }

    it 'issues a protected download link scoped to the destination' do
      resend(source_blob)
      expect(response).to have_http_status(:ok)

      copy = destination.messages.outgoing.last.attachments.sole
      get URI(copy.file_url).request_uri, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq('surrogate audio')
    end
  end

  it 'still allows a freshly uploaded blob' do
    blob = ActiveStorage::Blob.create_and_upload!(**new_audio)

    resend(blob)

    expect(response).to have_http_status(:ok)
    expect(destination.messages.outgoing.last.attachments.sole.file.blob).to eq(blob)
  end

  it 'allows public media reuse only in the same conversation when there is no dashboard actor' do
    same_message = source.messages.build(account: account, inbox: inbox, message_type: :incoming)
    other_message = destination.messages.build(account: account, inbox: inbox, message_type: :incoming)

    expect(same_message.attachments.build(account: account, file_type: :audio, file: source_blob)).to be_valid
    expect(other_message.attachments.build(account: account, file_type: :audio, file: source_blob)).not_to be_valid
  end

  it 'rejects saving a reusable macro that contains restricted pilot media' do
    params = {
      name: 'Restricted media',
      visibility: 'personal',
      actions: [{ action_name: 'send_attachment', action_params: [source_blob.signed_id] }]
    }

    expect do
      post "/api/v1/accounts/#{account.id}/macros", headers: headers, params: params, as: :json
    end.not_to change(account.macros, :count)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it 'blocks execution of a previously saved macro if permission to its source was transferred' do
    blob = source_blob
    source.update!(assignee: other_agent)
    macro = account.macros.create!(created_by: agent, name: 'Legacy', actions: [{ action_name: 'send_attachment', action_params: [blob.id] }])
    macro.files.attach(blob)

    expect do
      MacrosExecutionJob.perform_now(macro, conversation_ids: [destination.display_id], user: agent)
    end.not_to change(destination.messages.outgoing, :count)
  end
end
