module Admin
  module MegaDashboard
    # End-to-end time from ship submission to payout, broken into the stages a
    # ship actually sits in, read like a browser network waterfall: each stage
    # splits into the time it waited unclaimed and the time a reviewer held it.
    #
    # Only ships that reached payout inside the window are measured, so the
    # bars describe journeys that actually finished rather than a mix of
    # finished and in-flight work.
    class Waterfall
      PERIODS = QueueStats::PERIODS

      # Ships take different routes to payout, and averaging them together
      # produces a number that describes nobody. Each path is measured on its own.
      PATHS = {
        "voting" => "Standard (voting)",
        "hardware" => "Hardware",
        "static_prize" => "Fixed-prize mission"
      }.freeze

      STAGES = [
        { key: "ship_cert", label: "Ship certification" },
        { key: "ysws_review", label: "YSWS review" },
        { key: "voting", label: "Rating" },
        { key: "payout", label: "Payout" }
      ].freeze

      # A fixed-prize ship never enters voting, so the span between its cert
      # decision and its payout is the mission reviewer deciding, not a payout
      # queue. Same measurement, honest label.
      STAGE_LABELS_BY_PATH = {
        "static_prize" => { "payout" => "Mission review" }
      }.freeze

      Journey = Data.define(:ship_event_id, :path, :segments, :total, :reworked)

      def initialize(period: QueueStats::DEFAULT_PERIOD, now: Time.current)
        @period = PERIODS.key?(period.to_s) ? period.to_s : QueueStats::DEFAULT_PERIOD
        @now = now
        @journeys = build_journeys
      end

      def to_h
        {
          period: @period,
          paths: PATHS.keys.index_with { |path| summarise(@journeys.select { |j| j.path == path }, path: path) },
          overall: summarise(@journeys),
          excluded: excluded_counts
        }
      end

      private

      def window_start = (@now - (PERIODS.fetch(@period) - 1).days).beginning_of_day

      # Estimated backfills carry made-up timestamps, so including them would
      # quietly bend every bar. RatingDashboard::Snapshot draws the same line.
      def measurable
        ::Post::ShipEvent
          .where(paid_at: window_start..)
          .where(lifecycle_data_quality: %w[live backfilled_exact])
      end

      def build_journeys
        ships = measurable
          .left_outer_joins(:mission_submission, :certification_ysws_review, post: :project)
          .pluck(
            Arel.sql("post_ship_events.id"),
            Arel.sql("post_ship_events.created_at"),
            Arel.sql("post_ship_events.voting_started_at"),
            Arel.sql("post_ship_events.voting_completed_at"),
            Arel.sql("post_ship_events.paid_at"),
            Arel.sql("projects.hardware_stage"),
            Arel.sql("mission_submissions.payout_path"),
            Arel.sql("certification_ysws_reviews.created_at"),
            Arel.sql("certification_ysws_reviews.claimed_at"),
            Arel.sql("certification_ysws_reviews.reviewed_at"),
            Arel.sql("certification_ysws_reviews.returned_at")
          )

        ship_certs = ::Certification::Ship
          .where(post_ship_event_id: ships.map(&:first))
          .pluck(:post_ship_event_id, :created_at, :claimed_at, :decided_at, :recert_reason)
          .index_by(&:first)

        ships.filter_map do |id, shipped_at, voting_started_at, voting_completed_at, paid_at,
                             hardware_stage, payout_path, ysws_at, ysws_claimed_at, ysws_reviewed_at, ysws_returned_at|
          cert = ship_certs[id]
          segments = {}

          segments["ship_cert"] = split(cert&.[](1) || shipped_at, cert&.[](2), cert&.[](3))
          segments["ysws_review"] = split(ysws_at, ysws_claimed_at, ysws_reviewed_at) if ysws_at
          segments["voting"] = split(voting_started_at, nil, voting_completed_at) if voting_started_at
          segments["payout"] = split(voting_completed_at || cert&.[](3), nil, paid_at)

          total = paid_at && shipped_at ? paid_at - shipped_at : nil
          next unless total&.positive?

          Journey.new(
            ship_event_id: id,
            path: path_for(hardware_stage, payout_path),
            segments: segments.compact,
            total: total,
            reworked: ysws_returned_at.present? || cert&.[](4).present?
          )
        end
      end

      def path_for(hardware_stage, payout_path)
        return "hardware" if hardware_stage.present?
        return "static_prize" if payout_path == "static_prize"

        "voting"
      end

      # A stage is `wait` (sitting unclaimed) then `work` (a reviewer holding
      # it). Stages with no claim concept report the whole span as wait.
      def split(entered_at, claimed_at, left_at)
        return if entered_at.nil? || left_at.nil? || left_at < entered_at

        if claimed_at && claimed_at.between?(entered_at, left_at)
          { wait: claimed_at - entered_at, work: left_at - claimed_at }
        else
          { wait: left_at - entered_at, work: 0.0 }
        end
      end

      def summarise(journeys, path: nil)
        return { count: 0, stages: [], total_median_hours: nil, total_p90_hours: nil, rework_rate: nil } if journeys.empty?

        labels = STAGE_LABELS_BY_PATH.fetch(path, {})
        stages = STAGES.filter_map do |stage|
          waits = journeys.filter_map { |j| j.segments.dig(stage[:key], :wait) }
          works = journeys.filter_map { |j| j.segments.dig(stage[:key], :work) }
          next if waits.empty?

          {
            key: stage[:key],
            label: labels.fetch(stage[:key], stage[:label]),
            count: waits.size,
            wait_median_hours: percentile_hours(waits, 50),
            work_median_hours: percentile_hours(works, 50),
            median_hours: percentile_hours(journeys.filter_map { |j| segment_total(j, stage[:key]) }, 50),
            p90_hours: percentile_hours(journeys.filter_map { |j| segment_total(j, stage[:key]) }, 90)
          }
        end

        total_median = percentile_hours(journeys.map(&:total), 50)
        # Each stage median is taken over its own subset, so they don't add up
        # to the journey median. Shares are normalised against the summed stage
        # medians instead, which keeps them honest relative to each other and
        # stops a skewed stage reading over 100%.
        stage_total = stages.sum { |stage| stage[:median_hours].to_f }
        stages.each do |stage|
          stage[:share] = stage_total.positive? ? ((stage[:median_hours].to_f / stage_total) * 100).round : nil
        end

        {
          count: journeys.size,
          stages: stages,
          total_median_hours: total_median,
          total_p90_hours: percentile_hours(journeys.map(&:total), 90),
          rework_rate: ((journeys.count(&:reworked) * 100.0) / journeys.size).round(1)
        }
      end

      def segment_total(journey, key)
        segment = journey.segments[key]
        segment && segment[:wait] + segment[:work]
      end

      def excluded_counts
        base = ::Post::ShipEvent.where(paid_at: window_start..)
        {
          estimated: base.where(lifecycle_data_quality: "backfilled_estimated").count,
          unknown: base.where(lifecycle_data_quality: nil).count
        }
      end

      def percentile_hours(seconds, percentile)
        values = seconds.compact
        return if values.empty?

        sorted = values.sort
        index = ((percentile / 100.0) * (sorted.size - 1)).round
        (sorted[index] / 3600.0).round(1)
      end
    end
  end
end
