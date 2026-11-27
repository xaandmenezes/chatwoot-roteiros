require 'rails_helper'

describe 'Dashboard branding', type: :request do
  let(:installation_name) { 'Chatwoot' }
  let(:display_manifest) { true }
  let(:thumbnail) { '/brand-assets/logo_thumbnail.svg' }

  let(:bootstrap_config) { JSON.parse(response.body.match(/window\.globalConfig = (.+)$/)[1]) }

  before do
    allow(GlobalConfig).to receive(:get).and_wrap_original do |original, *keys|
      config = original.call(*keys)
      next config unless keys.include?('LOGO_THUMBNAIL')

      config.merge('DISPLAY_MANIFEST' => display_manifest, 'LOGO_THUMBNAIL' => thumbnail, 'INSTALLATION_NAME' => installation_name)
    end
  end

  ['/app/login', '/app/accounts/1/dashboard'].each do |path|
    it "serves the PSR brand on #{path}" do
      get path

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)
      expect(document.at_css('title').text.strip).to eq('Porto Seguro Roteiros')
      expect(document.at_css('html')['class']).to include('psr-brand')
      expect(document.at_css('link[rel="manifest"]')['href']).to eq('/brand-assets/psr/manifest.json')
      expect(document.at_css('link[rel="apple-touch-icon"]')['href']).to eq('/brand-assets/psr/icon-180.png')
      expect(document.at_css('link[sizes="32x32"]')['href']).to eq('/brand-assets/psr/favicon-32x32.png')
      expect(document.at_css('link[sizes="32x32"]')['data-favicon-badge']).to eq('/brand-assets/psr/favicon-badge-32x32.png')
    end
  end

  it 'exposes original branding for installation policies and the public widget preview' do
    get '/app/accounts/1/dashboard'

    expect(bootstrap_config.fetch('INSTALLATION_BRANDING')).to include('INSTALLATION_NAME' => 'Chatwoot', 'LOGO_THUMBNAIL' => thumbnail)
  end

  context 'when an installation already has its own name' do
    let(:installation_name) { 'Agência' }

    it 'preserves its name and original installation policy' do
      get '/app/login'

      expect(Nokogiri::HTML(response.body).at_css('title').text.strip).to eq('Agência')
      expect(bootstrap_config.fetch('INSTALLATION_BRANDING').fetch('INSTALLATION_NAME')).to eq('Agência')
    end
  end

  context 'when the optional manifest is disabled' do
    let(:display_manifest) { false }

    it 'keeps the branded favicon' do
      get '/app/login'

      document = Nokogiri::HTML(response.body)
      expect(document.at_css('link[rel="manifest"]')).to be_nil
      expect(document.at_css('link[sizes="32x32"]')['href']).to eq('/brand-assets/psr/favicon-32x32.png')
    end
  end

  context 'with a custom thumbnail' do
    let(:thumbnail) { '/custom-company-icon.png' }
    let(:display_manifest) { false }

    it 'renders the configured icon without applying the PSR palette' do
      get '/app/login'

      document = Nokogiri::HTML(response.body)
      expect(document.at_css('html')['class']).not_to include('psr-brand')
      expect(document.at_css('link[rel="icon"]')['href']).to eq(thumbnail)
    end
  end
end
