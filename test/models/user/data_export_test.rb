require "test_helper"

class User::DataExportTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  setup do
    @user = create_user(slack_id: "U_DATA_EXPORT", display_name: "data-exporter")
  end

  test "exports expire after seven days" do
    export = @user.data_exports.create!(status: "completed", created_at: 7.days.ago - 1.second)

    assert_predicate export, :expired?
    refute_predicate export, :download_available?
  end

  test "purge expired deletes only exports older than seven days" do
    expired_export = @user.data_exports.create!(status: "completed", created_at: 8.days.ago)
    expired_export.zip_file.attach(
      io: StringIO.new("fake zip"),
      filename: "expired.zip",
      content_type: "application/zip"
    )
    expired_blob_id = expired_export.zip_file.blob.id
    current_export = @user.data_exports.create!(status: "completed")

    perform_enqueued_jobs { User::DataExport.purge_expired! }

    refute User::DataExport.exists?(expired_export.id)
    refute ActiveStorage::Blob.exists?(expired_blob_id)
    assert User::DataExport.exists?(current_export.id)
  end
end
