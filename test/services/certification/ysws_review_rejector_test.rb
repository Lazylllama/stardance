# frozen_string_literal: true

require "test_helper"

# Auto-rejection of YSWS reviews left unreviewable by a soft-deleted project.
class Certification::YswsReviewRejectorTest < ActiveJob::TestCase
  setup do
    @avd = create_user(
      slack_id: Certification::YswsReviewRejector::REVIEWER_SLACK_ID,
      display_name: "avd"
    )
    @owner = create_user(slack_id: "U_REJ_OWNER", display_name: "rej-owner")
  end

  test "every undecided devlog review lands on a rejection" do
    review = build_review(statuses: [ :pending, :approved, :rejected ])

    result = Certification::YswsReviewRejector.new(review, reason: :banned).call

    assert result.rejected
    assert_equal 2, result.devlog_reviews
    assert review.devlog_reviews.reload.all?(&:rejected?)
    assert review.devlog_reviews.all? { |dr| dr.approved_minutes.zero? }
  end

  test "an already-rejected devlog review keeps its own justification" do
    review = build_review(statuses: [ :rejected ])
    untouched = review.devlog_reviews.first

    Certification::YswsReviewRejector.new(review, reason: :banned).call

    assert_equal "not enough detail", untouched.reload.justification
  end

  test "the justification follows the reason" do
    banned  = build_review(statuses: [ :pending ])
    deleted = build_review(statuses: [ :pending ])

    Certification::YswsReviewRejector.new(banned, reason: :banned).call
    Certification::YswsReviewRejector.new(deleted, reason: :project_deleted).call

    assert_equal "banned", banned.devlog_reviews.first.reload.justification
    assert_equal "project deleted", deleted.devlog_reviews.first.reload.justification
  end

  test "the review is completed, credited to AVD, and unclaimed" do
    claimer = create_user(slack_id: "U_REJ_CLAIM", display_name: "rej-claimer")
    review  = build_review(statuses: [ :pending ])
    review.update!(claimed_by: claimer, claimed_at: Time.current)

    Certification::YswsReviewRejector.new(review, reason: :banned).call
    review.reload

    assert_not review.pending?
    assert_not_nil review.reviewed_at
    assert_equal @avd.id, review.reviewer_id
    assert_nil review.claimed_by_id
    assert_nil review.claimed_at
    assert_equal :rejected, review.review_status
  end

  test "the Airtable sync is enqueued when an integrity check exists" do
    review = build_review(statuses: [ :pending ], integrity: true)

    result = nil
    assert_enqueued_with(job: Certification::YswsAirtableSyncJob, args: [ review.id ]) do
      result = Certification::YswsReviewRejector.new(review, reason: :banned).call
    end

    assert result.synced
  end

  test "a review with no integrity check is rejected but not synced" do
    review = build_review(statuses: [ :pending ])

    result = nil
    assert_no_enqueued_jobs(only: Certification::YswsAirtableSyncJob) do
      result = Certification::YswsReviewRejector.new(review, reason: :banned).call
    end

    assert result.rejected
    assert_not result.synced
  end

  test "an already-completed review is left alone" do
    review = build_review(statuses: [ :pending ])
    review.update!(reviewed_at: 1.day.ago)

    result = Certification::YswsReviewRejector.new(review, reason: :banned).call

    assert_not result.rejected
    assert review.devlog_reviews.first.reload.pending?
  end

  test "reject_pending_for_user! clears every pending review the user has" do
    mine    = build_review(statuses: [ :pending ])
    decided = build_review(statuses: [ :pending ])
    decided.update!(reviewed_at: 1.day.ago)

    Certification::YswsReviewRejector.reject_pending_for_user!(@owner)

    assert_not mine.reload.pending?
    assert decided.devlog_reviews.first.reload.pending?
  end

  private

    # A pending review carrying one devlog review per entry in `statuses`.
    def build_review(statuses:, integrity: false)
      project = Project.create!(title: "rejector project #{SecureRandom.hex(4)}")
      project.memberships.create!(user: @owner, role: :owner)

      ship_event = Post::ShipEvent.new(body: "shipped", certification_status: "pending")
      ship_event.uploading_attachments = true
      ship_event.save!(validate: false)
      Post.create!(project: project, user: @owner, postable: ship_event)

      if integrity
        Certification::Integrity.create!(ship_event: ship_event, status: :pending)
      end

      review = Certification::Ysws.create!(
        user: @owner, project: project, post_ship_event: ship_event,
        original_minutes: statuses.size * 15
      )

      statuses.each do |status|
        devlog = Post::Devlog.new(body: "log", duration_seconds: 900)
        devlog.uploading_attachments = true
        devlog.save!
        Post.create!(project: project, user: @owner, postable: devlog)

        Certification::Devlog.create!(
          post_devlog: devlog, ysws_review: review, original_minutes: 15,
          status: status,
          approved_minutes: { pending: nil, approved: 15, rejected: 0 }[status],
          justification: { pending: nil, approved: "looks real", rejected: "not enough detail" }[status]
        )
      end

      review
    end
end
