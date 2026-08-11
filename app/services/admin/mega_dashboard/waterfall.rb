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
      # Hardware is two separate journeys with a build in between, not one
      # continuous wait: a user waits for funding, buys parts and builds
      # (their own time, not a queue), then waits for build certification and
      # payout. Measuring it end to end would report the build as review time.
      PATHS = {
        "voting" => "Standard (voting)",
        "static_prize" => "Fixed-prize mission",
        "hardware_design" => "Hardware design (funding)",
        "hardware_build" => "Hardware build"
      }.freeze

      # YSWS review is deliberately absent: it is internal grant processing the
      # user never waits on, so counting it would overstate what they actually
      # experience. Its return_at is still read, but only to flag rework.
      STAGES = [
        { key: "funding_wait", label: "Waiting for a reviewer" },
        { key: "funding_review", label: "Funding review" },
        { key: "ship_cert", label: "Ship certification" },
        { key: "voting", label: "Rating" },
        { key: "payout", label: "Payout" }
      ].freeze

      # Time inside the journey that no tracked stage accounts for: the gap
      # between shipping and the cert being opened, and between a cert decision
      # and voting starting. Named rather than hidden, so the segments add up to
      # the real end-to-end figure instead of silently falling short.
      UNATTRIBUTED = { key: "unattributed", label: "Other" }.freeze

      # A fixed-prize ship never enters voting, so the span between its cert
      # decision and its payout is the mission reviewer deciding, not a payout
      # queue. Same measurement, honest label.
      STAGE_LABELS_BY_PATH = {
        "static_prize" => { "payout" => "Mission review" },
        "hardware_build" => { "ship_cert" => "Build certification" }
      }.freeze

      Journey = Data.define(:ship_event_id, :path, :segments, :total, :reworked)

      def initialize(period: QueueStats::DEFAULT_PERIOD, now: Time.current)
        @period = PERIODS.key?(period.to_s) ? period.to_s : QueueStats::DEFAULT_PERIOD
        @now = now
        @journeys = build_journeys + build_funding_journeys
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

      # A fixed-prize mission never pays stardust, so it never gets a paid_at:
      # its journey ends when the mission reviewer approves the prize. Keying
      # the whole waterfall off paid_at made that path permanently empty.
      def finished_at_for(path, paid_at, submission_reviewed_at)
        return submission_reviewed_at || paid_at if path == "static_prize"

        paid_at
      end

      # Only the voting path reads the backfilled voting timestamps, so only it
      # needs the data-quality gate. Applying it everywhere threw away the
      # fixed-prize and hardware journeys, whose stages come from the ship cert
      # and the mission review instead.
      def measurable?(path, quality)
        return true unless path == "voting"

        %w[live backfilled_exact].include?(quality)
      end

      def build_journeys
        ships = ::Post::ShipEvent
          .left_outer_joins(:mission_submission, post: :project)
          .where(
            "post_ship_events.paid_at >= :since OR (mission_submissions.payout_path = 'static_prize' AND mission_submissions.reviewed_at >= :since)",
            since: window_start
          )
          .pluck(
            Arel.sql("post_ship_events.id"),
            Arel.sql("post_ship_events.created_at"),
            Arel.sql("post_ship_events.voting_started_at"),
            Arel.sql("post_ship_events.voting_completed_at"),
            Arel.sql("post_ship_events.paid_at"),
            Arel.sql("post_ship_events.lifecycle_data_quality"),
            Arel.sql("projects.hardware_stage"),
            Arel.sql("mission_submissions.payout_path"),
            Arel.sql("mission_submissions.reviewed_at")
          )

        ids = ships.map(&:first)
        ship_certs = ::Certification::Ship
          .where(post_ship_event_id: ids)
          .pluck(:post_ship_event_id, :created_at, :claimed_at, :decided_at, :recert_reason)
          .index_by(&:first)
        returned_ysws = ::Certification::Ysws
          .where(post_ship_event_id: ids).where.not(returned_at: nil)
          .pluck(:post_ship_event_id).to_set

        @excluded = 0

        ships.filter_map do |id, shipped_at, voting_started_at, voting_completed_at, paid_at,
                             quality, hardware_stage, payout_path, submission_reviewed_at|
          path = path_for(hardware_stage, payout_path)
          finished_at = finished_at_for(path, paid_at, submission_reviewed_at)
          next unless finished_at && finished_at >= window_start

          unless measurable?(path, quality)
            @excluded += 1
            next
          end

          cert = ship_certs[id]
          segments = {}
          segments["ship_cert"] = split(cert&.[](1) || shipped_at, cert&.[](2), cert&.[](3))
          segments["voting"] = split(voting_started_at, nil, voting_completed_at) if voting_started_at
          segments["payout"] = split(voting_completed_at || cert&.[](3), nil, finished_at)

          total = finished_at && shipped_at ? finished_at - shipped_at : nil
          next unless total&.positive?

          Journey.new(
            ship_event_id: id,
            path: path,
            segments: segments.compact,
            total: total,
            reworked: returned_ysws.include?(id) || cert&.[](4).present?
          )
        end
      end

      # A funding request is its own short journey: submitted, waiting for a
      # reviewer, then decided. It happens before the build, so it is measured
      # separately rather than folded into the build's timeline.
      def build_funding_journeys
        ::Certification::FundingRequest
          .where(decided_at: window_start..)
          .pluck(:id, :created_at, :claimed_at, :decided_at)
          .filter_map do |id, created_at, claimed_at, decided_at|
            total = decided_at - created_at
            next unless total.positive?

            claimed_at = decided_at unless claimed_at&.between?(created_at, decided_at)

            Journey.new(
              ship_event_id: id,
              path: "hardware_design",
              segments: {
                "funding_wait" => { wait: claimed_at - created_at, work: 0.0 },
                "funding_review" => { wait: decided_at - claimed_at, work: 0.0 }
              },
              total: total,
              reworked: false
            )
          end
      end

      def path_for(hardware_stage, payout_path)
        return "hardware_build" if hardware_stage.present?
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

      # Segments are MEANS, not medians, and that is deliberate: medians are not
      # additive, so a bar built from per-stage medians can never add up to the
      # median end-to-end time. Means are additive, so stage means plus the
      # unattributed remainder sum exactly to the mean journey. The true median
      # and p90 are reported alongside for context.
      def summarise(journeys, path: nil)
        return { count: 0, stages: [], total_mean_hours: nil, total_median_hours: nil, total_p90_hours: nil, rework_rate: nil } if journeys.empty?

        labels = STAGE_LABELS_BY_PATH.fetch(path, {})
        rows = journeys.map { |journey| durations_for(journey) }

        stages = (STAGES + [ UNATTRIBUTED ]).filter_map do |stage|
          values = rows.map { |row| row.fetch(stage[:key], 0.0) }
          mean = values.sum / values.size
          next if mean <= 0

          {
            key: stage[:key],
            label: labels.fetch(stage[:key], stage[:label]),
            count: values.count(&:positive?),
            mean_hours: (mean / 3600.0).round(1),
            p90_hours: percentile_hours(values.reject(&:zero?), 90)
          }
        end

        total_mean = rows.sum { |row| row.values.sum } / rows.size
        stages.each do |stage|
          stage[:share] = total_mean.positive? ? ((stage[:mean_hours] * 3600.0 / total_mean) * 100).round(1) : nil
        end

        {
          count: journeys.size,
          stages: stages,
          total_mean_hours: (total_mean / 3600.0).round(1),
          total_median_hours: percentile_hours(journeys.map(&:total), 50),
          total_p90_hours: percentile_hours(journeys.map(&:total), 90),
          rework_rate: ((journeys.count(&:reworked) * 100.0) / journeys.size).round(1)
        }
      end

      # Every stage plus whatever the stages don't account for, so one journey's
      # parts always add to its own end-to-end duration.
      def durations_for(journey)
        parts = STAGES.to_h { |stage| [ stage[:key], segment_total(journey, stage[:key]) || 0.0 ] }
        parts[UNATTRIBUTED[:key]] = [ journey.total - parts.values.sum, 0.0 ].max
        parts
      end

      def segment_total(journey, key)
        segment = journey.segments[key]
        segment && segment[:wait] + segment[:work]
      end

      # Voting journeys dropped for unusable backfill timestamps.
      def excluded_counts = { estimated_or_unknown: @excluded.to_i }

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
