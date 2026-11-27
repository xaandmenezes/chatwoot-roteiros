require 'rails_helper'

RSpec.describe 'Ryze pilot profile avatar', type: :request do
  include ActiveJob::TestHelper

  let(:channel) { create(:channel_api) }
  let(:inbox) { channel.reload.inbox }
  let(:jid) { '5511999999999@s.whatsapp.net' }
  let(:profile_number) { '5511999999999' }
  let!(:conversation) do
    create(:conversation, account: inbox.account, inbox: inbox, additional_attributes: { whatsapp_jid: jid })
  end
  let(:contact) { conversation.contact }
  let(:avatar_url) { 'https://pps.whatsapp.net/avatar.png?signature=temporary' }
  let(:profile_endpoint) { 'https://ryzeapi.cloud/api/profile/getAccount/pilot' }
  let(:avatar_body) { File.binread(Rails.root.join('spec/assets/avatar.png')) }
  let(:claim_key) { "RYZE_PROFILE_AVATAR:#{inbox.id}:#{conversation.display_id}" }
  let(:payload) do
    {
      event: 'message.exchange', instanceData: { instance: 'pilot' },
      data: { id: 'WA-1', direction: 'incoming', chat: { jid: jid, type: 'private' }, message: { type: 'text', content: 'Olá' } }
    }
  end

  around do |example|
    with_modified_env(RYZE_WEBHOOK_SECRET: 'avatar-test-secret', RYZE_INSTANCE_NAME: 'pilot', RYZE_INBOX_ID: inbox.id.to_s,
                      RYZE_EDIT_API_TOKEN: 'avatar-test-token', RYZE_PILOT_CHAT_JID: jid, RYZE_PROFILE_AVATAR_SYNC: 'true',
                      RYZE_EDIT_CONVERSATION_ID: conversation.display_id.to_s) { example.run }
  ensure
    Redis::Alfred.delete(claim_key)
  end

  def receive_event(event = payload, token: 'avatar-test-secret')
    post '/webhooks/ryze', params: event, as: :json, headers: { 'Authorization' => "Bearer #{token}" }
  end

  def stub_profile
    stub_request(:get, profile_endpoint).with(query: { number: profile_number }, headers: { 'token' => 'avatar-test-token' })
  end

  def stub_avatar(&before_download)
    allow(Resolv).to receive(:getaddresses).and_call_original
    allow(Resolv).to receive(:getaddresses).with('pps.whatsapp.net').and_return(['93.184.216.34'])
    stub_request(:get, avatar_url).to_return do
      before_download&.call
      { body: avatar_body, headers: { 'Content-Type' => 'image/png' } }
    end
  end

  it 'imports a temporary photo for the already linked contact only once on replay' do
    profile = stub_profile.to_return(body: { success: true, profile: { profilePicture: avatar_url } }.to_json)
    download = stub_avatar
    other_contact = create(:contact, account: create(:account))

    perform_enqueued_jobs do
      receive_event
      expect(response).to have_http_status(:ok)
      receive_event
    end

    expect(profile).to have_been_requested.once
    expect(download).to have_been_requested.once
    expect(contact.reload.avatar.download).to eq(avatar_body)
    expect(other_contact.reload.avatar).not_to be_attached
  end

  it 'keeps the avatar absent and limits repeated profile lookups when Ryze returns null' do
    profile = stub_profile.to_return(body: { success: true, profile: { profilePicture: nil } }.to_json)

    perform_enqueued_jobs do
      receive_event
      receive_event
    end

    expect(profile).to have_been_requested.once
    expect(contact.reload.avatar).not_to be_attached
  end

  it 'acknowledges the message and leaves the contact unchanged on a network timeout' do
    profile = stub_profile.to_timeout

    perform_enqueued_jobs { receive_event }

    expect(response).to have_http_status(:ok)
    expect(profile).to have_been_requested.once
    expect(contact.reload.avatar).not_to be_attached
  end

  it 'skips lookup when a manual avatar is already attached' do
    contact.avatar.attach(io: StringIO.new(avatar_body), filename: 'manual.png', content_type: 'image/png')
    blob_id = contact.avatar.blob.id
    profile = stub_profile

    perform_enqueued_jobs { receive_event }

    expect(profile).not_to have_been_requested
    expect(contact.reload.avatar.blob.id).to eq(blob_id)
  end

  it 'keeps an avatar added while the CDN request is in flight' do
    stub_profile.to_return(body: { success: true, profile: { profilePicture: avatar_url } }.to_json)
    download = stub_avatar do
      contact.avatar.attach(io: StringIO.new(avatar_body), filename: 'manual.png', content_type: 'image/png')
    end

    perform_enqueued_jobs { receive_event }

    expect(download).to have_been_requested.once
    expect(contact.reload.avatar.filename.to_s).to eq('manual.png')
  end

  it 'rejects an unexpected image origin' do
    url = 'http://127.0.0.1/avatar.png'
    profile = stub_profile.to_return(body: { success: true, profile: { profilePicture: url } }.to_json)

    perform_enqueued_jobs { receive_event }

    expect(profile).to have_been_requested.once
    expect(WebMock).not_to have_requested(:get, url)
    expect(contact.reload.avatar).not_to be_attached
  end

  context 'with a pilot backed by a LID' do
    let(:jid) { '52399087550579@lid' }
    let(:profile_number) { jid }

    it 'uses the full LID as the profile query target' do
      profile = stub_profile.to_return(body: { success: true, profile: { profilePicture: nil } }.to_json)
      event = payload.deep_merge(data: { chat: { jid: '', lid: jid } })

      perform_enqueued_jobs { receive_event(event) }

      expect(profile).to have_been_requested.once
    end
  end

  it 'skips unauthorized, disabled, foreign chat, outgoing, and group events' do
    profile = stub_profile

    perform_enqueued_jobs do
      receive_event(token: 'wrong')
      expect(response).to have_http_status(:unauthorized)
      with_modified_env(RYZE_PROFILE_AVATAR_SYNC: nil) { receive_event }
      receive_event(payload.deep_merge(data: { chat: { jid: '5511888888888@s.whatsapp.net' } }))
      receive_event(payload.deep_merge(data: { direction: 'outgoing' }))
      receive_event(payload.deep_merge(data: { chat: { type: 'group' } }))
    end

    expect(profile).not_to have_been_requested
  end

  it 'ignores the same display ID in a different account and inbox' do
    other_inbox = create(:channel_api).reload.inbox
    create(:conversation, account: other_inbox.account, inbox: other_inbox, display_id: conversation.display_id,
                          additional_attributes: { whatsapp_jid: '5511888888888@s.whatsapp.net' })
    profile = stub_profile

    with_modified_env(RYZE_INBOX_ID: other_inbox.id.to_s) { perform_enqueued_jobs { receive_event } }

    expect(profile).not_to have_been_requested
    expect(contact.reload.avatar).not_to be_attached
  end
end
