require 'rails_helper'

RSpec.describe 'Ryze audio transcriptions API', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox).reload }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:path) { "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/audio_transcriptions" }

  around do |example|
    with_modified_env(RYZE_AUDIO_TRANSCRIPTION_ENABLED: 'true', RYZE_INBOX_ID: inbox.id.to_s,
                      RYZE_AUDIO_TRANSCRIPTION_CONVERSATION_ID: conversation.display_id.to_s) { example.run }
  end

  before do
    create(:inbox_member, inbox: inbox, user: agent)
  end

  it 'rejects malformed and oversized lists of attachment IDs' do
    headers = agent.create_new_auth_token
    [{}, { attachment_ids: '1' }, { attachment_ids: { invalid: '1' } },
     { attachment_ids: ['-1'] }, { attachment_ids: ['1.5'] }, { attachment_ids: [1, 'bad'] },
     { attachment_ids: [1, { unexpected: '1' }] }, { attachment_ids: Array.new(101, 1) }].each do |query|
      get path, headers: headers, params: query

      expect(response).to have_http_status(422)
    end
  end

  it 'returns each stored result in the conversation once and omits unknown or legacy attachments' do
    completed = transcribe_attachment(conversation, status: :completed, text: 'Passeio pelo Espelho')
    pending = transcribe_attachment(conversation, status: :pending)
    failed = transcribe_attachment(conversation, status: :failed)
    legacy = with_modified_env(RYZE_AUDIO_TRANSCRIPTION_ENABLED: 'false') { build_attachment(conversation) }
    same_account = transcribe_attachment(create(:conversation, account: account, inbox: inbox), status: :completed, text: 'Outra conversa')
    other_account = transcribe_attachment(create(:conversation), status: :completed, text: 'Outra conta')

    get path, headers: agent.create_new_auth_token, params: {
      attachment_ids: [completed.attachment_id, pending.attachment_id, failed.attachment_id, legacy.id, same_account.attachment_id,
                       other_account.attachment_id, completed.attachment_id, 2_147_483_647]
    }

    expect(response).to have_http_status(:ok)
    expect(response.headers.fetch('Cache-Control')).to include('no-store')
    expect(response.parsed_body.fetch('transcriptions')).to contain_exactly(
      { 'attachment_id' => completed.attachment_id, 'status' => 'completed', 'text' => 'Passeio pelo Espelho' },
      { 'attachment_id' => pending.attachment_id, 'status' => 'pending', 'text' => nil },
      { 'attachment_id' => failed.attachment_id, 'status' => 'failed', 'text' => nil }
    )
  end

  it 'denies requests by unsigned visitors and agent bots' do
    bot = create(:agent_bot, account: account)

    get path, params: { attachment_ids: [1] }
    expect(response).to have_http_status(:unauthorized)

    get path, headers: { api_access_token: bot.access_token.token }, params: { attachment_ids: [1] }
    expect(response).to have_http_status(:unauthorized)
  end

  it 'restricts access to dashboard authentication even when the API token belongs to the agent' do
    login_headers = agent.create_new_auth_token
    dashboard_bearer = "Bearer #{Base64.strict_encode64(login_headers.to_json)}"
    get path, headers: { Authorization: dashboard_bearer }, params: { attachment_ids: [1] }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('transcriptions' => [])

    api_headers = { api_access_token: agent.access_token.token }
    get path, headers: api_headers, params: { attachment_ids: [1] }
    expect(response).to have_http_status(:not_found)

    get api_v1_account_conversation_messages_path(account, conversation.display_id), headers: api_headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('meta')).not_to have_key('ryze_audio_transcription_enabled')
  end

  it 'denies an agent who cannot see the conversation' do
    other_agent = create(:user, account: account, role: :agent)
    get path, headers: other_agent.create_new_auth_token, params: { attachment_ids: [1] }

    expect(response).to have_http_status(:unauthorized)
  end

  it 'responds with 404 outside the configured pilot' do
    other_conversation = create(:conversation, account: account, inbox: inbox).reload
    other_path = "/api/v1/accounts/#{account.id}/conversations/#{other_conversation.display_id}/audio_transcriptions"
    get other_path, headers: agent.create_new_auth_token, params: { attachment_ids: [1] }

    expect(response).to have_http_status(:not_found)
  end

  it 'exposes availability to the agent without embedding a transcript in conversation or webhook data' do
    transcription = transcribe_attachment(conversation, status: :completed, text: 'Texto reservado')
    message = transcription.attachment.message
    get api_v1_account_conversation_messages_path(account, conversation.display_id), headers: agent.create_new_auth_token

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('meta')).to include('ryze_audio_transcription_enabled' => true)
    expect(response.body).not_to include('Texto reservado')
    expect(message.webhook_data.to_json).not_to include('Texto reservado')
    expect(message.webhook_push_event_data.to_json).not_to include('Texto reservado')
    expect(message.widget_push_event_data.to_json).not_to include('Texto reservado')
  end

  it 'keeps the private text out of contact API responses' do
    transcription = transcribe_attachment(conversation, status: :completed, text: 'Texto reservado')
    public_path = public_api_v1_inbox_contact_conversation_messages_path(
      inbox.channel.identifier, conversation.contact_inbox.source_id, conversation.display_id
    )

    get public_path

    expect(response).to have_http_status(:ok)
    message = response.parsed_body.find { |item| item['id'] == transcription.attachment.message_id }
    expect(message.fetch('attachments').sole).to include('id' => transcription.attachment_id, 'transcribed_text' => '')
    expect(response.body).not_to include('Texto reservado')
  end

  it 'hides availability when transcription is disabled' do
    headers = agent.create_new_auth_token
    with_modified_env(RYZE_AUDIO_TRANSCRIPTION_ENABLED: 'false') do
      get api_v1_account_conversation_messages_path(account, conversation.display_id), headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch('meta')).not_to have_key('ryze_audio_transcription_enabled')
      get path, headers: headers, params: { attachment_ids: [1] }
      expect(response).to have_http_status(:not_found)
    end
  end

  def transcribe_attachment(conversation, status:, text: nil)
    attachment = build_attachment(conversation)
    Ryze::AudioTranscription.find_or_initialize_by(attachment: attachment).tap do |transcription|
      transcription.update!(status: status, text: text)
    end
  end

  def build_attachment(conversation)
    message = create(:message, conversation: conversation, account: conversation.account)
    attachment = message.attachments.build(account: conversation.account, file_type: :audio)
    attachment.file.attach(io: StringIO.new('fake audio'), filename: 'voice.ogg', content_type: 'audio/ogg', identify: false)
    attachment.save!
    attachment
  end
end
