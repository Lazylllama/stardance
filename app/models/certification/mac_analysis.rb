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
# Indexes
#
#  index_certification_mac_analyses_on_ysws_review_id  (ysws_review_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (ysws_review_id => certification_ysws_reviews.id)
#
# Read API over the pre-screen `report` jsonb.
#
# The report is written verbatim by an external analyzer (see
# Api::V1::MACAnalysesController) and is *not* validated on the way in, so its
# shape drifts: a stable core is present in almost every row, but each report
# also carries whatever ad-hoc keys the analyzer decided to emit for that case,
# and the earliest rows use a different top level entirely. Every reader here is
# therefore total — missing or unexpected keys yield empty results rather than
# raising, so the review page renders for any row in the table.
class Certification::MACAnalysis < ApplicationRecord
  # Severities the analyzer assigns to flags, least to most severe. Used to pick
  # the banner's overall tone from the flags it raised.
  SEVERITY_ORDER = %w[green yellow orange red].freeze

  # The signal keys present in essentially every report, in display order.
  # Anything else the analyzer emitted is surfaced separately as #extra_signals,
  # so a new signal shows up in the UI without a code change.
  CORE_SIGNAL_KEYS = %w[
    total_heartbeats
    total_writes
    write_ratio_pct
    distinct_files
    total_commits
    commit_span_days
    ai_coding_pct
    human_coding_pct
    editor_agents
    phantom_entities
    other_categories
  ].freeze

  self.table_name = "certification_mac_analyses"

  has_paper_trail

  belongs_to :ysws_review, class_name: "Certification::Ysws",
    foreign_key: :ysws_review_id

  validates :report, presence: true
  validates :generated_at, presence: true
  validates :ysws_review_id, uniqueness: true

  def summary_note
    report_hash["summary_note"].presence
  end

  def recommend_fraud_flag?
    report_hash["recommend_fraud_flag"] == true
  end

  def recommend_fraud_flag_reason
    report_hash["recommend_fraud_flag_reason"].presence
  end

  # Flags the analyzer raised, each { "type", "severity", "detail" }. Entries
  # that aren't hashes are dropped — the banner reads keys off them.
  def flags
    @flags ||= Array.wrap(report_hash["flags"]).grep(Hash)
  end

  # Most severe flag severity raised, or nil when the report raised none (which
  # includes every legacy-shape row). Unrecognised severities sort lowest.
  def worst_severity
    flags
      .filter_map { |flag| flag["severity"].presence }
      .max_by { |severity| SEVERITY_ORDER.index(severity) || -1 }
  end

  def core_signals
    signals.slice(*CORE_SIGNAL_KEYS)
      .reject { |_key, value| value.nil? }
      .sort_by { |key, _value| CORE_SIGNAL_KEYS.index(key) }
      .to_h
  end

  def extra_signals
    signals.except(*CORE_SIGNAL_KEYS).reject { |_key, value| value.nil? }
  end

  # Per-devlog time recommendation for one Certification::Devlog, or nil when the
  # report has none for it. Memoised into a lookup because the devlog partial
  # asks once per devlog.
  def recommendation_for(devlog_review_id)
    recommendations_by_devlog_review_id[devlog_review_id]
  end

  def devlog_recommendations
    recommendations_by_devlog_review_id.values
  end

  # The cached_data arrays, as { key:, title:, columns:, rows: } — the raw
  # evidence the verdict rests on, so a reviewer can check it without refetching.
  # `columns` is empty for flat lists (e.g. filenames), which render as a list
  # rather than a table.
  def evidence_tables
    cached_data.filter_map do |key, value|
      rows = Array.wrap(value)
      next if !value.is_a?(Array) || rows.empty?

      {
        key: key,
        title: key.to_s.humanize,
        columns: rows.grep(Hash).flat_map(&:keys).uniq,
        rows: rows
      }
    end
  end

  # Scalar cached_data entries — the analyzer's free-text notes about how it read
  # the evidence ("_warehouse_note", "commits_note", …).
  def evidence_notes
    cached_data.reject { |_key, value| value.is_a?(Array) || value.is_a?(Hash) || value.nil? }
  end

  private

    # `report` is non-null in the schema, but guard anyway: these readers are
    # called from the review page, which must not 500 on a malformed row.
    def report_hash
      report.is_a?(Hash) ? report : {}
    end

    def signals
      @signals ||= hash_at("signals")
    end

    def cached_data
      @cached_data ||= hash_at("cached_data")
    end

    def hash_at(key)
      value = report_hash[key]
      value.is_a?(Hash) ? value : {}
    end

    # Recommendations keyed by devlog review id. A handful of early reports name
    # the field `suggested_minutes` instead of `recommended_minutes`, so both are
    # normalised onto `recommended_minutes` here rather than in the view.
    def recommendations_by_devlog_review_id
      @recommendations_by_devlog_review_id ||=
        Array.wrap(report_hash["devlog_recommendations"]).grep(Hash).each_with_object({}) do |entry, lookup|
          id = entry["devlog_review_id"]
          next if id.blank?

          minutes = entry["recommended_minutes"] || entry["suggested_minutes"]
          lookup[id.to_i] = entry.merge("recommended_minutes" => minutes)
        end
    end
end
