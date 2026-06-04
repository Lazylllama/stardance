# frozen_string_literal: true

class Shop::WishlistsController < Shop::BaseController
  private def render_wishlist_widget
    render turbo_stream: turbo_stream.replace(
    "discover-rail-wishlist",
      render_to_string(
        DiscoverRail::ShopWishlistWidget.new(
          user: current_user,
          context: { user_balance: current_user&.cached_balance || 0 }
        ),
        layout: false
      )
    )
  end

  def create
    authorize :shop
    current_user.shop_wishlists.find_or_create_by!(shop_item_id: params[:id])
    render_wishlist_widget
  end

  def destroy
    authorize :shop
    current_user.shop_wishlists.where(shop_item_id: params[:id]).destroy_all
    render_wishlist_widget
  end
end
