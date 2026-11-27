require 'rails_helper'

RSpec.describe Ryze::HistoricalSync do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:contact) { create(:contact, account: account) }
  let(:chat_jid) { '5511999999999@s.whatsapp.net' }
  let(:original_activity_at) { 1.day.ago.change(usec: 0) }
  let(:conversation) do
    create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      additional_attributes: { 'whatsapp_jid' => chat_jid },
      status: :resolved,
      last_activity_at: original_activity_at
    )
  end
  let(:client) { instance_double(Ryze::Client) }

  around do |example|
    with_modified_env(
      RYZE_INSTANCE_NAME: 'test-instance',
      RYZE_EDIT_API_TOKEN: 'test-token',
      RYZE_WEBHOOK_SECRET: 'test-secret',
      RYZE_INBOX_ID: inbox.id.to_s,
      RYZE_PILOT_CHAT_JID: chat_jid,
      RYZE_EDIT_CONVERSATION_ID: conversation.reload.display_id.to_s,
      RYZE_HISTORY_SYNC_ENABLED: 'true'
    ) { example.run }
  end

  def success_response(body)
    instance_double(Net::HTTPSuccess, code: '200', body: body.to_json)
  end

  def error_response(code, body = {})
    instance_double(Net::HTTPResponse, code: code.to_s, body: body.to_json)
  end

  describe '.enabled?' do
    it 'returns true when pilot conversation and env enabled' do
      expect(described_class.enabled?(conversation)).to be true
    end

    it 'returns false when RYZE_HISTORY_SYNC_ENABLED is false' do
      with_modified_env(RYZE_HISTORY_SYNC_ENABLED: 'false') do
        expect(described_class.enabled?(conversation)).to be false
      end
    end

    it 'returns false for non-pilot conversation' do
      non_pilot = create(:conversation, account: account, inbox: inbox, additional_attributes: { 'whatsapp_jid' => 'other@s.whatsapp.net' })
      expect(described_class.enabled?(non_pilot)).to be false
    end
  end

  describe '#perform' do
    subject(:sync) { described_class.new(conversation: conversation, before: before_param, client: client) }

    let(:before_param) { nil }

    it 'raises ArgumentError if historical sync is not enabled' do
      with_modified_env(RYZE_HISTORY_SYNC_ENABLED: 'false') do
        expect { sync.perform }.to raise_error(ArgumentError, /not enabled/)
      end
    end

    it 'raises ArgumentError if conversation lacks valid whatsapp_jid' do
      conversation.update!(additional_attributes: {})
      expect { sync.perform }.to raise_error(ArgumentError, /not enabled/)
    end

    it 'does not import Ryze history that belongs to an earlier or later restricted conversation' do
      from = conversation.created_at
      to = from + 2.hours
      create(:conversation, account: account, inbox: inbox, contact: contact, created_at: from - 1.day)
      create(:conversation, account: account, inbox: inbox, contact: contact, created_at: to)
      history = {
        success: true,
        messages: [
          { id: 'past', timestamp: (from - 1.minute).iso8601(6), type: 'text', content: 'Previous conversation' },
          { id: 'current', timestamp: (from + 1.minute).iso8601(6), type: 'text', content: 'This conversation' },
          { id: 'next', timestamp: to.iso8601(6), type: 'text', content: 'Next conversation' }
        ]
      }
      allow(client).to receive(:post)
        .with('chat/history', hash_including(from: from.utc.iso8601(6), to: to.utc.iso8601(6)))
        .and_return(success_response(history))

      with_modified_env(PSR_RESTRICTED_INBOX_ID: inbox.id.to_s) do
        expect(sync.perform.imported_messages.map(&:source_id)).to eq(['current'])
        expect(conversation.messages.history_imports.pluck(:source_id)).to eq(['current'])
      end
    end

    context 'with text messages' do
      let(:msg_time1) { 2.days.ago.change(usec: 0) }
      let(:msg_time2) { 3.days.ago.change(usec: 0) }
      let(:raw_history) do
        {
          success: true,
          messages: [
            {
              id: 'msg-1',
              timestamp: msg_time1.iso8601,
              type: 'text',
              content: 'Recent historical text',
              fromMe: true
            },
            {
              id: 'msg-2',
              timestamp: msg_time2.to_i,
              type: 'text',
              content: 'Older incoming text',
              fromMe: false
            }
          ]
        }
      end

      before do
        allow(client).to receive(:post).with('chat/history', anything).and_return(success_response(raw_history))
      end

      it 'maps outgoing and incoming fields accurately' do
        result = sync.perform
        older = result.imported_messages.first
        newer = result.imported_messages.second

        expect(older.source_id).to eq('msg-2')
        expect(older.incoming?).to be true
        expect(older.sender).to eq(contact)
        expect(older.status).to eq('sent')
        expect(newer.source_id).to eq('msg-1')
        expect(newer.outgoing?).to be true
        expect(newer.status).to eq('delivered')
      end

      it 'attaches historical attributes and sorts messages chronologically' do
        result = sync.perform
        older = result.imported_messages.first
        newer = result.imported_messages.second

        expect(older.content_attributes['external_created_at']).to eq(msg_time2.to_i)
        expect(older.additional_attributes['ryze_historical_sync']).to be true
        expect(newer.content_attributes['external_echo']).to be true
        expect(result.has_more).to be false
        expect(result.next_before).to be_nil
      end

      it 'preserves conversation status and does not reopen or update last_activity_at when importing older messages' do
        expect do
          sync.perform
        end.not_to have_enqueued_job(SendReplyJob)

        expect(conversation.reload.status).to eq('resolved')
        expect(conversation.last_activity_at).to eq(original_activity_at)
      end

      it 'never moves activity backwards when another writer has advanced it' do
        recent = Time.current.change(usec: 0)
        conversation.update!(last_activity_at: 5.days.ago)
        Conversation.find(conversation.id).update!(last_activity_at: recent)
        sync.perform
        expect(conversation.reload.last_activity_at).to eq(recent)
      end

      it 'excludes imported messages from unread counts even before the first read' do
        sync.perform
        [nil, 1.year.ago].each do |seen|
          conversation.update!(agent_last_seen_at: seen, assignee_last_seen_at: seen)
          expect(conversation.unread_incoming_messages).to be_empty
          expect(conversation.assignee_unread_messages.incoming).to be_empty
        end
      end
    end

    context 'with duplicates and overlap pagination' do
      let(:t1) { 5.days.ago.change(usec: 0) }
      let(:t2) { 6.days.ago.change(usec: 0) }
      let(:t3) { 7.days.ago.change(usec: 0) }
      let(:before_param) { t1.to_i }

      before do
        # Existing message in database
        create(
          :message,
          conversation: conversation,
          account: account,
          inbox: inbox,
          source_id: 'existing-id',
          created_at: t1
        )
      end

      it 'deduplicates against database messages and advances pages' do
        # Page 1 returns 50 items: all are duplicates already in db
        page1_items = Array.new(50) do |i|
          {
            id: i.zero? ? 'existing-id' : "seen-in-page1-#{i}",
            timestamp: (t1 - (i + 1).minutes).iso8601,
            type: 'text',
            content: "Dup #{i}",
            fromMe: false
          }
        end
        # Pretend they are all already in db or duplicates
        page1_items.each do |item|
          create(
            :message,
            conversation: conversation,
            account: account,
            inbox: inbox,
            source_id: item[:id],
            created_at: Time.zone.parse(item[:timestamp])
          )
        end

        page2_items = [
          {
            id: 'new-id-page2',
            timestamp: t3.iso8601,
            type: 'text',
            content: 'Found in page 2',
            fromMe: false
          }
        ]

        expect(client).to receive(:post).with('chat/history', hash_including(count: 50)).and_return(
          success_response({ success: true, messages: page1_items }),
          success_response({ success: true, messages: page2_items })
        )

        result = sync.perform
        expect(result.imported_messages.map(&:source_id)).to eq(['new-id-page2'])
        expect(result.has_more).to be false
      end
    end

    context 'with skipped types' do
      let(:raw_history) do
        {
          success: true,
          messages: [
            { id: 'react-1', timestamp: 1.day.ago.iso8601, type: 'reaction', content: '👍' },
            { id: 'edit-1', timestamp: 1.day.ago.iso8601, type: 'message_edit', content: 'new text' },
            { id: 'revoke-1', timestamp: 1.day.ago.iso8601, type: 'message_revoke' },
            { id: 'protocol-1', timestamp: 1.day.ago.iso8601, type: 'protocol_message' }
          ]
        }
      end

      before do
        allow(client).to receive(:post).with('chat/history', anything).and_return(success_response(raw_history))
      end

      it 'filters out reaction, edit, revoke, and protocol messages' do
        result = sync.perform
        expect(result.imported_messages).to be_empty
      end
    end

    context 'with media attachments' do
      let(:img_id) { 'img-123' }
      let(:base64_data) { Base64.encode64('fake-image-binary-data') }
      let(:media_item) { { id: img_id, type: 'image', timestamp: 2.days.ago.iso8601, mediaSize: 22, mimeType: 'image/jpeg' } }
      let(:download) { success_response(success: true, base64: base64_data) }

      def deliver_live(with_file:)
        params = { message_type: 'incoming', source_id: img_id, content: 'Live caption' }
        if with_file
          blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('live file'), filename: 'live.txt', content_type: 'text/plain')
          params[:attachments] = [blob.signed_id]
        end
        Messages::MessageBuilder.new(nil, conversation, params).perform(replay_incoming_attachments: true)
      end

      [true, false].each do |with_file|
        it "preserves the original live delivery (file=#{with_file}) when history arrives later" do
          live = deliver_live(with_file: with_file)
          allow(client).to receive(:post).and_return(success_response(success: true, messages: [media_item]))
          expect(sync.perform.imported_messages).to be_empty
          expect(conversation.messages.where(source_id: img_id).sole).to eq(live)
          expect(live.reload).not_to be_historical_import
          expect(live.attachments.size).to eq(with_file ? 1 : 0)
        end

        [true, false].each do |downloaded|
          it "reuses an imported row (downloaded=#{downloaded}) on live delivery (file=#{with_file})" do
            allow(client).to receive(:post).and_return(success_response(success: true, messages: [media_item]))
            allow(client).to receive(:get).and_return(downloaded ? download : error_response(404))
            imported = sync.perform.imported_messages.sole
            expect(deliver_live(with_file: with_file)).to eq(imported)
            expect(deliver_live(with_file: with_file)).to eq(imported)
            expect(conversation.messages.where(source_id: img_id).sole).to eq(imported)
            files = imported.reload.attachments
            if downloaded || with_file
              expect(files.sole.file.download).to eq(downloaded ? 'fake-image-binary-data' : 'live file')
              expect(imported.additional_attributes).not_to have_key('ryze_history_pending_media')
            else
              expect(files).to be_empty
              expect(imported.additional_attributes).to have_key('ryze_history_pending_media')
            end
          end
        end
      end

      it 'limits downloads across a full import' do
        items = Array.new(12) { |i| media_item.merge(id: "image-#{i}") }
        allow(client).to receive(:post).and_return(success_response(success: true, messages: items))
        allow(client).to receive(:get).and_return(download)
        expect(sync.perform.imported_messages.size).to eq(12)
        expect(client).to have_received(:get).exactly(4).times
        expect(conversation.attachments.count).to eq(4)
      end

      it 'resumes the same page without a gap when the import deadline interrupts it' do
        freeze_time do
          items = [media_item, { id: 'later-in-page', type: 'text', timestamp: 1.day.ago.iso8601, content: 'Not skipped' }]
          allow(client).to receive(:post).and_return(success_response(success: true, messages: items))
          allow(client).to receive(:get) do
            travel 21.seconds
            download
          end
          first = sync.perform
          expect(first.imported_messages.map(&:source_id)).to eq([img_id])
          expect(first.has_more).to be(true)
          expect(first.next_before).to be >= Time.iso8601(items.last[:timestamp]).to_i

          allow(client).to receive(:get).and_return(download)
          retry_run = described_class.new(conversation: conversation.reload, client: client, before: first.next_before).perform
          expect(retry_run.imported_messages.map(&:source_id)).to eq(['later-in-page'])
          expect(retry_run.has_more).to be(false)
        end
      end

      it 'does not attach divergent or oversized decoded media, but imports the messages' do
        stub_const('Ryze::HistoricalSync::MediaAttacher::MAX_MEDIA_BYTES', 16)
        items = [media_item.merge(mediaSize: 8), media_item.merge(id: 'oversized', mediaSize: nil)]
        allow(client).to receive(:post).and_return(success_response(success: true, messages: items))
        allow(client).to receive(:get).and_return(success_response(success: true, base64: Base64.strict_encode64('abc')), download)
        expect(sync.perform.imported_messages.size).to eq(2)
        expect(conversation.attachments).to be_empty
      end

      it 'repairs an earlier placeholder even after the history cursor has advanced' do
        first_page = success_response(success: true, messages: [media_item])
        allow(client).to receive(:post).and_return(first_page, success_response(success: true, messages: []))
        allow(client).to receive(:get).and_return(error_response(404), download)
        message = sync.perform.imported_messages.sole
        expect(message.attachments).to be_empty
        result = described_class.new(conversation: conversation.reload, client: client).perform
        expect(result.imported_messages).to be_empty
        expect(message.reload.attachments.sole.file.download).to eq('fake-image-binary-data')
        expect(message.content).to be_blank
      end

      it 'deduplicates two overlapping imports when the second finishes during the first download' do
        allow(client).to receive(:post).and_return(success_response(success: true, messages: [media_item]))
        concurrent_client = instance_double(Ryze::Client, post: success_response(success: true, messages: [media_item]), get: download)
        allow(client).to receive(:get) do
          other = described_class.new(conversation: Conversation.find(conversation.id), client: concurrent_client)
          expect(other.perform.imported_messages.size).to eq(1)
          download
        end
        expect(sync.perform.imported_messages).to be_empty
        expect(conversation.messages.where(source_id: img_id).sole.attachments.size).to eq(1)
      end

      it 'persists a repairable placeholder if storage fails after the download' do
        allow(client).to receive(:post).and_return(success_response(success: true, messages: [media_item]))
        allow(client).to receive(:get).and_return(download)
        allow(ActiveStorage::Blob.service).to receive(:upload).and_raise(IOError, 'storage unavailable')
        expect { sync.perform }.to have_enqueued_job(ActiveStorage::PurgeJob)
        message = conversation.messages.find_by!(source_id: img_id)
        expect(message.attachments).to be_empty
        expect(message.content).to eq('[Historical media unavailable]')
      end

      it 'fetches base64 media and attaches it when within size limit' do
        raw_history = {
          success: true,
          messages: [
            {
              id: img_id,
              timestamp: 1.hour.ago.iso8601,
              type: 'image',
              mediaSize: 22,
              mimeType: 'image/jpeg',
              fileName: 'photo.jpg',
              caption: 'Nice picture'
            }
          ]
        }
        allow(client).to receive(:post).with('chat/history', anything).and_return(success_response(raw_history))
        expect(client).to receive(:get).with('chat/base64', messageId: img_id).and_return(
          success_response({ success: true, base64: base64_data, mime_type: 'image/jpeg; codecs=something' })
        )

        result = sync.perform
        msg = result.imported_messages.first
        expect(msg).to be_present
        expect(msg.attachments.first&.file&.content_type).to eq('image/jpeg')
        expect(msg.content).to eq('Nice picture')
        expect(msg.attachments.size).to eq(1)
        expect(msg.attachments.first.file_type).to eq('image')
        expect(msg.attachments.first.file).to be_attached
      end

      it 'falls back gracefully with placeholder text on 404/failure' do
        raw_history = {
          success: true,
          messages: [
            {
              id: img_id,
              timestamp: 1.hour.ago.iso8601,
              type: 'image',
              mediaSize: 1024,
              mimeType: 'image/jpeg'
            }
          ]
        }
        allow(client).to receive(:post).with('chat/history', anything).and_return(success_response(raw_history))
        expect(client).to receive(:get).with('chat/base64', messageId: img_id).and_return(
          error_response(404, { success: false, error: 'Not found' })
        )

        result = sync.perform
        msg = result.imported_messages.first
        expect(msg).to be_present
        expect(msg.content).to eq('[Historical media unavailable]')
        expect(msg.attachments).to be_empty
      end

      it 'does not request base64 for media exceeding MAX_MEDIA_BYTES' do
        raw_history = {
          success: true,
          messages: [
            {
              id: 'huge-video',
              timestamp: 1.hour.ago.iso8601,
              type: 'video',
              mediaSize: 20.megabytes
            }
          ]
        }
        allow(client).to receive(:post).with('chat/history', anything).and_return(success_response(raw_history))
        expect(client).not_to receive(:get)

        result = sync.perform
        msg = result.imported_messages.first
        expect(msg.content).to eq('[Historical media unavailable]')
        expect(msg.attachments).to be_empty
      end
    end

    context 'with upstream errors' do
      it 'raises RateLimitError on 429' do
        allow(client).to receive(:post).with('chat/history', anything).and_return(error_response(429, { error: 'Rate limit' }))
        expect { sync.perform }.to raise_error(Ryze::HistoricalSync::RateLimitError)
      end

      it 'raises UpstreamError on 500' do
        allow(client).to receive(:post).with('chat/history', anything).and_return(error_response(500, { error: 'Internal server error' }))
        expect { sync.perform }.to raise_error(Ryze::HistoricalSync::UpstreamError)
      end

      it 'raises UpstreamError on success: false' do
        allow(client).to receive(:post).with('chat/history', anything).and_return(success_response({ success: false, error: 'Bad query' }))
        expect { sync.perform }.to raise_error(Ryze::HistoricalSync::UpstreamError)
      end

      it 'raises UpstreamError on Ryze::Client::ConnectionError' do
        allow(client).to receive(:post).with('chat/history', anything).and_raise(Ryze::Client::ConnectionError, 'Timeout')
        expect { sync.perform }.to raise_error(Ryze::HistoricalSync::UpstreamError, /Could not reach Ryze/)
      end
    end
  end
end
