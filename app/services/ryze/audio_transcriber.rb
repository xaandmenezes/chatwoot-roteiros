require 'faraday/multipart'

class Ryze::AudioTranscriber
  class Error < StandardError; end
  class UnsupportedAudio < Error; end

  ENDPOINT = 'http://ryze-transcriber:8080/inference'.freeze
  MAX_BYTES = 25_000_000
  AUDIO_EXTENSIONS = {
    'audio/ogg' => 'ogg', 'audio/opus' => 'opus', 'audio/webm' => 'webm',
    'audio/mpeg' => 'mp3', 'audio/mp3' => 'mp3', 'audio/x-mp3' => 'mp3',
    'audio/mp4' => 'm4a', 'audio/x-m4a' => 'm4a', 'audio/aac' => 'aac',
    'audio/wav' => 'wav', 'audio/x-wav' => 'wav', 'audio/flac' => 'flac'
  }.freeze

  def transcribe(blob)
    raise UnsupportedAudio, 'Audio exceeds size limit' if blob.byte_size > MAX_BYTES

    mime = blob.content_type.to_s.partition(';').first.strip.downcase
    extension = AUDIO_EXTENSIONS.fetch(mime) { raise UnsupportedAudio, 'Unsupported audio format' }
    response = blob.open do |file|
      audio = Faraday::Multipart::FilePart.new(file, mime, "audio.#{extension}")
      connection.post(ENDPOINT, file: audio, language: 'pt', response_format: 'json')
    end
    validate_response!(response)
    extract_text(response.body)
  rescue Faraday::Error
    raise Error, 'Transcriber unavailable'
  end

  private

  def connection
    Faraday.new do |client|
      client.proxy = nil
      client.request :multipart
      client.options.open_timeout = 5
      client.options.timeout = 180
    end
  end

  def validate_response!(response)
    raise UnsupportedAudio, 'Audio rejected' if [400, 413, 415, 422].include?(response.status)
    raise UnsupportedAudio, 'Audio could not be decoded' if response.status == 500 && response.body == '{"error":"FFmpeg conversion failed."}'

    raise Error, "Transcriber HTTP #{response.status}" unless response.success?
  end

  def extract_text(body)
    payload = JSON.parse(body)
    raise Error, 'Invalid transcription response' unless payload.is_a?(Hash) && payload['text'].is_a?(String)

    payload['text'].strip.presence || raise(UnsupportedAudio, 'No speech recognized')
  rescue JSON::ParserError
    raise Error, 'Invalid transcription response'
  end
end
