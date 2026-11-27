require 'rails_helper'
require 'timeout'

RSpec.describe 'Incoming attachment replay in API inboxes', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:agent) { create(:user, account: account, role: :administrator) }
  let(:url) { api_v1_account_conversation_messages_url(account, conversation.display_id) }
  let(:headers) { { api_access_token: agent.access_token.token } }
  let(:service) { ActiveStorage::Blob.service }

  def document(body)
    Rack::Test::UploadedFile.new(StringIO.new(body), 'text/plain', original_filename: 'document.txt')
  end

  def deliver(files, target: conversation, **attributes)
    payload = { message_type: 'incoming', source_id: 'provider-media-123', content: 'Caption', attachments: files }
    post api_v1_account_conversation_messages_url(account, target.display_id), headers: headers, params: payload.merge(attributes).compact
    response.parsed_body
  end

  it 'returns the original message with caption, quotation, ordered files and voice-note flags' do
    quoted = create(:message, account: account, conversation: conversation, inbox: inbox, source_id: 'quoted')
    audio = -> { fixture_file_upload('spec/assets/sample.ogg', 'audio/ogg') }
    first = deliver([audio.call, document('second file'), audio.call],
                    voice_message_attachment_indices: ['2'], content_attributes: { in_reply_to_external_id: quoted.source_id })
    conversation.update!(status: :resolved)

    replay = deliver([audio.call, document('second file'), audio.call], echo_id: 'retry-echo', voice_message_attachment_indices: ['2'])
    expect(response).to have_http_status(:ok)
    expect(replay).to include('id' => first.fetch('id'), 'content' => 'Caption', 'echo_id' => 'retry-echo')
    expect(replay.fetch('content_attributes')).to include('in_reply_to' => quoted.id)
    payloads = [first, replay].map { |delivery| delivery.fetch('attachments').pluck('file_type', 'is_voice_message') }
    expect(payloads).to all(eq([['audio', false], ['file', nil], ['audio', true]]))
    expect(replay.fetch('attachments').pluck('id')).to eq(first.fetch('attachments').pluck('id'))
    expect(Message.find(first.fetch('id')).webhook_data.fetch(:attachments).pluck(:id)).to eq(first.fetch('attachments').pluck('id'))
    expect(conversation.reload).to be_resolved
  end

  it 'preserves distinct files with the same filename and retains multiplicity and order' do
    first = deliver([document('one'), document('two')])
    reversed = deliver([document('two'), document('one')])
    repeated = deliver([document('one'), document('one')])

    expect([first, reversed, repeated].pluck('id').uniq.size).to eq(3)
    expect(repeated.fetch('attachments').pluck('id').uniq.size).to eq(2)
    expect(deliver([document('one'), document('two')]).fetch('id')).to eq(first.fetch('id'))
  end

  it 'fills a historical placeholder committed while the live multipart upload is in flight' do
    imported = nil
    allow(service).to receive(:upload).and_wrap_original do |upload, key, io, **options|
      upload.call(key, io, **options)
      imported ||= create(
        :message,
        account: account, conversation: conversation, inbox: inbox, source_id: 'provider-media-123',
        additional_attributes: { ryze_historical_sync: true, ryze_history_pending_media: { type: 'document', placeholder: true } }
      )
    end
    dispatcher = Rails.configuration.dispatcher
    allow(dispatcher).to receive(:dispatch).and_call_original
    result = deliver([document('live file')])
    expect(result).to include('id' => imported.id, 'historical_import' => true, 'historical_media_pending' => false, 'content' => 'Caption')
    expect(conversation.messages.incoming.sole).to eq(imported)
    expect(imported.reload.attachments.sole.file.download).to eq('live file')
    expect(dispatcher).to have_received(:dispatch).with('message.updated', anything, hash_including(message: imported)).once
    expect(ActiveStorage::PurgeJob).not_to have_been_enqueued
  end

  it 'leaves private, outgoing and unidentified deliveries independent' do
    ids = [
      deliver([document('same')], private: true), deliver([document('same')], message_type: 'outgoing'),
      deliver([document('same')], source_id: nil), deliver([document('same')], source_id: nil),
      deliver([document('same')])
    ].pluck('id')

    expect(ids.uniq.size).to eq(5)
    expect(deliver([document('same')]).fetch('id')).to eq(ids.last)
  end

  it 'reuses a full attachment batch only within the same conversation' do
    files = -> { Array.new(Message::NUMBER_OF_PERMITTED_ATTACHMENTS) { |index| document("file-#{index}") } }
    first = deliver(files.call)
    another = create(:conversation, account: account, inbox: inbox)
    independent = deliver(files.call, target: another)
    replay = deliver(files.call)

    expect(first.fetch('attachments').size).to eq(Message::NUMBER_OF_PERMITTED_ATTACHMENTS)
    expect(independent.fetch('id')).not_to eq(first.fetch('id'))
    expect(replay.fetch('id')).to eq(first.fetch('id'))
    expect(replay.fetch('attachments').pluck('id')).to eq(first.fetch('attachments').pluck('id'))
  end

  it 'does not publish a new message if the second upload fails, then creates it once on retry' do
    fail_upload = true
    allow(service).to receive(:upload).and_wrap_original do |upload, key, io, **options|
      raise IOError, 'synthetic storage failure' if fail_upload && io.read == 'second'

      io.rewind
      upload.call(key, io, **options)
    end
    expect do
      deliver([document('first'), document('second')])
      expect(response).to have_http_status(:unprocessable_content)
    end.not_to(change { conversation.messages.incoming.count })

    fail_upload = false
    first = deliver([document('first'), document('second')])
    expect(response).to have_http_status(:ok)
    expect(conversation.messages.incoming.sole.attachments.map { |item| item.file.download }).to eq(%w[first second])
    expect(deliver([document('first'), document('second')]).fetch('id')).to eq(first.fetch('id'))
  end

  it 'repairs an incomplete legacy upload in place without re-opening the conversation' do
    message = build(:message, account: account, conversation: conversation, inbox: inbox, source_id: 'provider-media-123')
    %w[first second third].each do |body|
      attachment = message.attachments.build(account: account, file_type: :file)
      attachment.file.attach(io: StringIO.new(body), filename: 'document.txt', content_type: 'text/plain')
    end
    message.save!
    original = message.attachments.order(:id).to_a
    missing = original.second.file.blob
    truncated = original.third.file.blob
    service.delete(missing.key)
    service.upload(truncated.key, StringIO.new('th'))
    conversation.update!(status: :resolved)

    fail_repair = true
    allow(service).to receive(:upload).and_wrap_original do |upload, key, io, **options|
      raise IOError, 'synthetic repair failure' if key == truncated.key && fail_repair

      upload.call(key, io, **options)
    end
    deliver(%w[first second third].map { |body| document(body) })
    expect(response).to have_http_status(:unprocessable_content)
    expect(missing.download).to eq('second')

    fail_repair = false
    replay = deliver(%w[first second third].map { |body| document(body) })
    expect(response).to have_http_status(:ok)
    expect(replay.fetch('id')).to eq(message.id)
    expect(replay.fetch('attachments').pluck('id')).to eq(original.map(&:id))
    expect(original.map { |item| item.file.download }).to eq(%w[first second third])
    expect(conversation.reload).to be_resolved
  end

  it 'preserves the deletion of a known media delivery' do
    first = deliver([document('revoked')])
    Message.find(first.fetch('id')).mark_deleted!

    replay = deliver([document('revoked')])
    expect(replay).to include('id' => first.fetch('id'), 'content_attributes' => a_hash_including('deleted' => true))
    expect(replay['attachments']).to be_blank
    expect(deliver(nil).fetch('id')).not_to eq(first.fetch('id'))
  end

  it 'rejects an incomplete direct upload until the signed blob is available' do
    body = 'direct upload'
    checksum = OpenSSL::Digest::MD5.base64digest(body)
    blob = ActiveStorage::Blob.create_before_direct_upload!(
      filename: 'document.txt', content_type: 'text/plain', byte_size: body.bytesize, checksum: checksum
    )
    deliver([blob.signed_id])
    expect(response).to have_http_status(:unprocessable_content)
    expect(conversation.messages.incoming).not_to exist

    service.upload(blob.key, StringIO.new(body), checksum: checksum)
    first = deliver([blob.signed_id])
    expect(response).to have_http_status(:ok)
    expect(conversation.messages.incoming.sole.attachments.sole.file.blob).to eq(blob)
    expect(deliver([blob.signed_id]).fetch('id')).to eq(first.fetch('id'))
  end

  context 'with overlapping requests' do
    self.use_transactional_tests = false

    after do
      perform_enqueued_jobs(only: ActiveStorage::PurgeJob)

      perform_enqueued_jobs(only: [ActiveStorage::PurgeJob, ActiveRecord::DestroyAssociationAsyncJob]) do
        conversation.destroy!
        account.contacts.destroy_all
        inbox.destroy!
        account.destroy!
        agent.destroy!
      end
    end

    it 'persists a single delivery even when both requests uploaded their file' do
      endpoint = url
      credentials = headers
      uploaded = Queue.new
      publish = Queue.new
      allow(service).to receive(:upload).and_wrap_original do |upload, key, io, **options|
        upload.call(key, io, **options)
        uploaded << true
        Timeout.timeout(15) { publish.pop }
      end

      requests = Array.new(2) do
        Concurrent::Promises.future do
          Rails.application.executor.wrap do
            session = ActionDispatch::Integration::Session.new(Rails.application)
            session.post endpoint, headers: credentials,
                                   params: { message_type: 'incoming', source_id: 'overlap-1', attachments: [document('overlap')] }
            [session.response.status, session.response.parsed_body.fetch('id')]
          end
        end
      end

      2.times { Timeout.timeout(15) { uploaded.pop } }
      expect(conversation.messages.incoming).not_to exist
      2.times { publish << true }
      results = requests.map { |request| request.value!(15) }
      message = conversation.messages.incoming.sole
      expect(results).to eq([[200, message.id], [200, message.id]])
      expect(message.attachments.sole.file.download).to eq('overlap')
      expect(ActiveStorage::PurgeJob).to have_been_enqueued.exactly(:once)
    ensure
      2.times { publish << true } if publish
      requests&.each { |request| request.wait(15) }
    end
  end
end
