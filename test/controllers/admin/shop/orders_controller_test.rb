require "test_helper"

class Admin::Shop::OrdersControllerTest < ActionDispatch::IntegrationTest
  include UserFactory

  setup do
    @admin = create_user(slack_id: "U_ORD_ADMIN", display_name: "ord-admin")
    @admin.grant_role!(:admin)
    sign_in @admin

    @item = ShopItem.new(
      name: "Order Sort Test Item",
      description: "d",
      ticket_cost: 0,
      type: "ShopItem::ThirdPartyPhysical",
      enabled: true
    )
    @item.save!(validate: false)

    # Created first (lower id), so the old "ties broken by ascending user_id"
    # behavior would surface bob's group before alice's regardless of sort.
    @bob = create_user(slack_id: "U_ORD_BOB", display_name: "bob")
    @alice = create_user(slack_id: "U_ORD_ALICE", display_name: "alice")

    # alice holds both the oldest and the newest order overall, but has the
    # same order count as bob, whose two orders both fall in between.
    @alice_oldest = create_order(@alice, 4.days.ago)
    @bob_first    = create_order(@bob, 3.days.ago)
    @bob_second   = create_order(@bob, 2.days.ago)
    @alice_newest = create_order(@alice, 1.day.ago)
  end

  test "sorting oldest-first puts the user holding the oldest order first" do
    get admin_shop_orders_path(view: "fulfillment", goob: "true", sort: "created_at_asc")
    assert_response :success

    assert group_order(response.body) == [ "alice", "bob" ]
  end

  test "sorting newest-first (default) puts the user holding the newest order first" do
    get admin_shop_orders_path(view: "fulfillment", goob: "true")
    assert_response :success

    assert group_order(response.body) == [ "alice", "bob" ]
  end

  test "orders within a group still follow the selected sort" do
    get admin_shop_orders_path(view: "fulfillment", goob: "true", sort: "created_at_asc")
    assert_response :success

    alice_index = response.body.index(">alice<")
    order_ids_after_alice = response.body[alice_index..].scan(/#(\d+)<\/td>/).first(2).flatten.map(&:to_i)
    assert_equal [ @alice_oldest.id, @alice_newest.id ], order_ids_after_alice
  end

  private

  def group_order(body)
    body.scan(/shop-orders__group-name">\s*<a[^>]*>([^<]+)</).flatten
  end

  def create_order(user, created_at)
    order = user.shop_orders.new(shop_item: @item, quantity: 1)
    order.aasm_state = "awaiting_periodical_fulfillment"
    order.save!(validate: false)
    order.update_column(:created_at, created_at)
    order
  end
end
