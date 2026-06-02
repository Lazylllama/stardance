class CreatePostReposts < ActiveRecord::Migration[8.1]
  def change
    create_table :post_reposts do |t|
      t.string :body
      t.references :original_post, null: false, foreign_key: { to_table: :posts }
      t.references :user, null: false, foreign_key: true

      t.timestamps
    end

    add_index :post_reposts, [ :original_post_id, :user_id ], unique: true
    add_column :posts, :reposts_count, :integer, default: 0, null: false
    change_column_null :posts, :project_id, true
  end
end
