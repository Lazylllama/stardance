# frozen_string_literal: true

module Growth
  # Duolingo's lever analysis: project DAU forward from today's states using
  # the recent transition rates, then again with one retention rate improved
  # a little each month, and rank the rates by how much DAU they add.
  class Simulator
    WINDOW = 14
    HORIZON_DAYS = 90
    MONTHLY_LIFT = 0.02
    LEVERS = %w[nurr curr rurr surr iwaurr reactivation resurrection].freeze
    # Where a state's users go when the window saw nobody leave it.
    DECAY = {
      "new" => "at_risk_wau",
      "current" => "at_risk_wau",
      "reactivated" => "at_risk_wau",
      "resurrected" => "at_risk_wau",
      "at_risk_wau" => "at_risk_mau",
      "at_risk_mau" => "dormant",
      "dormant" => "dormant"
    }.freeze

    Lever = Data.define(:rate, :current_rate, :dau, :lift)

    # `snapshots` are one metric's, oldest first.
    def initialize(snapshots)
      recent = snapshots.last(WINDOW)
      @start = GrowthDailySnapshot::STATES.to_h { |state| [ state, recent.last.count_for(state).to_f ] }
      @new_per_day = recent.sum(&:new_users).fdiv(recent.size)
      @matrix = pooled_matrix(recent)
    end

    def baseline_dau = @baseline_dau ||= project

    def levers
      LEVERS.filter_map do |rate|
        from, to = GrowthDailySnapshot::RATES.fetch(rate)
        current_rate = @matrix[from].fetch(to, 0.0)
        next if current_rate.zero?

        dau = project(lever: [ from, to ])
        Lever.new(rate:, current_rate:, dau:, lift: dau - baseline_dau)
      end.sort_by { |lever| -lever.lift }
    end

    private

    def pooled_matrix(snapshots)
      GrowthDailySnapshot::STATES.index_with do |from|
        targets = Hash.new(0)
        snapshots.each { |snapshot| snapshot.transitions.fetch(from, {}).each { |to, users| targets[to] += users } }
        total = targets.values.sum
        total.zero? ? { DECAY.fetch(from) => 1.0 } : targets.transform_values { |users| users.fdiv(total) }
      end
    end

    def project(lever: nil)
      counts = @start
      HORIZON_DAYS.times do |day|
        matrix = lever ? lifted(lever, (1 + MONTHLY_LIFT)**((day + 1) / 30.0)) : @matrix
        counts = step(counts, matrix)
      end
      GrowthDailySnapshot::ACTIVE_STATES.sum { |state| counts[state] }
    end

    def step(counts, matrix)
      following = Hash.new(0.0)
      counts.each do |from, users|
        matrix.fetch(from).each { |to, share| following[to] += users * share }
      end
      following["new"] = @new_per_day
      following
    end

    # Raises one transition by `factor`, capped at 1, and scales the rest of
    # its row down so the row still sums to 1.
    def lifted((from, to), factor)
      row = @matrix.fetch(from)
      rate = row.fetch(to, 0.0)
      raised = [ rate * factor, 1.0 ].min
      rest = rate < 1 ? (1 - raised) / (1 - rate) : 0.0

      @matrix.merge(from => row.to_h { |target, share| [ target, target == to ? raised : share * rest ] })
    end
  end
end
