# == Schema Information
#
# Table name: project_reports
#
#  id          :bigint           not null, primary key
#  details     :text             not null
#  reason      :string           not null
#  status      :integer          default(0), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  project_id  :bigint           not null
#  reporter_id :bigint           not null
#
# Indexes
#
#  idx_project_reports_status_created_at_desc           (status,created_at DESC)
#  index_project_reports_on_project_id                  (project_id)
#  index_project_reports_on_reporter_id                 (reporter_id)
#  index_project_reports_on_reporter_id_and_project_id  (reporter_id,project_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (reporter_id => users.id)
#
class Project::Report < ApplicationRecord
    has_paper_trail

    belongs_to :reporter, class_name: "User"
    belongs_to :project
    after_commit :notify_slack_channel, on: :create

    REASONS = [
      "low_effort",
      "undeclared_ai",
      "demo_broken",
      "fraud",
      "other",
      "External flag",
      "YSWS project flag",
      "Shipwrights project flag"
    ].freeze
    USER_REASONS = %w[low_effort undeclared_ai demo_broken other].freeze # fraud is internal

    DETAILS_MIN_LENGTH = 20

    # excluded from REASONS on purpose — never saved as a Project::Report row
    SHOULD_NOT_HAVE_BEEN_APPROVED_REASON = "should_not_have_been_approved"
    SHOULD_NOT_HAVE_BEEN_APPROVED_CHANNEL =
      Rails.application.credentials.dig(:slack, :should_not_have_been_approved_channel) ||
      ENV["SHOULD_NOT_HAVE_BEEN_APPROVED_SLACK_CHANNEL"] ||
      "C09TTRZH94Z"
    SHOULD_NOT_HAVE_BEEN_APPROVED_DETAILS_MAX_LENGTH = 2_000
    SHOULD_NOT_HAVE_BEEN_APPROVED_THROTTLE = 7.days

    enum :status, { pending: 0, reviewed: 1, dismissed: 2 }, default: :pending

    validates :reason, presence: true, inclusion: { in: REASONS }
    validates :details, presence: true, length: { minimum: DETAILS_MIN_LENGTH }
    validates :reporter_id, uniqueness: { scope: :project_id, message: "has already reported this project" }

    validates :reporter, exclusion: {
        in: ->(report) { report.project&.users || [] },
        message: "cannot report own project"
      }, unless: -> { Rails.env.development? || reason == "fraud" }

    REASON_LABELS = {
      "low_effort" => "Low-effort project",
      "undeclared_ai" => "Uses AI but it's undeclared",
      "demo_broken" => "Demo does not work",
      "other" => "Other"
    }.freeze

    def reason_label
      REASON_LABELS.fetch(reason, reason.humanize)
    end

    # Returns :ok, :details_too_short, :not_allowed (reporter is a project
    # member), :not_approved, or :throttled (already flagged this approval).
    def self.flag_should_not_have_been_approved!(project:, reporter:, details:)
      details = details.to_s.strip
      return :details_too_short if details.length < DETAILS_MIN_LENGTH
      return :not_allowed if !Rails.env.development? && project.users.include?(reporter)

      latest_approval = project.ship_reviews.approved.order(Arel.sql("decided_at DESC NULLS LAST"), id: :desc).first
      return :not_approved unless latest_approval

      # Tied to the approval, not just (project, reporter), so a re-approval
      # within the window doesn't swallow a legitimate new flag. Checked as a
      # plain exists? first — an outage making `write` return falsy shouldn't
      # be indistinguishable from "already flagged" and silently drop a report.
      cache_key = "project_report/should_not_have_been_approved/#{latest_approval.id}/#{reporter.id}"
      return :throttled if Rails.cache.exist?(cache_key)
      Rails.cache.write(cache_key, true, expires_in: SHOULD_NOT_HAVE_BEEN_APPROVED_THROTTLE)

      reviewer = latest_approval.reviewer

      Rails.logger.info(
        "[Project::Report] should_not_have_been_approved flag: project=#{project.id} reporter=#{reporter.id} reviewer=#{reviewer&.id || 'none'}"
      )

      SendSlackDmJob.perform_later(
        SHOULD_NOT_HAVE_BEEN_APPROVED_CHANNEL,
        "Ship approval flagged",
        blocks_path: "notifications/reports/should_not_have_been_approved_slack_message",
        locals: { project: project, reporter: reporter, reviewer: reviewer, details: details.truncate(SHOULD_NOT_HAVE_BEEN_APPROVED_DETAILS_MAX_LENGTH, omission: "") }
      )
      :ok
    end

    private

    def notify_slack_channel
      SendSlackDmJob.perform_later("C0A1YJ9PDAS", "New report received", blocks_path: "notifications/reports/slack_message", locals: { report: self })
    end
end
