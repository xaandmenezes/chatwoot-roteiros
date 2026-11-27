require 'rails_helper'

RSpec.describe Ryze::HistoricalSync do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:contact) { create(:contact, account: account) }
  let(:chat_jid) { '5511999999999@s.whatsapp.net' }
  let(:conversation) do
    create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      additional_attributes: { 'whatsapp_jid' => chat_jid },
      status: :resolved,
      last_activity_at: 1.day.ago
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
        expect(conversation.last_activity_at.to_i).to eq(1.day.ago.to_i)
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

      it 'fetches base64 media and attaches it when within size limit' do
        raw_history = {
          success: true,
          messages: [
            {
              id: img_id,
              timestamp: 1.hour.ago.iso8601,
              type: 'image',
              mediaSize: 1024,
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
        expect(msg.content).to eq('[Mídia histórica indisponível]')
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
        expect(msg.content).to eq('[Mídia histórica indisponível]')
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
