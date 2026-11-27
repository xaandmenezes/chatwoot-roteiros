class Ryze::AudioTranscriptionJob < ApplicationJob
  queue_as :ryze_audio_transcription
  discard_on ActiveRecord::RecordNotFound

  def perform(transcription_id = nil)
    return unless ENV['RYZE_AUDIO_TRANSCRIPTION_ENABLED'] == 'true'

    transcription = transcription_id ? Ryze::AudioTranscription.find_by(id: transcription_id) : Ryze::AudioTranscription.next_due
    process(transcription, recovery: transcription_id.nil?) if transcription
  end

  private

  def process(transcription, recovery:)
    eligible = Ryze::AudioTranscription.enabled_for_attachment?(transcription.attachment)
    return unless eligible || recovery

    attempt = transcription.claim!
    return unless attempt

    eligible ? transcribe(transcription, attempt) : transcription.finish!(attempt, :failed)
  end

  def transcribe(transcription, attempt)
    blob = transcription.attachment.file.blob
    raise ActiveStorage::FileNotFoundError unless blob

    text = Ryze::AudioTranscriber.new.transcribe(blob)
    transcription.finish!(attempt, :completed, text: text)
  rescue Ryze::AudioTranscriber::UnsupportedAudio
    transcription.finish!(attempt, :failed)
  rescue Ryze::AudioTranscriber::Error, ActiveStorage::FileNotFoundError, ActiveStorage::IntegrityError
    transcription.finish!(attempt, :pending)
  rescue ActiveRecord::RecordInvalid => e
    raise unless e.record == transcription && transcription.errors.of_kind?(:text, :too_long)

    transcription.reload.finish!(attempt, :failed)
  end
end
