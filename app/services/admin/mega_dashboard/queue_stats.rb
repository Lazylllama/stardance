module Admin
  module MegaDashboard
    # Period-scoped stats for a single review queue, shaped for the shared
    # queue panel: four headline tiles and three daily series.
    #
    # Every series is folded in Ruby out of one entered/decided pluck rather
    # than queried per day, so a 90 day window costs the same round trips as a
    # 7 day one.
    class QueueStats
      PERIODS = { "7" => 7, "30" => 30, "90" => 90 }.freeze
      DEFAULT_PERIOD = "30"

      attr_reader :queue

      def initialize(queue, period: DEFAULT_PERIOD, now: Time.current)
        @queue = queue
        @period = PERIODS.key?(period.to_s) ? period.to_s : DEFAULT_PERIOD
        @period_days = PERIODS.fetch(@period)
        @now = now
        @pairs = queue.timestamp_pairs(window_start)
      end

      def tiles
        {
          arrivals: arrivals_in_period.size,
          depth: open_pairs.size,
          unclaimed: queue.unclaimed_count,
          median_decision_hours: percentile_hours(decided_latencies, 50),
          decided_sample: decided_latencies.size
        }
      end

      def metrics
        {
          decisions: decided_in_period.size,
          p90_decision_hours: percentile_hours(decided_latencies, 90),
          median_wait_hours: percentile_hours(open_pairs.map { |entered, _| @now - entered }, 50),
          oldest_wait_hours: open_pairs.map { |entered, _| (@now - entered) / 3600.0 }.max&.round(1),
          overdue: open_pairs.count { |entered, _| @now - entered > queue.sla_hours.hours },
          sla_hours: queue.sla_hours,
          net: decided_in_period.size - arrivals_in_period.size,
          days_to_clear: days_to_clear
        }
      end

      # One row per day: arrivals and decisions (paired bars), median decision
      # latency, and the backlog as it stood at end of day.
      def chart_data
        dates.map do |date|
          day_end = date.in_time_zone.end_of_day
          settled_today = @pairs.filter_map do |entered, decided|
            span = (decided - entered) if decided&.to_date == date && entered
            span if span&.positive?
          end

          {
            date: date.strftime("%-d %b"),
            arrived: @pairs.count { |entered, _| entered&.to_date == date },
            decided: @pairs.count { |_, decided| decided&.to_date == date },
            latency_hours: percentile_hours(settled_today, 50),
            backlog: @pairs.count { |entered, decided| entered && entered <= day_end && (decided.nil? || decided > day_end) }
          }
        end
      end

      private

      def window_start = (@now - (@period_days - 1).days).beginning_of_day

      def dates = (window_start.to_date..@now.to_date).to_a

      def open_pairs = @pairs.select { |entered, decided| entered && decided.nil? }

      def arrivals_in_period = @pairs.select { |entered, _| entered && entered >= window_start }

      def decided_in_period = @pairs.select { |_, decided| decided && decided >= window_start }

      # Latency only counts items decided inside the window, so the number
      # tracks current turnaround instead of drifting with all-time history.
      # Negative spans are dropped rather than averaged in: a decided_at older
      # than its entered_at is bad data (backfills and state machines that
      # stamp out of order both produce it), and one of them can drag a median
      # below zero.
      def decided_latencies
        @decided_latencies ||= decided_in_period.filter_map do |entered, decided|
          span = (decided - entered) if entered
          span if span&.positive?
        end
      end

      def days_to_clear
        cleared_per_day = decided_in_period.size / @period_days.to_f
        arrived_per_day = arrivals_in_period.size / @period_days.to_f
        net_per_day = cleared_per_day - arrived_per_day
        return if net_per_day <= 0 || open_pairs.empty?

        (open_pairs.size / net_per_day).round(1)
      end

      def percentile_hours(seconds, percentile)
        return if seconds.blank?

        sorted = seconds.sort
        index = ((percentile / 100.0) * (sorted.size - 1)).round
        (sorted[index] / 3600.0).round(1)
      end
    end
  end
end
