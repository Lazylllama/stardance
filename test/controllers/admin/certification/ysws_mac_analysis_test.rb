# frozen_string_literal: true

require "test_helper"

# End-to-end coverage for the MAC pre-screen on the YSWS review page: the banner
# along the top and the read-only recommendation on the devlog whose id the report
# names. The page must also render unchanged when a review has no pre-screen, or
# when the reviewer doesn't have the :mac_analysis flag.
class Admin::Certification::YswsMacAnalysisTest < ActionDispatch::IntegrationTest
  setup do
    Flipper.enable(:mac_analysis)

    @reviewer = create_user(slack_id: "U_MAC_REV", display_name: "mac-reviewer")
    @reviewer.grant_role!(:admin)

    @owner = create_user(slack_id: "U_MAC_OWNER", display_name: "mac-owner")
    @review = ysws_review("MAC test project")
    @devlog_review = @review.devlog_reviews.sole

    sign_in @reviewer
  end

  teardown { Flipper.disable(:mac_analysis) }

  test "the banner and the devlog recommendation show when the review has a pre-screen" do
    seed_mac_analysis

    get admin_certification_ysws_review_path(@review)

    assert_response :success
    assert_select ".mac-banner.mac-banner--orange"
    assert_select ".mac-banner__summary", text: /57% of heartbeats/
    assert_select ".mac-banner__chip--orange", text: /Understated ai/
    assert_select ".mac-banner__table td", text: /mostly AI-authored/
    # The note sits beside the devlog media, with the reasoning visible rather
    # than behind a disclosure, and never in the decision panel.
    assert_select ".devlog-review-panel .mac-hint", count: 0
    assert_select ".devlog-media-section .media-row .mac-hint.mac-hint--aside" do
      assert_select ".mac-hint__original", text: "60"
      assert_select ".mac-hint__suggested", text: "13 min"
      assert_select ".mac-hint__reason", text: /mostly AI-authored/
    end
    assert_select ".mac-hint button", count: 0
  end

  test "the page renders without a banner when the review has no pre-screen" do
    get admin_certification_ysws_review_path(@review)

    assert_response :success
    assert_select ".mac-banner", count: 0
    assert_select ".mac-hint", count: 0
    # The rest of the review screen is untouched.
    assert_select ".devlogs-card"
    assert_select ".minutes-input"
  end

  test "nothing about the pre-screen shows when the reviewer doesn't have the flag" do
    seed_mac_analysis
    Flipper.disable(:mac_analysis)

    get admin_certification_ysws_review_path(@review)

    assert_response :success
    assert_select ".mac-banner", count: 0
    assert_select ".mac-hint", count: 0
    assert_select ".devlogs-card"
  end

  private

    def seed_mac_analysis
      @review.create_mac_analysis!(
        generated_at: 1.hour.ago,
        report: {
          "summary_note" => "57% of heartbeats came from an AI editor.",
          "flags" => [ { "type" => "understated_ai", "severity" => "orange", "detail" => "declared minimal" } ],
          "signals" => { "ai_coding_pct" => 57.2, "total_heartbeats" => 33_911 },
          "devlog_recommendations" => [
            { "devlog_review_id" => @devlog_review.id, "original_minutes" => 60,
              "recommended_minutes" => 13, "justification" => "mostly AI-authored" }
          ],
          "cached_data" => { "commits" => [ { "sha" => "804a7868", "message" => "persist profiles" } ] }
        }
      )
    end

    # Minimal review graph: a project with one devlog, a ship event, and the YSWS
    # review the page renders. Mirrors script/make_review.rb, trimmed to what the
    # show action touches.
    def ysws_review(title)
      project = Project.create!(title: title)
      project.memberships.create!(user: @owner, role: :owner)

      devlog = Post::Devlog.new(body: "built the thing", duration_seconds: 3600)
      devlog.uploading_attachments = true
      devlog.save!
      Post.create!(project: project, user: @owner, postable: devlog)

      ship_event = Post::ShipEvent.new(body: "shipped it", certification_status: "pending")
      ship_event.uploading_attachments = true
      ship_event.save!(validate: false)
      Post.create!(project: project, user: @owner, postable: ship_event)

      review = ::Certification::Ysws.create!(
        user: @owner, project: project, post_ship_event: ship_event, original_minutes: 60
      )
      ::Certification::Devlog.create!(
        post_devlog: devlog, ysws_review: review, original_minutes: 60
      )
      review
    end
end
