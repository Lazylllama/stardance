require "test_helper"

class Growth::SimulatorTest < ActiveSupport::TestCase
  test "ranks retention levers by the DAU they add" do
    simulator = Growth::Simulator.new([ snapshot ] * 3)
    levers = simulator.levers

    assert levers.all? { |lever| lever.lift.positive? }
    assert_equal levers.map(&:lift).sort.reverse, levers.map(&:lift)
    assert_equal "curr", levers.first.rate
    assert_in_delta 0.8, levers.find { |lever| lever.rate == "curr" }.current_rate
  end

  test "rates the window never saw are not levers" do
    levers = Growth::Simulator.new([ snapshot ]).levers.map(&:rate)

    assert_not_includes levers, "surr"
    assert_not_includes levers, "rurr"
  end

  private

  def snapshot
    GrowthDailySnapshot.new(
      metric: "engaged", snapshot_on: Date.new(2026, 9, 30),
      new_users: 10, current_users: 100, at_risk_wau: 50, at_risk_mau: 40, dormant_users: 200,
      transitions: {
        "new" => { "current" => 4, "at_risk_wau" => 6 },
        "current" => { "current" => 80, "at_risk_wau" => 20 },
        "at_risk_wau" => { "current" => 5, "at_risk_wau" => 35, "at_risk_mau" => 10 },
        "at_risk_mau" => { "reactivated" => 2, "at_risk_mau" => 33, "dormant" => 5 },
        "dormant" => { "resurrected" => 1, "dormant" => 199 }
      }
    )
  end
end
