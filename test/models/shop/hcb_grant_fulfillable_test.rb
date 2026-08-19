require "test_helper"

# Guards the money path: an HCB grant must never be disbursed twice because a
# later step failed and someone retried. The dangerous windows are all between
# "HCB moved money" and "the order says so".
class Shop::HCBGrantFulfillableTest < ActiveSupport::TestCase
  include UserFactory

  GRANT_RESPONSE = { "id" => "grt_test", "disbursements" => [ { "transaction_id" => "txn_test" } ] }.freeze

  setup do
    @user = create_user(slack_id: "u-hcb", display_name: "grantee", verified: true)
    @user.update!(has_gotten_free_stickers: true)

    @item = ShopItem::HCBGrant.new(
      name: "Test Grant",
      description: "A grant item",
      ticket_cost: 0,
      usd_cost: 25,
      enabled: true
    )
    @item.image.attach(
      io: StringIO.new(Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")),
      filename: "px.png", content_type: "image/png"
    )
    @item.save!
    @order = @user.shop_orders.create!(
      shop_item: @item, quantity: 1,
      frozen_address: { "country" => "US", "primary" => true }
    )
  end

  test "a grant is created once and the order is fulfilled" do
    HCBService.stub(:create_card_grant, GRANT_RESPONSE) do
      HCBService.stub(:rename_transaction, true) { @item.fulfill!(@order) }
    end

    assert @order.reload.fulfilled?
    assert_equal "grt_test", @order.shop_card_grant.hcb_grant_hashid
    assert_equal 1, ShopCardGrant.where(user: @user, shop_item: @item).count
  end

  test "a retry after the state change is lost does not disburse again" do
    HCBService.stub(:create_card_grant, GRANT_RESPONSE) do
      HCBService.stub(:rename_transaction, true) { @item.fulfill!(@order) }
    end

    # Exactly the window that used to double-pay: the grant landed and the
    # order is linked to it, but the order is somehow back in the queue.
    @order.update!(aasm_state: "pending")

    topups = 0
    HCBService.stub(:topup_card_grant, ->(**) { topups += 1; GRANT_RESPONSE }) do
      HCBService.stub(:create_card_grant, ->(**) { flunk "must not create a second grant" }) do
        @item.fulfill!(@order)
      end
    end

    assert_equal 0, topups, "the disbursement for this order already happened"
    assert @order.reload.fulfilled?
  end

  test "an HCB error during creation leaves nothing behind to block a retry" do
    exploding = ->(**) { raise HCBError, "HCB returned 400: invalid_grant" }

    assert_raises(HCBError) do
      HCBService.stub(:create_card_grant, exploding) { @item.fulfill!(@order) }
    end

    assert_empty ShopCardGrant.where(user: @user, shop_item: @item),
                 "a refused request created no grant, so it must leave no claim"
    assert @order.reload.pending?

    # And the retry goes through cleanly.
    HCBService.stub(:create_card_grant, GRANT_RESPONSE) do
      HCBService.stub(:rename_transaction, true) { @item.fulfill!(@order) }
    end

    assert @order.reload.fulfilled?
  end

  test "an ambiguous failure stops the next attempt instead of granting twice" do
    # A timeout is not an answer: HCB may or may not have created the grant.
    timing_out = ->(**) { raise Faraday::TimeoutError, "execution expired" }

    assert_raises(Faraday::TimeoutError) do
      HCBService.stub(:create_card_grant, timing_out) { @item.fulfill!(@order) }
    end

    claim = ShopCardGrant.find_by(user: @user, shop_item: @item)
    assert claim, "an unanswered request must leave evidence a grant may exist"
    assert_nil claim.hcb_grant_hashid

    error = assert_raises(HCBError) do
      HCBService.stub(:create_card_grant, ->(**) { flunk "must not create a second grant" }) do
        @item.fulfill!(@order)
      end
    end

    assert_match(/reconcile it by hand/, error.message)
    assert @order.reload.pending?
  end

  test "a cancelled grant is replaced rather than topped up" do
    ShopCardGrant.create!(user: @user, shop_item: @item, hcb_grant_hashid: "grt_dead", expected_amount_cents: 100)

    HCBService.stub(:show_card_grant, { "status" => "canceled" }) do
      HCBService.stub(:create_card_grant, GRANT_RESPONSE) do
        HCBService.stub(:rename_transaction, true) { @item.fulfill!(@order) }
      end
    end

    assert_equal "grt_test", @order.reload.shop_card_grant.hcb_grant_hashid
  end

  test "a second order tops up the existing grant" do
    ShopCardGrant.create!(user: @user, shop_item: @item, hcb_grant_hashid: "grt_live", expected_amount_cents: 100)

    topped = 0
    HCBService.stub(:show_card_grant, { "status" => "active" }) do
      HCBService.stub(:topup_card_grant, ->(**) { topped += 1; GRANT_RESPONSE }) do
        HCBService.stub(:rename_transaction, true) { @item.fulfill!(@order) }
      end
    end

    assert_equal 1, topped
    assert @order.reload.fulfilled?
    assert_equal 2600, ShopCardGrant.find_by(hcb_grant_hashid: "grt_live").expected_amount_cents
  end
end
