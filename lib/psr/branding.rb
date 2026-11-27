module Psr::Branding
  NAME = 'Porto Seguro Roteiros'.freeze
  THUMBNAIL = '/brand-assets/psr/icon-512.png'.freeze

  # Only replace upstream defaults in the agent and mailer presentation layers.
  # InstallationConfig also serves public widgets and help centers.
  DEFAULTS = {
    'INSTALLATION_NAME' => ['Chatwoot', NAME],
    'BRAND_NAME' => ['Chatwoot', NAME],
    'BRAND_URL' => ['https://www.chatwoot.com', 'https://www.portoseguroroteiros.com.br'],
    'LOGO' => ['/brand-assets/logo.svg', '/brand-assets/psr/logo.png'],
    'LOGO_DARK' => ['/brand-assets/logo_dark.svg', '/brand-assets/psr/logo-dark.png'],
    'LOGO_THUMBNAIL' => ['/brand-assets/logo_thumbnail.svg', THUMBNAIL]
  }.freeze

  def self.apply(config)
    branded = config.dup
    DEFAULTS.each do |key, (upstream, psr)|
      next unless config.key?(key)

      branded[key] = psr if config[key].nil? || config[key] == upstream
    end
    branded
  end

  def self.official_thumbnail?(config)
    config['LOGO_THUMBNAIL'] == THUMBNAIL
  end
end
