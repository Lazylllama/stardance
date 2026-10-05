class Admin::GrowthPolicy < ApplicationPolicy
  # Admin only, like the other all-users dashboards.
  def show? = user&.admin?

  def rebuild? = show?
end
