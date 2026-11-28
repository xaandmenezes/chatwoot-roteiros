require 'rails_helper'

RSpec.describe Viari::NativeLaunch do
  let(:origin) { URI.parse('https://example.org') }

  it 'accepts only the native entry point and projects the public launch contract' do
    result = described_class.new(origin, { 'url' => 'https://example.org/atendimento/nativo?ticket=opaque', 'api_key' => 'secret' }).data
    expect(result).to eq('url' => 'https://example.org/atendimento/nativo?ticket=opaque', 'origin' => 'https://example.org')
  end

  it 'rejects credentials, altered ports, arbitrary paths and relative URLs' do
    urls = ['https://user@example.org/atendimento/nativo', 'https://example.org:444/atendimento/nativo',
            'https://example.org/settings', '/atendimento/nativo']
    urls.each do |url|
      expect { described_class.new(origin, { 'url' => url }).data }.to raise_error(Viari::Client::Unavailable)
    end
  end
end
