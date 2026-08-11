# frozen_string_literal: true

require "test_helper"

class OneTime::RejectDeletedProjectYswsReviewsJobTest < ActiveJob::TestCase
  setup do
    @owner = create_user(slack_id: "U_ONETIME_OWNER", display_name: "onetime-owner")
    @job   = OneTime::RejectDeletedProjectYswsReviewsJob.new
  end

  test "the scope is pending reviews on soft-deleted projects only" do
    deleted = build_review
    deleted.project.soft_delete!(force: true)
    live = build_review
    completed = build_review
    completed.project.soft_delete!(force: true)
    completed.update!(reviewed_at: 1.day.ago)

    ids = @job.scope.pluck(:id)

    assert_includes ids, deleted.id
    assert_not_includes ids, live.id
    assert_not_includes ids, completed.id
  end

  test "a dry run writes nothing" do
    review = build_review
    review.project.soft_delete!(force: true)

    assert_equal [ review.id ], @job.perform

    assert review.reload.pending?
    assert review.devlog_reviews.first.reload.pending?
  end

  test "a wet run rejects the review and reports what it did" do
    review = build_review
    review.project.soft_delete!(force: true)

    summary = @job.perform(dry_run: false)

    assert_equal 1, summary[:reviews]
    assert_equal 1, summary[:devlog_reviews]
    assert_equal 1, summary[:sync_skipped]
    assert_not review.reload.pending?
    assert review.devlog_reviews.first.reload.rejected?
  end

  test "a self-deleted project's review is rejected as project deleted, not banned" do
    review = build_review
    review.project.soft_delete!(force: true)

    @job.perform(dry_run: false)

    assert_not @owner.reload.banned?
    assert_equal "project deleted", review.devlog_reviews.first.reload.justification
  end

  private

    # A pending review with one pending devlog review.
    def build_review
      project = Project.create!(title: "onetime project #{SecureRandom.hex(4)}")
      project.memberships.create!(user: @owner, role: :owner)

      ship_event = Post::ShipEvent.new(body: "shipped", certification_status: "pending")
      ship_event.uploading_attachments = true
      ship_event.save!(validate: false)
      Post.create!(project: project, user: @owner, postable: ship_event)

      review = Certification::Ysws.create!(
        user: @owner, project: project, post_ship_event: ship_event, original_minutes: 15
      )

      devlog = Post::Devlog.new(body: "log", duration_seconds: 900)
      devlog.uploading_attachments = true
      devlog.save!
      Post.create!(project: project, user: @owner, postable: devlog)

      Certification::Devlog.create!(
        post_devlog: devlog, ysws_review: review, original_minutes: 15, status: :pending
      )

      review
    end
end
