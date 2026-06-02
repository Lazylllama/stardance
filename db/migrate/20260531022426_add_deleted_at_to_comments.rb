class AddDeletedAtToComments < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :comments, :deleted_at, :datetime
    add_index :comments, :deleted_at, algorithm: :concurrently
  end
end
