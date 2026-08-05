# frozen_string_literal: true

class Admin::Certification::ShipPolicy < ApplicationPolicy
  def index? = user&.can_review?

  def logs? = user&.can_review?

  def show? = can_review_hardware? && not_own_project?

  def update? = show?

  def next? = user&.can_review?

  def set_project_type? = show?

  def set_bonus_stardust? = user&.admin?

  def report_fraud? = user&.can_review?

  class Scope < ApplicationPolicy::Scope
    # Software only: hardware ships are listed by the hardware build queue.
    # The hardware controller reads Certification::Ship directly rather than
    # through this scope, so it keeps seeing them.
    def resolve
      return scope.none unless user&.can_review?
      scope.joins(:project).where(projects: { deleted_at: nil }).merge(::Certification::Ship.software_only)
    end
  end

  private

  def not_own_project?
    !user.memberships.exists?(project_id: record.project_id)
  end
end
