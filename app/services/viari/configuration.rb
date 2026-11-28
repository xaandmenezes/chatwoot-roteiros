class Viari::Configuration
  attr_reader :origin, :api_key, :namespace

  def self.for(account)
    entry = Viari::Settings.new(account).entry
    new(entry) if entry
  rescue TypeError, KeyError, ArgumentError, JSON::ParserError, URI::InvalidURIError, ActiveSupport::MessageEncryptor::InvalidMessage
    Rails.logger.warn("Viari configuration unavailable for account #{account.id}")
    nil
  end

  def initialize(entry)
    @origin = URI.parse(entry.fetch('origin'))
    @api_key = entry.fetch('api_key')
    @actors = entry.fetch('actors')
    @namespace = entry.fetch('namespace')
    local = (Rails.env.development? || Rails.env.test?) && %w[viari host.docker.internal localhost 127.0.0.1].include?(origin.host)
    valid_scheme = origin.is_a?(URI::HTTPS) || (local && origin.is_a?(URI::HTTP))
    raise ArgumentError, 'Invalid Viari origin' unless valid_scheme && origin.host.present? && origin.userinfo.nil? &&
                                                       ['', '/'].include?(origin.path) && origin.query.nil? && origin.fragment.nil?
    raise ArgumentError, 'Invalid Viari configuration' if api_key.blank? || namespace.blank? || signing_secret.bytesize < 32
  end

  def binding_scope(tenant_id)
    OpenSSL::Digest::SHA256.hexdigest([origin.normalize.to_s, tenant_id].join("\0"))
  end

  def signing_secret
    ENV.fetch('VIARI_CHATWOOT_SIGNING_SECRET')
  end

  def actor_for(user)
    @actors[user.id.to_s]
  end
end
