class Api::V1::Accounts::Integrations::ViariSettingsController < Api::V1::Accounts::BaseController
  before_action :require_administrator
  rescue_from Viari::Client::Unavailable, TypeError, ArgumentError, KeyError, JSON::ParserError, URI::InvalidURIError, ActiveSupport::MessageEncryptor::InvalidMessage do
    render json: { error: 'viari_configuration_invalid' }, status: :unprocessable_entity
  end

  def show
    render json: settings.public_settings
  end

  def update
    settings.save(params.permit(:origin, :namespace, :api_key, actors: {}).to_h)
    render json: settings.public_settings
  end

  def destroy
    settings.disable
    head :no_content
  end

  private

  def settings
    @settings ||= Viari::Settings.new(Current.account)
  end

  def require_administrator
    head :forbidden unless Current.user.is_a?(User) && !authenticate_by_access_token? && Current.account_user&.administrator?
  end
end
