require 'rails_helper'

# == Schema Information
#
# Table name: mission_prize_redemptions
#
#  id               :bigint           not null, primary key
#  source_type      :string           not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  mission_id       :bigint           not null
#  mission_prize_id :bigint           not null
#  shop_order_id    :bigint           not null
#  source_id        :bigint           not null
#  user_id          :bigint           not null
#
# Indexes
#
#  index_mission_prize_redemptions_on_mission_id        (mission_id)
#  index_mission_prize_redemptions_on_mission_prize_id  (mission_prize_id)
#  index_mission_prize_redemptions_on_shop_order_id     (shop_order_id) UNIQUE
#  index_mission_prize_redemptions_on_source            (source_type,source_id)
#  index_mission_prize_redemptions_on_user_id           (user_id)
#  index_prize_redemptions_on_source_and_prize          (source_type,source_id,mission_prize_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (mission_id => missions.id)
#  fk_rails_...  (mission_prize_id => mission_prizes.id)
#  fk_rails_...  (shop_order_id => shop_orders.id)
#  fk_rails_...  (user_id => users.id)
#
RSpec.describe Mission::PrizeRedemption, type: :model do
  pending "add some examples to (or delete) #{__FILE__}"
end
