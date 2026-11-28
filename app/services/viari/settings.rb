class Viari::Settings
  KEY = 'viari_integration'.freeze
  UUID = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i

  def initialize(account)
    @account = account
  end

  def entry
    stored = @account.internal_attributes[KEY]
    return bootstrap if stored.nil?
    return if stored['disabled']

    stored.except('encrypted_key').merge('api_key' => encryptor.decrypt_and_verify(stored.fetch('encrypted_key'), purpose: purpose))
  end

  def origins
    (ENV.fetch('VIARI_CHATWOOT_ALLOWED_ORIGINS', '').split(',').map(&:strip) + [bootstrap&.fetch('origin', nil)]).compact.uniq
  end

  def public_settings
    current = entry || {}
    current.slice('origin', 'namespace', 'actors').merge('origins' => origins, 'has_key' => current['api_key'].present?)
  end

  def save(input)
    prior = @account.internal_attributes[KEY]
    old = entry || {}
    config = input.slice('origin', 'namespace', 'actors')
    raise ArgumentError unless origins.include?(config['origin'])
    config['api_key'] = input['api_key'].presence || old['api_key']
    raise ArgumentError if config['origin'] != old['origin'] && old.present? && input['api_key'].blank?
    actors = config.fetch('actors')
    raise ArgumentError unless actors.is_a?(Hash) && actors.values.all? { |id| UUID.match?(id.to_s) }
    raise ArgumentError unless actors.keys.all? { |id| /\A[1-9]\d*\z/.match?(id) } &&
                               @account.account_users.where(user_id: actors.keys).count == actors.size

    raise ArgumentError if actors.empty?

    connection = Viari::Client.new(Viari::Configuration.new(config), actors.values.first)
    status, result = connection.get('capacidades')
    raise ArgumentError unless status == 200 && UUID.match?(result.dig('data', 'tenantId').to_s)

    config['encrypted_key'] = encryptor.encrypt_and_sign(config.delete('api_key'), purpose: purpose)
    @account.with_lock do
      raise ArgumentError unless @account.internal_attributes[KEY] == prior

      persist(config)
    end
  end

  def disable
    @account.with_lock { persist({ 'disabled' => true }) }
  end

  private

  def persist(value)
    @account.update!(internal_attributes: @account.internal_attributes.merge(KEY => value))
  end

  def bootstrap
    JSON.parse(ENV.fetch('VIARI_CHATWOOT_ACCOUNTS', '{}'))[@account.id.to_s]
  end

  def encryptor
    secret = Rails.application.key_generator.generate_key('viari api credentials', 32)
    ActiveSupport::MessageEncryptor.new(secret, cipher: 'aes-256-gcm')
  end

  def purpose
    "viari-account-#{@account.id}"
  end
end
