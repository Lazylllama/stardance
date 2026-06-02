class AddUserRefToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :user_ref, :string
  end
end
