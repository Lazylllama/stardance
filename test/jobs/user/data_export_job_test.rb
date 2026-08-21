require "test_helper"
require "zip"
require "base64"

class User::DataExportJobTest < ActiveJob::TestCase
  setup do
    @user = create_user(slack_id: "U_EXPORT", display_name: "exporter")
    @project = Project.create!(title: "My Cool Project", description: "desc")
    Project::Membership.create!(user: @user, project: @project)

    @devlog = Post::Devlog.new(body: "Devlog body text", duration_seconds: 1.hour)
    @devlog.attachments.attach(
      io: StringIO.new(Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")),
      filename: "progress.png",
      content_type: "image/png"
    )
    @devlog.save!
    Post.create!(project: @project, user: @user, postable: @devlog)

    @export = @user.data_exports.create!(status: "pending")
  end

  test "generates a completed export with profile, project, and devlog entries" do
    User::DataExportJob.new.perform(@export.id)

    @export.reload
    assert_equal "completed", @export.status
    assert @export.zip_file.attached?
    assert @export.zip_filename.present?

    entries = zip_entry_names(@export)

    assert_includes entries, "profile.json"
    assert_includes entries, "README.md"
    assert_includes entries, "projects/my-cool-project-#{@project.id}/project.json"
    assert_includes entries, "projects/my-cool-project-#{@project.id}/devlogs/devlog-#{@devlog.id}.md"
    assert_includes entries, "projects/my-cool-project-#{@project.id}/devlogs/attachments/#{@devlog.id}-1.png"
  end

  test "keeps attachments from different devlogs in distinct entries" do
    second_devlog = Post::Devlog.new(body: "Second devlog", duration_seconds: 1.hour)
    second_devlog.attachments.attach(
      io: StringIO.new(Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")),
      filename: "progress.png",
      content_type: "image/png"
    )
    second_devlog.save!
    Post.create!(project: @project, user: @user, postable: second_devlog)

    User::DataExportJob.new.perform(@export.id)

    entries = zip_entry_names(@export.reload)
    devlog_dir = "projects/my-cool-project-#{@project.id}/devlogs"
    assert_includes entries, "#{devlog_dir}/attachments/#{@devlog.id}-1.png"
    assert_includes entries, "#{devlog_dir}/attachments/#{second_devlog.id}-1.png"
  end

  test "zip contents include user and project data" do
    User::DataExportJob.new.perform(@export.id)

    @export.reload
    profile = JSON.parse(zip_entry_content(@export, "profile.json"))
    assert_equal @user.display_name, profile["display_name"]

    project_json = JSON.parse(zip_entry_content(@export, "projects/my-cool-project-#{@project.id}/project.json"))
    assert_equal "My Cool Project", project_json["title"]
  end

  test "marks export as failed when generation raises" do
    boom = ->(*) { raise StandardError, "boom" }

    Zip::OutputStream.stub(:open, boom) do
      assert_raises(StandardError) do
        User::DataExportJob.new.perform(@export.id)
      end
    end

    @export.reload
    assert_equal "failed", @export.status
    assert_match(/boom/, @export.error_message)
    refute @export.zip_file.attached?
  end

  private

  def zip_entry_names(export)
    entry_names = []
    export.zip_file.open do |file|
      Zip::File.open_buffer(file.read) do |zip|
        entry_names = zip.entries.map(&:name)
      end
    end
    entry_names
  end

  def zip_entry_content(export, name)
    content = nil
    export.zip_file.open do |file|
      Zip::File.open_buffer(file.read) do |zip|
        content = zip.find_entry(name).get_input_stream.read
      end
    end
    content
  end
end
