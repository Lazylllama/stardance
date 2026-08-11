# frozen_string_literal: true

require "test_helper"

class User::ModerationTest < ActiveJob::TestCase
  setup do
    @user = create_user(slack_id: "U_MOD_OWNER", display_name: "mod-owner")
  end

  test "banning clears the user's pending YSWS reviews" do
    review = build_review

    @user.ban!(reason: "fraud")

    assert @user.reload.banned?
    assert_not review.reload.pending?
    assert review.devlog_reviews.first.reload.rejected?
    assert_equal "banned", review.devlog_reviews.first.justification
    assert_equal :rejected, review.review_status
  end

  test "banning leaves an already-completed review alone" do
    review = build_review
    review.update!(reviewed_at: 1.day.ago, approved_minutes: 15)
    review.devlog_reviews.first.approve!(15, "looks real")

    @user.ban!(reason: "fraud")

    assert review.devlog_reviews.first.reload.approved?
  end

  private

    # A pending review with one pending devlog review, owned by @user.
    def build_review
      project = Project.create!(title: "moderation project #{SecureRandom.hex(4)}")
      project.memberships.create!(user: @user, role: :owner)

      ship_event = Post::ShipEvent.new(body: "shipped", certification_status: "pending")
      ship_event.uploading_attachments = true
      ship_event.save!(validate: false)
      Post.create!(project: project, user: @user, postable: ship_event)

      review = Certification::Ysws.create!(
        user: @user, project: project, post_ship_event: ship_event, original_minutes: 15
      )

      devlog = Post::Devlog.new(body: "log", duration_seconds: 900)
      devlog.uploading_attachments = true
      devlog.save!
      Post.create!(project: project, user: @user, postable: devlog)

      Certification::Devlog.create!(
        post_devlog: devlog, ysws_review: review, original_minutes: 15, status: :pending
      )

      review
    end
end
