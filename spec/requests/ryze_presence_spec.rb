require 'rails_helper'

RSpec.describe 'Ryze outgoing presence', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:agent) { build_agent(inbox) }
  let(:colleague) { build_agent(inbox) }
  let(:jid) { '15550001111@s.whatsapp.net' }
  let(:conversation) { create(:conversation, inbox: inbox, account: account, additional_attributes: { whatsapp_jid: jid }) }
  let(:provider_url) { 'https://ryzeapi.cloud/api/chat/presence/Presence%20%2F%20Test' }

  around do |example|
    with_modified_env(RYZE_OUTBOUND_PRESENCE_ENABLED: 'true', RYZE_INBOX_ID: inbox.id.to_s, RYZE_PILOT_CHAT_JID: jid,
                      RYZE_EDIT_CONVERSATION_ID: conversation.display_id.to_s, RYZE_INSTANCE_NAME: 'Presence / Test',
                      RYZE_EDIT_API_TOKEN: 'fake-presence-token', RYZE_WEBHOOK_SECRET: 'fake-webhook-secret') { example.run }
  end

  def build_agent(member_inbox = nil)
    create(:user).tap do |user|
      create(:account_user, account: account, user: user, role: :agent)
      create(:inbox_member, inbox: member_inbox, user: user) if member_inbox
    end
  end

  def pulse(state, user: agent, chat: conversation, composer: '123456784abc', **extra)
    path = api_v1_account_conversation_ryze_presence_path(chat.account_id, chat.display_id)
    post path, as: :json, headers: user.create_new_auth_token, params: { state: state, composer_id: composer, **extra }
  end

  def provider(state)
    stub_request(:post, provider_url).with(headers: { 'token' => 'fake-presence-token' }, body: { number: jid, state: state })
                                     .to_return(body: { success: true }.to_json)
  end

  def dispatch_due
    perform_enqueued_jobs(only: Ryze::DispatchPresenceJob, at: Time.current)
  end

  it 'advertises capability only for a human in the enabled pilot' do
    path = api_v1_account_conversation_path(account.id, conversation.display_id)
    get path, headers: agent.create_new_auth_token

    expect(response.parsed_body['ryze_presence_enabled']).to be(true)

    with_modified_env(RYZE_OUTBOUND_PRESENCE_ENABLED: 'false') do
      get path, headers: agent.create_new_auth_token
      expect(response.parsed_body['ryze_presence_enabled']).to be(false)
    end
  end

  it 'requires conversation access and scopes presence to the opt-in conversation' do
    outsider = build_agent
    other_chat = create(:conversation, inbox: inbox, account: account, additional_attributes: { whatsapp_jid: jid })

    expect do
      pulse('typing', user: outsider)
      expect(response).to have_http_status(:unauthorized)
      pulse('typing', chat: other_chat)
      expect(response).to have_http_status(:no_content)
      with_modified_env(RYZE_OUTBOUND_PRESENCE_ENABLED: nil) { pulse('typing') }
      expect(response).to have_http_status(:no_content)
    end.not_to have_enqueued_job(Ryze::DispatchPresenceJob)

    expect(WebMock).not_to have_requested(:post, provider_url)
  end

  it 'rejects private and malformed inputs before registering activity' do
    expect do
      pulse('typing', is_private: true)
      expect(response).to have_http_status(:unprocessable_content)
      pulse(['typing'])
      expect(response).to have_http_status(:unprocessable_content)
      pulse('typing', composer: 'invalid')
      expect(response).to have_http_status(:unprocessable_content)
    end.not_to have_enqueued_job(Ryze::DispatchPresenceJob)
  end

  it 'lets recording take precedence and only pauses after both people stop' do
    typing = provider('typing')
    recording = provider('recording')
    pause = provider('pause')

    freeze_time do
      expect do
        pulse('typing')
        pulse('recording', user: colleague)
        5.times { pulse('typing') }
        expect(enqueued_jobs.count { |job| job[:job] == Ryze::DispatchPresenceJob }).to eq(1)
        dispatch_due
        expect(recording).to have_been_requested.once
        expect(typing).not_to have_been_requested

        pulse('pause', user: colleague)
        pulse('typing')
        expect(pause).not_to have_been_requested

        travel 4.seconds
        dispatch_due
        expect(typing).to have_been_requested.once

        pulse('pause')
        travel 4.seconds
        dispatch_due
        expect(pause).to have_been_requested.once
      end.not_to change(Message, :count)
    end
  end

  it 'ignores duplicate jobs, and a provider timeout stays within the normal pulse cadence' do
    typing = provider('typing').to_timeout

    freeze_time do
      pulse('typing')
      job = enqueued_jobs.find { |entry| entry[:job] == Ryze::DispatchPresenceJob }
      dispatch_due
      Ryze::DispatchPresenceJob.perform_now(*job.fetch(:args))

      expect(typing).to have_been_requested.once
      expect(enqueued_jobs.count { |entry| entry[:job] == Ryze::DispatchPresenceJob }).to eq(1)

      travel 4.seconds
      provider('typing')
      dispatch_due
      expect(WebMock).to have_requested(:post, provider_url).with(body: { number: jid, state: 'typing' }).twice
    end
  end

  it 'suppresses work for a pulse that was cancelled before any provider dispatch' do
    freeze_time do
      pulse('typing')
      pulse('pause')
      dispatch_due

      expect(WebMock).not_to have_requested(:post, provider_url)
      expect(enqueued_jobs.none? { |job| job[:job] == Ryze::DispatchPresenceJob }).to be(true)
    end
  end

  it 'uses finite leases and drops queued work when the pilot is switched off' do
    typing = provider('typing')
    pause = provider('pause')

    freeze_time do
      pulse('typing')
      dispatch_due
      expect(typing).to have_been_requested.once

      travel 12.seconds
      dispatch_due
      expect(pause).to have_been_requested.once

      pulse('recording')
      travel 4.seconds
      with_modified_env(RYZE_OUTBOUND_PRESENCE_ENABLED: 'false') { dispatch_due }
      expect(WebMock).not_to have_requested(:post, provider_url).with(body: { number: jid, state: 'recording' })
    end
  end
end
