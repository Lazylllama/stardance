class My::TimelapsesController < ApplicationController
  before_action :require_login

  # Temporary recovery hub: every Lookout recording this builder has with tracked
  # time, so they can confirm each one's time reached Hackatime and push any that
  # didn't. Each row links to its per-session finalize page. Retired with the
  # rest of the recovery surface after LookoutSession::FINALIZE_DEADLINE.
  def index
    @deadline = LookoutSession::FINALIZE_DEADLINE
    @window_open = Time.current <= @deadline
    @sessions = LookoutSession.where(user: current_user)
                              .recoverable
                              .includes(:project)
                              .order(Arel.sql("COALESCE(started_at, created_at) DESC"))
  end

  private

  def require_login
    redirect_to root_path, alert: "Please log in first" and return unless current_user
  end
end
