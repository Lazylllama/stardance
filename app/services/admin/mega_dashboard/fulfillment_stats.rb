module Admin
  module MegaDashboard
    # What is sitting in fulfillment, grouped the way the fulfillment team
    # actually splits the work rather than by raw item class.
    class FulfillmentStats
      GROUPS = {
        "HQ mail" => %w[ShopItem::HQMailItem ShopItem::LetterMail ShopItem::NonmachinableLetterMail],
        "Third party" => %w[ShopItem::ThirdPartyPhysical ShopItem::Accessory ShopItem::ThirdPartyDigital ShopItem::Inkthreadable],
        "Warehouse" => %w[ShopItem::WarehouseItem]
      }.freeze

      # Warehouse orders older than this are the ones that quietly rot.
      STALE_WAREHOUSE_DAYS = 3
      RECENT_ITEM_LIMIT = 12

      def initialize(now: Time.current)
        @now = now
      end

      def to_h
        awaiting = ::ShopOrder.joins(:shop_item)
                              .where(aasm_state: "awaiting_periodical_fulfillment")
                              .where.not(shop_items: { type: "ShopItem::FreeStickers" })
                              .group("shop_items.type").count
        fulfilled = ::ShopOrder.joins(:shop_item)
                               .where(aasm_state: "fulfilled")
                               .where.not(shop_items: { type: "ShopItem::FreeStickers" })
                               .group("shop_items.type").count

        {
          groups: build_groups(awaiting, fulfilled),
          stale_warehouse: stale_warehouse_count,
          stale_days: STALE_WAREHOUSE_DAYS,
          recent_items: ::ShopItem.recently_added.enabled.limit(RECENT_ITEM_LIMIT).pluck(:name)
        }
      end

      private

      def build_groups(awaiting, fulfilled)
        known = GROUPS.values.flatten
        rows = GROUPS.map do |label, types|
          { label: label, awaiting: sum_for(awaiting, types), fulfilled: sum_for(fulfilled, types) }
        end

        other_types = (awaiting.keys + fulfilled.keys).uniq - known
        rows << { label: "Other", awaiting: sum_for(awaiting, other_types), fulfilled: sum_for(fulfilled, other_types) }
        rows << { label: "All", awaiting: awaiting.values.sum, fulfilled: fulfilled.values.sum }
        rows
      end

      def sum_for(counts, types) = counts.select { |type, _| types.include?(type) }.values.sum

      def stale_warehouse_count
        ::ShopOrder.joins(:shop_item)
                   .where(aasm_state: "awaiting_periodical_fulfillment")
                   .where(shop_items: { type: "ShopItem::WarehouseItem" })
                   .where("shop_orders.awaiting_periodical_fulfillment_at <= ?", STALE_WAREHOUSE_DAYS.days.ago)
                   .count
      end
    end
  end
end
