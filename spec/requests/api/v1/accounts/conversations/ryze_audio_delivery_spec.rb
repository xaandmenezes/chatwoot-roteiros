require 'rails_helper'

RSpec.describe 'Delivery callbacks for outgoing Ryze audio', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox).reload }
  let(:bridge) { create(:user, account: account, role: :administrator) }
  let(:audio) do
    create(:message, account: account, conversation: conversation, inbox: inbox, message_type: :outgoing).tap do |message|
      message.attachments.create!(account: account, file_type: :audio,
                                  file: { io: Rails.root.join('spec/assets/sample.ogg').open, filename: 'voice.ogg', content_type: 'audio/ogg' })
    end
  end
  let(:path) { "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages/#{audio.id}" }
  let(:provider_error) { 'Provider rejected this audio' }

  around do |example|
    with_modified_env(RYZE_INBOX_ID: inbox.id.to_s, RYZE_NATIVE_BRIDGE_USER_ID: bridge.id.to_s) { example.run }
  end

  def callback(status, error = nil, headers: { api_access_token: bridge.access_token.token })
    patch path, params: { status: status, external_error: error }.compact, headers: headers
    expect(response).to have_http_status(:success)
  end

  def read_timeout
    raise Net::ReadTimeout
  rescue Net::ReadTimeout
    raise SafeFetch::FetchError, 'read timed out'
  end

  def submit_webhook
    Webhooks::Trigger.execute('https://ryze.example/callback', { event: 'message_created', id: audio.id }, :api_inbox_webhook)
  end

  it 'keeps the explicit bridge acknowledgment when its HTTP request subsequently times out' do
    allow(SafeFetch).to receive(:fetch) do
      callback('sent')
      read_timeout
    end
    submit_webhook
    expect(audio.reload).to have_attributes(status: 'sent', external_error: nil)
  end

  it 'blocks resend while the result is unknown and recovers on a later bridge acknowledgment' do
    allow(SafeFetch).to receive(:fetch) { read_timeout }
    submit_webhook
    expect(audio.reload).to have_attributes(status: 'failed', external_error: 'ryze_delivery_unknown')
    expect { post "#{path}/retry", headers: bridge.create_new_auth_token }.not_to have_enqueued_job(SendReplyJob)
    expect(response).to have_http_status(:conflict)
    callback('sent')
    expect(audio.reload).to have_attributes(status: 'sent', external_error: nil)
  end

  it 'keeps a gateway timeout unconfirmed rather than treating it as a rejection' do
    allow(SafeFetch).to receive(:fetch).and_raise(SafeFetch::HttpError, '504 Gateway Timeout')
    submit_webhook
    expect(audio.reload.external_error).to eq('ryze_delivery_unknown')
  end

  it 'makes a definite rejection retryable even if the provider omits a diagnostic' do
    allow(SafeFetch).to receive(:fetch) { read_timeout }
    submit_webhook
    callback('failed')
    expect(audio.reload).to have_attributes(status: 'failed', external_error: 'ryze_delivery_failed')
    expect { post "#{path}/retry", headers: bridge.create_new_auth_token }.to have_enqueued_job(SendReplyJob).with(audio.id)
  end

  it 'accepts a real negative delivery callback after acceptance, including on redelivery' do
    callback('sent')
    2.times { callback('failed', provider_error) }
    expect(audio.reload).to have_attributes(status: 'failed', external_error: provider_error)
  end

  it 'preserves a provider rejection across a late acceptance and local HTTP error, until delivery is confirmed' do
    callback('failed', provider_error)
    callback('sent')
    allow(SafeFetch).to receive(:fetch).and_raise(SafeFetch::FetchError, 'read timed out')
    submit_webhook
    expect(audio.reload).to have_attributes(status: 'failed', external_error: provider_error)
    callback('delivered')
    expect(audio.reload).to have_attributes(status: 'delivered', external_error: nil)
  end

  it 'preserves a delivered audio created before bridge receipts were recorded' do
    audio.update!(status: :delivered)
    callback('failed', provider_error)
    allow(SafeFetch).to receive(:fetch) { read_timeout }
    submit_webhook
    expect(audio.reload).to have_attributes(status: 'delivered', external_error: nil)
  end

  it 'preserves a confirmed receipt when a stale negative callback arrives' do
    callback('delivered')
    callback('failed', provider_error)
    expect(audio.reload).to have_attributes(status: 'delivered', external_error: nil)
  end

  it 'does not mistake the ordinary initial status or the agent session for a provider acknowledgment' do
    callback('sent', headers: bridge.create_new_auth_token)
    allow(SafeFetch).to receive(:fetch).and_raise(SafeFetch::HttpError, '422 Unprocessable Content')
    submit_webhook
    expect(audio.reload).to have_attributes(status: 'failed', external_error: '422 Unprocessable Content')
  end

  it 'keeps the original handling for a message whose receipt could refer to another attachment' do
    audio.attachments.create!(account: account, file_type: :location, coordinates_lat: 1, coordinates_long: 1)
    callback('sent')
    allow(SafeFetch).to receive(:fetch).and_raise(SafeFetch::FetchError, 'timed out')
    submit_webhook
    expect(audio.reload).to have_attributes(status: 'failed', external_error: 'timed out')
  end

  it 'starts a fresh attempt when an agent retries a rejected audio' do
    callback('failed', provider_error)
    post "#{path}/retry", headers: bridge.create_new_auth_token
    expect(response).to have_http_status(:success)
    allow(SafeFetch).to receive(:fetch).and_raise(SafeFetch::FetchError, 'retry timed out')
    submit_webhook
    expect(audio.reload).to have_attributes(status: 'failed', external_error: 'retry timed out')
  end
end
