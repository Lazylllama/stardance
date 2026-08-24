require "test_helper"

class TelescreenHelperTest < ActionView::TestCase
  test "subject url uppercases slack ids" do
    assert_equal "https://telescreen.hackclub.com/subjects/U080A3QP42C",
                 telescreen_subject_url("u080a3qp42c")
  end

  test "subject url leaves numeric hackatime ids alone" do
    assert_equal "https://telescreen.hackclub.com/subjects/26105",
                 telescreen_subject_url("26105")
  end

  test "subject url is blank without an identifier" do
    assert_nil telescreen_subject_url(nil)
    assert_nil telescreen_subject_url("")
  end

  test "hackatime overview url filters by project" do
    assert_equal "https://telescreen.hackclub.com/workbench/hackatime/overview?p=arcade-game&u=26105",
                 telescreen_hackatime_overview_url("26105", project: "arcade-game")
  end

  test "hackatime url resolves slack ids on the day view" do
    assert_equal "https://telescreen.hackclub.com/workbench/hackatime?slack=U080A3QP42C",
                 telescreen_hackatime_url(slack_id: "u080a3qp42c")
  end

  test "displayed case url rewrites joe profile and case links" do
    assert_equal "https://telescreen.hackclub.com/subjects/U080A3QP42C",
                 displayed_telescreen_url("https://joe.fraud.hackclub.com/profile/u080a3qp42c")
    assert_equal "https://telescreen.hackclub.com/joe/cases/2518",
                 displayed_telescreen_url("https://joe.fraud.hackclub.com/cases/2518")
  end

  test "displayed case url leaves unknown hosts alone" do
    url = "https://example.com/cases/2518"
    assert_equal url, displayed_telescreen_url(url)
  end
end
