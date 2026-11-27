class Api::V1::Accounts::Conversations::RyzePresencesController < Api::V1::Accounts::Conversations::BaseController
  def create
    return head :no_content unless Current.user.is_a?(User) && Ryze::Presence.enabled?(@conversation)

    state, composer_id = params.values_at(:state, :composer_id)
    return head :unprocessable_content if params.key?(:is_private) || !Ryze::Presence.valid_event?(state, composer_id)

    Ryze::Presence.update(Current.user.id, composer_id, state, conversation: @conversation)
    head :no_content
  end
end
