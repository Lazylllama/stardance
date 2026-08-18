class Admin::Certification::YswsPolicy < ApplicationPolicy
  def index?
    user.admin? || user.has_role?(:guardian_of_integrity)
  end

  def show?
    index?
  end

  def dashboard?
    index?
  end

  def update?
    index?
  end

  def report_fraud?
    index?
  end

  # Reversing a decided review is destructive and admin-only: guardians of
  # integrity can review, but cannot undo a completed review.
  def undo?
    user&.admin? && !record.pending?
  end

  def unclaim?
    user.present? && index? && record.pending? && record.claimed_by?(user)
  end

  def resync?
    index?
  end
end
