require "test_helper"
require "base64"

class HomeControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @user.update!(verification_status: :verified, ysws_eligible: true)
    @project = projects(:one)
    @other_project = projects(:two)
    @project.update!(title: "Current user project")
    @other_project.update!(title: "Recommended project")
    @devlog = create_devlog(body: "Home feed update")
    @post = Post.create!(project: @other_project, user: users(:two), postable: @devlog)
  end

  test "home page loads the shell and lazy feed frame for signed in user" do
    sign_in @user

    get home_path

    assert_response :success
    assert_select ".feed-composer"
    assert_select "turbo-frame#home_feed[src=?]", home_feed_path
  end

  private

  def create_devlog(body:)
    devlog = Post::Devlog.new(body: body, duration_seconds: 1.hour)
    devlog.attachments.attach(
      io: StringIO.new(Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")),
      filename: "progress.png",
      content_type: "image/png"
    )
    devlog.save!
    devlog
  end
end
