class CustomFilterPolicy < ApplicationPolicy
  def index?
    @account_user.administrator? || @account_user.agent?
  end

  alias show? index?

  def create?
    @account_user.administrator? || (@account_user.agent? && record.personal?)
  end

  alias update? create?
  alias destroy? create?
end
