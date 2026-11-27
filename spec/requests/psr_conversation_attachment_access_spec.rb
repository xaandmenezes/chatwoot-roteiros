require 'rails_helper'
require 'uri'

RSpec.describe 'Attachment access for the restricted inbox', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:owner) { create(:user, account: account, role: :agent) }
  let(:other_agent) { create(:user, account: account, role: :agent) }
  let(:owner_headers) { owner.create_new_auth_token }
  let(:other_headers) { other_agent.create_new_auth_token }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: owner) }
  let(:message) { create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :outgoing) }
  let(:audio) do
    message.attachments.create!(account: account, file_type: :audio).tap do |file|
      file.file.attach(io: StringIO.new('surrogate audio'), filename: 'test.ogg', content_type: 'audio/ogg', identify: false)
    end
  end
  let(:image) do
    message.attachments.create!(account: account, file_type: :image).tap do |file|
      Rails.root.join('spec/assets/avatar.png').open do |source|
        file.file.attach(io: source, filename: 'avatar.png', content_type: 'image/png')
      end
    end
  end
  let(:path) { URI(audio.file_url).request_uri }
  let(:urls) { Rails.application.routes.url_helpers }

  around do |example|
    with_modified_env(PSR_RESTRICTED_INBOX_ID: inbox.id.to_s) { example.run }
  end

  before do
    inbox.inbox_members.create!(user: owner)
    inbox.inbox_members.create!(user: other_agent)
  end

  def dashboard_cookie(headers)
    cookies['cw_d_session_info'] = headers.to_json
  end

  it 'serves the dashboard audio, denies the former owner and keeps the same URL after a transfer' do
    dashboard_cookie(owner_headers)
    get path

    expect(response).to have_http_status(:ok)
    expect(response.body).to eq('surrogate audio')
    expect(response.headers['Content-Type']).to eq('audio/ogg')

    post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/assignments",
         params: { assignee_id: other_agent.id },
         headers: owner_headers
    expect(response).to have_http_status(:ok)

    get path
    expect(response).to have_http_status(:unauthorized)

    dashboard_cookie(other_headers)
    get path
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq('surrogate audio')
  end

  it 'serves a single requested byte range to the owner using dashboard headers' do
    get path, headers: owner_headers.merge('Range' => 'bytes=2-5')

    expect(response).to have_http_status(:partial_content)
    expect(response.headers['Content-Range']).to eq('bytes 2-5/15')
    expect(response.headers['Accept-Ranges']).to eq('bytes')
    expect(response.headers['Content-Length']).to eq('4')
    expect(response.headers['Cache-Control']).to include('no-store')
    expect(response.body).to eq('rrog')
  end

  it 'applies the storage range limit and rejects an unauthenticated range before reading the file' do
    get path, headers: owner_headers.merge('Range' => 'bytes=0-1,5-6')
    expect(response).to have_http_status(:range_not_satisfiable)

    get path, headers: { 'Range' => 'bytes=2-5' }
    expect(response).to have_http_status(:unauthorized)
    expect(response.headers['Cache-Control']).to include('no-store')
  end

  it 'authorizes previously issued blob redirect and proxy URLs on each request' do
    blob = audio.file.blob
    legacy_urls = [urls.rails_storage_redirect_path(blob), urls.rails_storage_proxy_path(blob)]

    legacy_urls.each do |legacy_path|
      get legacy_path
      expect(response).to have_http_status(:redirect)
      expect(response.headers['Cache-Control']).to include('no-store')
      expect(URI(response.location).path).to eq(path)
      follow_redirect!
      expect(response).to have_http_status(:unauthorized)
    end

    dashboard_cookie(owner_headers)
    get legacy_urls.last
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq('surrogate audio')
  end

  it 'routes legacy representations before processing the image and authorizes the thumbnail' do
    blob = image.file.blob
    variant = blob.variant(resize_to_fill: [80, 80])
    legacy_path = urls.rails_storage_proxy_path(variant)

    expect { get legacy_path }.not_to change(ActiveStorage::VariantRecord, :count)

    expect(response).to have_http_status(:redirect)
    expect(URI(response.location).request_uri).to eq(URI(image.thumb_url).request_uri)
    follow_redirect!
    expect(response).to have_http_status(:unauthorized)
  end

  it 'streams a protected thumbnail for the current owner' do
    get URI(image.thumb_url).request_uri, headers: owner_headers

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to start_with('image/')
    expect(response.headers['Cache-Control']).to include('no-store')
    expect(response.body.bytesize).to be_positive
  end

  it 'does not fall back to the owner cookie when another user sends explicit credentials' do
    dashboard_cookie(owner_headers)
    get path, headers: other_headers

    expect(response).to have_http_status(:unauthorized)
  end

  it 'scopes the attachment ID to the authorized conversation' do
    other_conversation = create(:conversation, account: account, inbox: inbox, assignee: owner)
    mismatched_path = urls.api_v1_account_conversation_attachment_path(account.id, other_conversation.display_id, audio.id)

    get mismatched_path, headers: owner_headers

    expect(response).to have_http_status(:not_found)
  end

  it 'keeps ordinary storage URLs and their public delivery on other inboxes' do
    ordinary_message = create(:message, account: account)
    attachment = ordinary_message.attachments.create!(account: account, file_type: :audio)
    attachment.file.attach(io: StringIO.new('outside pilot'), filename: 'ordinary.ogg', content_type: 'audio/ogg', identify: false)

    expect(URI(attachment.file_url).path).to start_with('/rails/active_storage/')
    get urls.rails_storage_proxy_path(attachment.file.blob)

    expect(response).to have_http_status(:ok)
    expect(response.body).to eq('outside pilot')
  end

  it 'provides expiring storage links instead of dashboard-session links in webhook payloads' do
    audio
    dashboard_url = message.push_event_data[:attachments].sole.fetch(:data_url)
    webhook_url = message.webhook_data[:attachments].sole.fetch(:data_url)

    expect(URI(dashboard_url).path).to eq(path)
    webhook_preview = conversation.webhook_data.fetch(:messages).sole
    expect(URI(webhook_preview.fetch(:attachments).sole.fetch(:data_url)).path).to start_with('/rails/active_storage/disk/')
    expect(URI(webhook_url).path).to start_with('/rails/active_storage/disk/')
    get URI(webhook_url).request_uri

    expect(response).to have_http_status(:ok)
    expect(response.body).to eq('surrogate audio')

    travel ActiveStorage.service_urls_expire_in + 1.second do
      get URI(webhook_url).request_uri
      expect(response).to have_http_status(:not_found)
    end
  end
end
