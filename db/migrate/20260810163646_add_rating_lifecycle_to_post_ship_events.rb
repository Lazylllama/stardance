class AddRatingLifecycleToPostShipEvents < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :post_ship_events, :voting_started_at, :datetime
    add_column :post_ship_events, :voting_completed_at, :datetime
    add_column :post_ship_events, :paid_at, :datetime
    add_column :post_ship_events, :lifecycle_data_quality, :string

    add_index :post_ship_events, :voting_started_at, algorithm: :concurrently
    add_index :post_ship_events, :voting_completed_at, algorithm: :concurrently
    add_index :post_ship_events, :paid_at, algorithm: :concurrently
  end
end
