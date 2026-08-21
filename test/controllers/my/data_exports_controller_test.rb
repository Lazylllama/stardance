require "test_helper"

class My::DataExportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @alice = create_user(slack_id: "U_ALICE", display_name: "alice")
    @bob = create_user(slack_id: "U_BOB", display_name: "bob")
    sign_in(@alice)
  end

  test "index renders the export page" do
    get my_data_exports_path
    assert_response :success
    assert_select "h1", text: "Export My Data"
  end

  test "create enqueues an export job" do
    assert_enqueued_with job: User::DataExportJob do
      post my_data_exports_path
    end

    assert_equal 1, @alice.data_exports.count
    assert_response :redirect
  end

  test "create blocks when an export is already in progress" do
    @alice.data_exports.create!(status: "processing")

    assert_no_enqueued_jobs only: User::DataExportJob do
      post my_data_exports_path
    end

    assert_equal 1, @alice.data_exports.count
  end

  test "show redirects to the zip when download is available" do
    export = @alice.data_exports.create!(status: "completed")
    export.zip_file.attach(
      io: StringIO.new("fake zip"),
      filename: "export.zip",
      content_type: "application/zip"
    )

    get my_data_export_path(export)
    assert_response :redirect
    assert_match(/rails\/active_storage/, response.redirect_url)
  end

  test "show refuses downloads that are not ready" do
    export = @alice.data_exports.create!(status: "pending")

    get my_data_export_path(export)
    assert_redirected_to my_data_exports_path
  end

  test "show cannot download another user's export" do
    export = @bob.data_exports.create!(status: "completed")

    get my_data_export_path(export)
    assert_response :not_found
  end

  test "logged out users are bounced" do
    delete logout_path
    get my_data_exports_path
    assert_response :redirect
  end
end
