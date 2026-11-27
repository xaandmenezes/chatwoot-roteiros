require 'rails_helper'
require Rails.root.join 'spec/mailers/administrator_notifications/shared/smtp_config_shared.rb'

RSpec.describe EmailDeliveryTestMailer do
  include_context 'with smtp config'

  let(:mail) { described_class.delivery_test('agent@example.com', 'Jane Agent').message }

  it 'sends a branded test email to the user' do
    expect(mail.to).to eq(['agent@example.com'])
    sender = Mail::Address.new(ApplicationMailer.default[:from])
    expect(mail[:from].addrs).to contain_exactly(have_attributes(address: sender.address, display_name: sender.display_name))
    expect(mail.subject).to eq('Test email from Porto Seguro Roteiros support')
    expect(mail.body.encoded).to include('Hi Jane Agent,')
    expect(mail.body.decoded).to include('check that emails from Porto Seguro Roteiros reach your inbox')
    document = Nokogiri::HTML(mail.body.decoded)
    expect(document.at_css('img[alt="Porto Seguro Roteiros"]')['src']).to end_with('/brand-assets/psr/logo.png')
    expect(document.at_css('a[href="https://www.portoseguroroteiros.com.br"]').text).to eq('Porto Seguro Roteiros')
  end

  it 'retains the configured brand and logo' do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with('BRAND_NAME', 'BRAND_URL', 'LOGO').and_return(
      { 'BRAND_NAME' => 'Acme & Co', 'BRAND_URL' => 'https://example.org', 'LOGO' => 'https://images.example.org/logo.png' }
    )

    expect(mail.subject).to eq('Test email from Acme & Co support')
    document = Nokogiri::HTML(mail.body.decoded)
    expect(document.at_css('img')['alt']).to eq('Acme & Co')
    expect(document.at_css('img')['src']).to eq('https://images.example.org/logo.png')
    expect(document.at_css('a[href="https://example.org"]').text).to eq('Acme & Co')
  end

  it 'greets by address when the name is blank' do
    expect(described_class.delivery_test('agent@example.com', '').message.body.encoded).to include('Hi agent@example.com,')
  end

  it 'does not send when SMTP is not configured' do
    with_modified_env('SMTP_ADDRESS' => nil) do
      expect(mail).to be_a(ActionMailer::Base::NullMail)
    end
  end
end
