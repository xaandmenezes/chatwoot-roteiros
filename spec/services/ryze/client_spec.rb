require 'rails_helper'

RSpec.describe Ryze::Client do
  let(:limits) { described_class::ResponseLimits.new(deadline: 20.seconds.from_now, max_bytes: 8) }
  let(:client) { described_class.new(instance: 'test', token: 'test', limits: limits) }
  let(:http) { instance_double(Net::HTTP) }

  it 'stops consuming the response as soon as chunked bytes exceed the limit' do
    response = instance_double(Net::HTTPOK, code: '200')
    allow(Net::HTTP).to receive(:start).and_yield(http)
    allow(http).to receive(:request).and_yield(response)
    allow(response).to receive(:read_body) do |&consume|
      consume.call('12345')
      consume.call('6789')
      raise 'read past the limit'
    end
    expect { client.get('chat/base64', messageId: 'id') }.to raise_error(described_class::ConnectionError, /limit/)
  end

  it 'does not open another connection once the shared deadline is reached' do
    client
    travel 21.seconds do
      expect(Net::HTTP).not_to receive(:start)
      expect { client.post('chat/history', {}) }.to raise_error(described_class::ConnectionError)
    end
  end
end
