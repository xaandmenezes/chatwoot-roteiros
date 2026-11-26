class Api::V1::Accounts::UmblerLabelSyncsController < Api::V1::Accounts::BaseController
  before_action :require_account_administrator

  def show
    render_report(enabled? ? UmblerLabelSync.latest(Current.account) : nil)
  end

  def create
    return render_report(nil, :unprocessable_content) unless enabled?

    render_report(UmblerLabelSync.start!(Current.account).reload, :accepted)
  end

  private

  def enabled?
    UmblerLabels::Sync.configured?(Current.account)
  end

  def render_report(run, status = :ok)
    report = run&.report || { status: 'idle', counts: UmblerLabelSync::EMPTY_COUNTS }
    render json: report.merge(enabled: enabled?), status: status
  end

  def require_account_administrator
    raise Pundit::NotAuthorizedError unless Current.account_user&.administrator?
  end
end
