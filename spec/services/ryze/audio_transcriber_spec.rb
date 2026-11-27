require 'rails_helper'

describe Ryze::AudioTranscriber do
  subject(:transcribe) { described_class.new.transcribe(blob) }

  let(:url) { 'http://ryze-transcriber:8080/inference' }
  let(:blob) { instance_double(ActiveStorage::Blob, byte_size: 12, content_type: 'audio/ogg; codecs=opus') }
  let(:audio) { Tempfile.new('test-recording') }

  before do
    audio.write('sample-audio')
    audio.rewind
    allow(blob).to receive(:open).and_yield(audio)
  end

  after { audio.close! }

  it 'uploads the stored audio with a neutral filename and requests Portuguese text' do
    stub_request(:post, url).with do |request|
      request.body.include?('filename="audio.ogg"') && request.body.include?('sample-audio') &&
        request.body.match?(/name="language".*?\r\n\r\npt\r\n/m)
    end.to_return(body: { text: "  Passeio em Trancoso.\n" }.to_json)
    expect(transcribe).to eq('Passeio em Trancoso.')
  end

  it 'skips audio above the upload limit before opening it' do
    allow(blob).to receive(:byte_size).and_return(25_000_001)
    expect(blob).not_to receive(:open)
    expect { transcribe }.to raise_error(described_class::UnsupportedAudio)
  end

  it 'flags a recording with no recognized speech' do
    stub_request(:post, url).to_return(body: { text: " \n" }.to_json)
    expect { transcribe }.to raise_error(described_class::UnsupportedAudio)
  end

  it 'treats an undecodable file as a terminal failure' do
    stub_request(:post, url).to_return(status: 500, body: '{"error":"FFmpeg conversion failed."}')
    expect { transcribe }.to raise_error(described_class::UnsupportedAudio)
  end

  it 'treats an unavailable server as retryable' do
    stub_request(:post, url).to_timeout
    expect { transcribe }.to raise_error(described_class::Error, /unavailable/i)
  end

  it 'rejects a malformed successful response' do
    stub_request(:post, url).to_return(body: '<html>Unavailable</html>')
    expect { transcribe }.to raise_error(described_class::Error, /response/i)
  end
end
