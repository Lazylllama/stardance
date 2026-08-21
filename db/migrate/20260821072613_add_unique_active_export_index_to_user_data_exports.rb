class AddUniqueActiveExportIndexToUserDataExports < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :user_data_exports, :user_id,
              unique: true,
              where: "status IN ('pending', 'processing')",
              name: "index_user_data_exports_on_user_id_active",
              algorithm: :concurrently
  end
end
