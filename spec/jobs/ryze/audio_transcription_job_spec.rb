require 'rails_helper'

RSpec.describe Ryze::AudioTranscriptionJob do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:transcriber) { instance_double(Ryze::AudioTranscriber) }

  around do |example|
    with_modified_env RYZE_AUDIO_TRANSCRIPTION_ENABLED: 'true', RYZE_INBOX_ID: inbox.id.to_s,
                      RYZE_AUDIO_TRANSCRIPTION_CONVERSATION_ID: conversation.display_id.to_s do
      example.run
    end
  end

  before { allow(Ryze::AudioTranscriber).to receive(:new).and_return(transcriber) }

  def attach_audio(message, filename, content_type)
    message.attachments.build(
      account: account,
      file_type: :audio,
      file: { io: StringIO.new('synthetic audio'), filename: filename, content_type: content_type, identify: false }
    )
  end

  def save_audio(message_type: :incoming, private: false, historical: false, target: conversation)
    message = build(:message, account: account, inbox: target.inbox, conversation: target, message_type: message_type, private: private)
    message.historical_import = historical
    attachment = attach_audio(message, 'sample.ogg', 'audio/ogg')
    message.save!
    attachment
  end

  it 'stores the text against each incoming, microphone and MP3 attachment and ignores repeated jobs' do
    incoming = save_audio
    outgoing = build(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing)
    microphone = attach_audio(outgoing, 'recording.webm', 'audio/webm')
    mp3 = attach_audio(outgoing, 'passeio.mp3', 'audio/mpeg')
    outgoing.save!

    attachments_and_phrases = { incoming => 'Praia do Espelho', microphone => 'Arraial d’Ajuda', mp3 => 'Trancoso' }
    attachments_and_phrases.each do |attachment, phrase|
      expect(transcriber).to receive(:transcribe).with(attachment.file.blob).once.and_return(phrase)
      record = attachment.reload.ryze_audio_transcription
      expect(record).to be_pending
      expect { 2.times { described_class.perform_now(record.id) } }.not_to change(Message, :count)
      expect(record.reload).to have_attributes(status: 'completed', text: phrase)
      expect(attachment.reload.file.download).to eq('synthetic audio')
      expect(attachment.push_event_data.values).not_to include(phrase)
    end
  end

  it 'requires explicit scope before processing the whole inbox' do
    with_modified_env RYZE_AUDIO_TRANSCRIPTION_CONVERSATION_ID: '' do
      expect { save_audio }.not_to change(Ryze::AudioTranscription, :count)
      expect(Ryze::AudioTranscription.next_due).to be_nil
    end
    with_modified_env RYZE_AUDIO_TRANSCRIPTION_CONVERSATION_ID: 'all' do
      expect { save_audio }.to change(Ryze::AudioTranscription, :count).by(1)
      expect(Ryze::AudioTranscription.next_due).to be_pending
    end
  end

  it 'omits private notes, historical messages and conversations outside the configured pilot' do
    other = create(:conversation, account: account, inbox: inbox)
    expect do
      save_audio(message_type: :outgoing, private: true)
      save_audio(historical: true)
      save_audio(target: other)
    end.not_to change(Ryze::AudioTranscription, :count)
  end

  it 'treats calls to a permanently rejected file as failed while preserving the attachment' do
    attachment = save_audio
    record = attachment.reload.ryze_audio_transcription
    expect(transcriber).to receive(:transcribe).once.and_raise(Ryze::AudioTranscriber::UnsupportedAudio)
    expect { 2.times { described_class.perform_now(record.id) } }.not_to change(Message, :count)
    expect(record.reload).to have_attributes(status: 'failed', text: nil, attempts: 1)
    expect(attachment.file.download).to eq('synthetic audio')
  end

  it 'recovers transient failures and stops retrying after a bounded number of attempts' do
    record = save_audio.reload.ryze_audio_transcription
    expect(transcriber).to receive(:transcribe).exactly(3).times.and_raise(Ryze::AudioTranscriber::Error)
    described_class.perform_now(record.id)
    expect(record.reload).to be_pending
    2.times do
      travel_to(record.reload.next_attempt_at + 1.second) { described_class.perform_now(record.id) }
    end
    expect(record.reload).to have_attributes(status: 'failed', text: nil, attempts: 3)
  end

  it 'lets an expired claim recover and ignores a stale worker completion' do
    record = save_audio.reload.ryze_audio_transcription
    first_attempt = record.claim!
    expect(first_attempt).to eq(1)
    expect(described_class.new.perform(record.id)).to be_nil
    expect(transcriber).to receive(:transcribe).once.and_return('Caraíva')
    travel_to(record.reload.next_attempt_at + 1.second) { described_class.perform_now(record.id) }
    record.finish!(first_attempt, :completed, text: 'stale')
    expect(record.reload).to have_attributes(status: 'completed', text: 'Caraíva', attempts: 2)
  end

  it 'recovers a queued record from a failed dispatch and processes only one due item per sweep' do
    allow(described_class).to receive(:perform_later).and_raise(ActiveJob::EnqueueError)
    first = save_audio.reload.ryze_audio_transcription
    second = save_audio.reload.ryze_audio_transcription
    expect(transcriber).to receive(:transcribe).with(first.attachment.file.blob).once.and_return('Trancoso')

    described_class.perform_now

    expect(first.reload).to have_attributes(status: 'completed', text: 'Trancoso')
    expect(second.reload).to have_attributes(status: 'pending', attempts: 0)
  end

  it 'marks an overlong result as failed without repeating inference' do
    record = save_audio.reload.ryze_audio_transcription
    expect(transcriber).to receive(:transcribe).once.and_return('a' * (ApplicationRecord::MAX_TEXT_COLUMN_LENGTH + 1))

    2.times { described_class.perform_now(record.id) }

    expect(record.reload).to have_attributes(status: 'failed', attempts: 1, text: nil)
  end

  it 'moves on when a queued attachment becomes private before the recovery sweep' do
    original = save_audio
    record = original.reload.ryze_audio_transcription
    original.message.update!(private: true)
    next_record = save_audio.reload.ryze_audio_transcription
    expect(transcriber).to receive(:transcribe).with(next_record.attachment.file.blob).once.and_return('Caraíva')

    2.times { described_class.perform_now }

    expect(record.reload).to have_attributes(status: 'failed', text: nil)
    expect(next_record.reload).to have_attributes(status: 'completed', text: 'Caraíva')
  end

  it 'recovers within the current pilot when the configured conversation changes' do
    previous = save_audio.reload.ryze_audio_transcription
    other = create(:conversation, account: account, inbox: inbox)
    with_modified_env RYZE_AUDIO_TRANSCRIPTION_CONVERSATION_ID: other.display_id.to_s do
      current = save_audio(target: other).reload.ryze_audio_transcription
      expect(transcriber).to receive(:transcribe).with(current.attachment.file.blob).once.and_return('Trancoso')

      described_class.perform_now

      expect(previous.reload).to have_attributes(status: 'pending', attempts: 0)
      expect(current.reload).to have_attributes(status: 'completed', text: 'Trancoso')
    end
  end

  it 'fails closed when the pilot ID is invalid' do
    with_modified_env RYZE_AUDIO_TRANSCRIPTION_CONVERSATION_ID: ' ' do
      expect { save_audio }.not_to change(Ryze::AudioTranscription, :count)
    end
  end

  it 'keeps the transcription tied to the lifetime of the attachment' do
    attachment = save_audio
    record = attachment.reload.ryze_audio_transcription

    expect { attachment.destroy! }.to change { Ryze::AudioTranscription.exists?(record.id) }.from(true).to(false)
  end

  it 'skips processing when the pilot is switched off while work is queued' do
    record = save_audio.reload.ryze_audio_transcription
    expect(transcriber).not_to receive(:transcribe)
    with_modified_env RYZE_AUDIO_TRANSCRIPTION_ENABLED: 'false' do
      described_class.perform_now(record.id)
    end
    expect(record.reload).to have_attributes(status: 'pending', attempts: 0)
  end
end
