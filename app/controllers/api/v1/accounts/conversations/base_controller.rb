class Api::V1::Accounts::Conversations::BaseController < Api::V1::Accounts::BaseController
  before_action :conversation

  private

  def dashboard_user?
    Current.user.is_a?(User) && !authenticate_by_access_token?
  end

  def conversation
    @conversation ||= Current.account.conversations.find_by!(display_id: params[:conversation_id])
    authorize @conversation, :show?
  end
end
