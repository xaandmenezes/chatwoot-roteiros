require 'rails_helper'

RSpec.describe Devise::Mailer do
  it 'carries the pending Shopify install redirect in the confirmation link' do
    user = create(:user, skip_confirmation: false)
    redirect_url = "settings/integrations/shopify?shopify_pending_install=#{'a' * 32}"
    mail = described_class
           .with(redirect_url: redirect_url)
           .confirmation_instructions(user, 'confirmation-token')

    expect(CGI.unescapeHTML(mail.body.to_s)).to include(
      "route_url=settings%2Fintegrations%2Fshopify%3Fshopify_pending_install%3D#{'a' * 32}"
    )
  end

  it 'carries the requested redirect in the password edit link' do
    user = create(:user)
    redirect_url = 'settings/billing?plan_handle=growth'
    mail = described_class
           .with(redirect_url: redirect_url, sso_account_id: '42')
           .reset_password_instructions(user, 'reset-token')

    document = Nokogiri::HTML(mail.body.decoded)
    action = document.css('a').find { |link| link.text == 'Change my password' }
    expect(action['href']).to include(
      '/app/auth/password/edit?reset_password_token=reset-token',
      'route_url=settings%2Fbilling%3Fplan_handle%3Dgrowth',
      'sso_account_id=42'
    )
    expect(document.at_css('img[alt="Porto Seguro Roteiros"]')).to be_present
  end
end
