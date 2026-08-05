class Admin::Certification::Ysws::DashboardController < Admin::Certification::ApplicationController
  # Lazy-loaded (Turbo Frame) reviewer stats banner for the YSWS review queue.
  # Read-only, so no PaperTrail/audit entry is needed.
  def show
    authorize ::Certification::Ysws, :dashboard?

    @leaderboard = ::Certification::Ysws.reviewer_devlog_leaderboard
    @chart_data  = ::Certification::Ysws.reviewer_daily_devlog_data.to_json

    # Reviewers hitting the daily average get the leaderboard's top-spot treatment,
    # alongside a devlogs/day column. Both ride the pace flag: nil averages hide
    # the column and leave every row unhighlighted.
    if Flipper.enabled?(:devlog_review_pace, current_user)
      @daily_averages       = ::Certification::Ysws.reviewer_daily_averages
      @on_pace_reviewer_ids = ::Certification::Ysws.reviewers_on_pace(daily_averages: @daily_averages)
    else
      @on_pace_reviewer_ids = Set.new
    end

    # The "See your progress" panel rides its own flag, so it can be rolled out
    # (and rolled back) without touching the leaderboard's pace treatment. Left
    # nil when off so the frame skips the queries as well as the markup.
    @progress = ::Certification::Ysws.reviewer_progress(current_user.id) if
      Flipper.enabled?(:reviewer_progress_panel, current_user)
  end
end
