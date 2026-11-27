class Api::V1::Accounts::Agents::InboxAccessController < Api::V1::Accounts::BaseController
  ACCESS_LEVELS = %w[none agent supervisor].freeze

  before_action :authorize_administrator
  before_action :fetch_agent

  def show
    return render json: [] unless pilot_in_account?

    levels = @agent.user.inbox_members.where(inbox: Current.account.inboxes).index_by(&:inbox_id)
    render json: Current.account.inboxes.order_by_name.map { |inbox| inbox_access(inbox, levels[inbox.id]) }
  end

  def update
    return head :not_found unless pilot_in_account?
    return head :unprocessable_content unless params[:inbox_id].is_a?(Integer) && ACCESS_LEVELS.include?(params[:access_level])

    inbox = Current.account.inboxes.find(params[:inbox_id])
    level = params[:access_level]
    return head :unprocessable_content if level == 'supervisor' && !Conversations::AssignmentAccess.enabled?(inbox)

    membership = @agent.with_lock { update_membership(inbox, level) }
    render json: inbox_access(inbox, membership)
  end

  private

  def authorize_administrator
    raise Pundit::NotAuthorizedError unless Current.account_user&.administrator?
  end

  def fetch_agent
    @agent = Current.account.account_users.find_by!(user_id: params[:agent_id])
  end

  def pilot_in_account?
    inbox = Current.account.inboxes.find_by(id: Conversations::AssignmentAccess.inbox_id)
    Conversations::AssignmentAccess.enabled?(inbox)
  end

  def inbox_access(inbox, membership)
    supervision_available = Conversations::AssignmentAccess.enabled?(inbox)
    level = membership&.access_level || 'none'
    level = 'agent' if level == 'supervisor' && !supervision_available

    { id: inbox.id, name: inbox.name, access_level: level, supervision_available: supervision_available }
  end

  def update_membership(inbox, level)
    if level == 'none'
      inbox.remove_members([@agent.user_id])
      return
    end

    membership = inbox.inbox_members.lock.find_or_initialize_by(user_id: @agent.user_id)
    new_member = membership.new_record?
    membership.update!(supervisor: level == 'supervisor')
    inbox.update_account_cache if new_member
    membership
  end
end
