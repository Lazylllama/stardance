# frozen_string_literal: true

require "test_helper"

# The banner renders an externally-supplied jsonb blob whose shape drifts, so
# these tests are mostly about it not blowing up: a report missing a section must
# drop that section, not raise on the review page.
class Admin::Certification::MACAnalysisBannerComponentTest < ViewComponent::TestCase
  def banner(report)
    Admin::Certification::MACAnalysisBannerComponent.new(
      analysis: Certification::MACAnalysis.new(report: report, generated_at: 2.hours.ago)
    )
  end

  test "renders nothing when the review has no analysis" do
    render_inline Admin::Certification::MACAnalysisBannerComponent.new(analysis: nil)

    assert_no_selector ".mac-banner"
  end

  test "renders the summary, flag chips and severity tone" do
    render_inline banner(
      "summary_note" => "57% of heartbeats came from an AI editor.",
      "flags" => [
        { "type" => "understated_ai", "severity" => "yellow", "detail" => "declared minimal" },
        { "type" => "clean_human", "severity" => "green", "detail" => "commits look hand-written" }
      ]
    )

    assert_selector ".mac-banner.mac-banner--yellow"
    assert_text "57% of heartbeats came from an AI editor."
    # Labels come from the report data, never from a hardcoded taxonomy.
    assert_selector ".mac-banner__chip--yellow", text: "Understated ai"
    assert_selector ".mac-banner__chip--green", text: "Clean human"
    assert_text "about 2 hours ago"
  end

  test "surfaces a recommended fraud flag with its reason" do
    render_inline banner(
      "recommend_fraud_flag" => true,
      "recommend_fraud_flag_reason" => "undisclosed AI usage",
      "flags" => [ { "type" => "undisclosed_ai", "severity" => "red" } ]
    )

    assert_selector ".mac-banner.mac-banner--red"
    assert_selector ".mac-banner__chip--red", text: "Fraud flag recommended"
    assert_text "undisclosed AI usage"
  end

  test "renders signals, recommendations and evidence in the drawer" do
    render_inline banner(
      "signals" => { "ai_coding_pct" => 57.2, "total_heartbeats" => 33_911, "hours_at_ship" => 11 },
      "devlog_recommendations" => [
        { "devlog_review_id" => 254, "date" => "2026-06-01", "original_minutes" => 651,
          "recommended_minutes" => 130, "justification" => "mostly AI-authored" }
      ],
      "cached_data" => {
        "commits" => [ { "sha" => "804a7868", "message" => "persist profiles" } ],
        "entities" => [ "README.md" ]
      }
    )

    assert_text "57.2%"
    assert_text "33,911"
    # Improvised signal keys still render, without being enumerated in code.
    assert_text "Hours at ship"
    assert_text "130 min (2:10)"
    assert_text "-521 min"
    # The drawer starts closed, so its contents are present but not visible.
    assert_selector ".mac-banner__evidence", count: 2, visible: :all
    assert_text "804a7868"
  end

  test "an empty report renders the banner without raising" do
    render_inline banner({})

    assert_selector ".mac-banner"
    assert_text "Pre-screen ran but returned no summary."
    assert_no_selector ".mac-banner__chip", visible: :all
    assert_no_selector ".mac-banner__evidence", visible: :all
  end

  test "a legacy-shape report renders the banner without raising" do
    render_inline banner("stub" => true, "verdict" => "needs review")

    assert_selector ".mac-banner"
    assert_no_selector ".mac-banner--red"
  end

  test "long list signals are truncated with an overflow count" do
    agents = Array.new(15) { |i| "wakatime/v#{i}" }
    render_inline banner("signals" => { "editor_agents" => agents })

    assert_selector ".mac-banner__list-item", visible: :all,
      count: Admin::Certification::MACAnalysisBannerComponent::LIST_PREVIEW_LIMIT + 1
    assert_text "+3 more"
  end
end
