# frozen_string_literal: true

require "test_helper"

# == Schema Information
#
# Table name: certification_mac_analyses
#
#  id             :bigint           not null, primary key
#  generated_at   :datetime         not null
#  report         :jsonb            not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  ysws_review_id :bigint           not null
#
# The report is written verbatim by an external analyzer and is not validated on
# the way in, so these tests lean on the shapes that actually occur in
# production: the stable core, the improvised long tail, and the early rows with
# a different top level. Records are built unsaved — the reader API is pure over
# `report` and needs no persisted review.
class Certification::MACAnalysisTest < ActiveSupport::TestCase
  # A report in the shape ~240 of the 254 production rows use.
  MODERN_REPORT = {
    "review_id" => 103,
    "summary_note" => "Declared minimal AI use; 57% of heartbeats from an AI editor.",
    "recommend_fraud_flag" => false,
    "recommend_fraud_flag_reason" => nil,
    "user" => { "slack_id" => "U086", "display_name" => "someone", "experience_level" => "experienced" },
    "project" => { "title" => "A Project", "type" => "Web App" },
    "flags" => [
      { "type" => "phantom_entities", "severity" => "yellow", "detail" => "22 phantom entities" },
      { "type" => "clean_human", "severity" => "green", "detail" => "commits look hand-written" }
    ],
    "signals" => {
      "total_heartbeats" => 33_911,
      "total_writes" => 32_806,
      "write_ratio_pct" => 96.7,
      "distinct_files" => 196,
      "total_commits" => 28,
      "commit_span_days" => 22,
      "ai_coding_pct" => 57.2,
      "human_coding_pct" => 42.7,
      "editor_agents" => [ "wakatime/v2.15.0 cursor/1.105.1" ],
      "phantom_entities" => [ "Cursor 061160a4" ],
      "other_categories" => [ { "name" => "writing docs", "pct" => 0.1 } ],
      "hidden_ai_in_user_agent" => true,
      "hours_at_ship" => 11
    },
    "devlog_recommendations" => [
      { "devlog_review_id" => 254, "date" => "2026-06-01", "original_minutes" => 24,
        "recommended_minutes" => 5, "justification" => "mostly AI-authored" }
    ],
    "cached_data" => {
      "commits" => [ { "sha" => "804a7868", "author" => "someone", "message" => "persist profiles" } ],
      "entities" => [ "README.md", "app.tsx" ],
      "commits_note" => "only commits inside the tracked window are listed"
    }
  }.freeze

  def analysis(report)
    Certification::MACAnalysis.new(report: report)
  end

  test "core_signals returns the stable keys in display order" do
    signals = analysis(MODERN_REPORT).core_signals

    assert_equal Certification::MACAnalysis::CORE_SIGNAL_KEYS, signals.keys
    assert_equal 96.7, signals["write_ratio_pct"]
  end

  test "extra_signals carries the improvised keys and nothing else" do
    assert_equal %w[hidden_ai_in_user_agent hours_at_ship], analysis(MODERN_REPORT).extra_signals.keys.sort
  end

  test "worst_severity picks the most severe flag rather than the first" do
    assert_equal "yellow", analysis(MODERN_REPORT).worst_severity

    escalated = MODERN_REPORT.merge(
      "flags" => [
        { "severity" => "green" }, { "severity" => "red" }, { "severity" => "orange" }
      ]
    )
    assert_equal "red", analysis(escalated).worst_severity
  end

  test "worst_severity ignores severities it doesn't recognise" do
    report = MODERN_REPORT.merge("flags" => [ { "severity" => "chartreuse" }, { "severity" => "yellow" } ])

    assert_equal "yellow", analysis(report).worst_severity
  end

  test "recommendation_for finds the entry for a devlog review" do
    recommendation = analysis(MODERN_REPORT).recommendation_for(254)

    assert_equal 5, recommendation["recommended_minutes"]
    assert_equal 24, recommendation["original_minutes"]
  end

  test "recommendation_for returns nil for a devlog the report doesn't cover" do
    assert_nil analysis(MODERN_REPORT).recommendation_for(999)
  end

  # A handful of early reports name the field suggested_minutes.
  test "recommendation_for normalises suggested_minutes onto recommended_minutes" do
    report = MODERN_REPORT.merge(
      "devlog_recommendations" => [ { "devlog_review_id" => 254, "suggested_minutes" => 12 } ]
    )

    assert_equal 12, analysis(report).recommendation_for(254)["recommended_minutes"]
  end

  test "recommendation_for skips entries with no devlog review id" do
    report = MODERN_REPORT.merge(
      "devlog_recommendations" => [ { "recommended_minutes" => 5 }, { "devlog_review_id" => 7, "recommended_minutes" => 9 } ]
    )

    assert_equal [ 9 ], analysis(report).devlog_recommendations.map { |entry| entry["recommended_minutes"] }
  end

  test "evidence_tables describes each cached_data array and skips the notes" do
    tables = analysis(MODERN_REPORT).evidence_tables.index_by { |table| table[:key] }

    assert_equal %w[commits entities], tables.keys.sort
    assert_equal %w[sha author message], tables["commits"][:columns]
    assert_equal "Commits", tables["commits"][:title]
    # A flat list has no columns, so the banner renders it as a list.
    assert_empty tables["entities"][:columns]
  end

  test "evidence_notes returns the scalar cached_data entries" do
    assert_equal({ "commits_note" => "only commits inside the tracked window are listed" },
      analysis(MODERN_REPORT).evidence_notes)
  end

  test "an empty report yields empty results instead of raising" do
    empty = analysis({})

    assert_nil empty.summary_note
    assert_nil empty.worst_severity
    assert_nil empty.recommendation_for(1)
    assert_not empty.recommend_fraud_flag?
    assert_empty empty.flags
    assert_empty empty.core_signals
    assert_empty empty.extra_signals
    assert_empty empty.evidence_tables
    assert_empty empty.evidence_notes
  end

  # The ~14 earliest rows use a different top level entirely.
  test "a legacy-shape report degrades gracefully" do
    legacy = analysis({ "stub" => true, "verdict" => "needs review", "tokens_used" => 4200 })

    assert_nil legacy.worst_severity
    assert_empty legacy.flags
    assert_empty legacy.core_signals
    assert_empty legacy.evidence_tables
  end

  test "keys holding the wrong type are treated as absent" do
    malformed = analysis(
      "flags" => "not an array",
      "signals" => [ "not a hash" ],
      "cached_data" => "not a hash",
      "devlog_recommendations" => { "not" => "an array" }
    )

    assert_empty malformed.flags
    assert_empty malformed.core_signals
    assert_empty malformed.evidence_tables
    assert_empty malformed.devlog_recommendations
  end

  test "flag entries that aren't hashes are dropped" do
    report = MODERN_REPORT.merge("flags" => [ "understated_ai", { "severity" => "orange" } ])

    assert_equal 1, analysis(report).flags.size
    assert_equal "orange", analysis(report).worst_severity
  end

  test "empty cached_data arrays produce no evidence table" do
    report = MODERN_REPORT.merge("cached_data" => { "commits" => [] })

    assert_empty analysis(report).evidence_tables
  end
end
