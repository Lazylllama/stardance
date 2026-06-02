class AddDeletedAtToPostReposts < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :post_reposts, :deleted_at, :datetime
    add_index :post_reposts, :deleted_at, algorithm: :concurrently

    remove_index :post_reposts, column: [ :original_post_id, :user_id ],
                 algorithm: :concurrently, if_exists: true
    add_index :post_reposts, [ :original_post_id, :user_id ],
              unique: true,
              where: "deleted_at IS NULL",
              name: "index_post_reposts_active_unique",
              algorithm: :concurrently
  end
end
