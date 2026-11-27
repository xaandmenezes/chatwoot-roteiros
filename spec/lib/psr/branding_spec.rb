require 'rails_helper'

describe Psr::Branding do
  describe '.apply' do
    it 'brands seeded and unseeded configurations for the dashboard and mailers' do
      defaults = ConfigLoader.new.general_configs.to_h { |entry| [entry.fetch('name'), entry['value']] }
      expected = {
        'INSTALLATION_NAME' => 'Porto Seguro Roteiros', 'BRAND_NAME' => 'Porto Seguro Roteiros',
        'BRAND_URL' => 'https://www.portoseguroroteiros.com.br',
        'LOGO' => '/brand-assets/psr/logo.png', 'LOGO_DARK' => '/brand-assets/psr/logo-dark.png',
        'LOGO_THUMBNAIL' => '/brand-assets/psr/icon-512.png'
      }

      expect(described_class.apply(defaults)).to include(expected)
      expect(described_class.apply(expected.transform_values { nil })).to eq(expected)
    end

    it 'respects configured values and leaves the input used by other surfaces intact' do
      config = { 'LOGO' => '', 'LOGO_DARK' => '/custom/logo.svg', 'DISPLAY_MANIFEST' => false, 'BRAND_NAME' => 'Chatwoot' }.freeze

      expect(described_class.apply(config)).to eq(config.merge('BRAND_NAME' => 'Porto Seguro Roteiros'))
      expect(config.fetch('BRAND_NAME')).to eq('Chatwoot')
    end
  end
end
