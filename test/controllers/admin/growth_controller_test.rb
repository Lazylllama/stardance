require "test_helper"

class Admin::GrowthControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @admin = User.create!(slack_id: "U_GROWTH_ADMIN", display_name: "growth_admin", email: "growth_admin@example.test")
    @admin.grant_role!(:admin)
  end

  test "admin sees a DAU chart per metric and the lever table" do
    GrowthDailySnapshot.create!(
      metric: "coding", snapshot_on: UserActivityDay.today - 1,
      new_users: 2, current_users: 30, at_risk_wau: 10,
      transitions: { "current" => { "current" => 24, "at_risk_wau" => 6 } }
    )
    sign_in @admin

    get admin_growth_path(metric: "coding")

    assert_response :success
    assert_select "canvas[data-controller=growth-chart]", minimum: GrowthDailySnapshot::METRICS.size
    assert_select ".growth__metric--selected", text: /Coding/
    assert_match "32 DAU", response.body
    assert_select ".growth__table th", text: "CURR"
    assert_select ".growth__toggle-option--active", text: "Word of mouth"
    assert_match "Projected, no change", response.body
  end

  test "signups can be held flat" do
    GrowthDailySnapshot.create!(metric: "coding", snapshot_on: UserActivityDay.today - 1, new_users: 2, current_users: 30)
    sign_in @admin

    get admin_growth_path(signups: "flat")

    assert_response :success
    assert_select ".growth__toggle-option--active", text: "Flat"
  end

  test "coding is the default metric and is marked as the source of truth" do
    GrowthDailySnapshot.create!(metric: "coding", snapshot_on: UserActivityDay.today - 1, new_users: 2, current_users: 30)
    sign_in @admin

    get admin_growth_path

    assert_response :success
    assert_select ".growth__metric--selected", text: /Coding.*Source of truth/m
    assert_no_match "For comparison only", response.body
  end

  test "other metrics say they are for comparison only" do
    GrowthDailySnapshot.create!(metric: "vote", snapshot_on: UserActivityDay.today - 1, new_users: 1, current_users: 5)
    sign_in @admin

    get admin_growth_path(metric: "vote")

    assert_response :success
    assert_match "For comparison only", response.body
  end

  test "an unknown metric falls back to the source of truth and shows the empty state" do
    sign_in @admin

    get admin_growth_path(metric: "nonsense")

    assert_response :success
    assert_match "No snapshots yet", response.body
  end

  test "rebuild enqueues the refresh and leaves an audit entry" do
    sign_in @admin

    assert_enqueued_with(job: GrowthRefreshJob, args: [ { days: Admin::GrowthController::REBUILD_DAYS } ]) do
      assert_difference -> { PaperTrail::Version.where(event: "rebuild_growth_model").count } do
        post rebuild_admin_growth_path
      end
    end
    assert_redirected_to admin_growth_path
  end

  test "non-admin is denied" do
    user = User.create!(slack_id: "U_GROWTH_USER", display_name: "growth_user", email: "growth_user@example.test")
    sign_in user

    get admin_growth_path

    assert_response :not_found
  end
end
