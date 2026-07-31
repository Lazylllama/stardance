module Admin
  class DashboardCountsController < ApplicationController
    layout false

    COUNTS = {
      "shop_fulfillment" => -> {
        ::ShopOrder.where(aasm_state: "awaiting_periodical_fulfillment").count
      },
      "fraud_checks" => -> {
        ::ShopOrder.where(aasm_state: "pending").count +
          ::Project::Report.pending.where(reason: "fraud").count
      },
      "ship_certifications" => -> {
        policy_scope(::Certification::Ship).where(status: "pending").count
      },
      "ysws_reviews" => -> {
        ::Certification::Ysws.pending.count
      },
      "mission_reviews" => -> {
        ::Mission::Submission.where(status: "pending", deleted_at: nil).count
      },
      "super_stars" => -> {
        ::Project.fire_nomination_pending.count
      }
    }.freeze

    def show
      authorize :admin, :index?
      count = COUNTS[params[:key]]
      return head :not_found unless count

      @key = params[:key]
      @count = instance_exec(&count)
    end
  end
end
