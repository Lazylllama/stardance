module Admin
  module MegaDashboard
    # Declarative registry of every review queue on the dashboard.
    #
    # Each queue exposes the same six facts (depth, unclaimed, arrivals,
    # decisions, latency, oldest waiting), which is what lets one panel
    # template render all of them. A queue is described by the relation its
    # items live in plus the SQL for when an item entered and left the queue;
    # everything else is derived.
    class Queue
      Definition = Data.define(:key, :label, :entered_at, :decided_at, :sla_hours, :scope, :pending, :unclaimed, :path, :pairs) do
        def unclaimed_count = unclaimed ? unclaimed.call.count : nil

        def claimable? = !unclaimed.nil?

        def url = path.call(Rails.application.routes.url_helpers)

        # [entered_at, decided_at] for every item that was in the queue at any
        # point from `since` onward, plus everything still open. One query per
        # queue: the per-day series are folded out of this in Ruby, since a
        # backlog-per-day SQL query would be one round trip per day.
        def timestamp_pairs(since)
          return pairs.call(since) if pairs

          scope.call
               .where("#{decided_at} IS NULL OR #{decided_at} >= ?", since)
               .where("#{entered_at} IS NOT NULL")
               .pluck(Arel.sql(entered_at), Arel.sql(decided_at))
        end
      end

      REGISTRY = [
        {
          key: "ship_certifications",
          label: "Ship certifications",
          scope: -> { ::Certification::Ship.software_only },
          pending: -> { ::Certification::Ship.software_only.where(status: :pending) },
          unclaimed: -> { ::Certification::Ship.software_only.where(status: :pending, claimed_at: nil) },
          entered_at: "certification_ship_reviews.created_at",
          decided_at: "certification_ship_reviews.decided_at",
          sla_hours: ::Certification::Ship::SLA_DAYS * 24,
          path: ->(h) { h.admin_certification_ships_path }
        },
        {
          key: "ysws_reviews",
          label: "YSWS reviews (GOI)",
          scope: -> { ::Certification::Ysws.all },
          pending: -> { ::Certification::Ysws.pending },
          unclaimed: -> { ::Certification::Ysws.pending.where(claimed_at: nil) },
          entered_at: "certification_ysws_reviews.created_at",
          decided_at: "COALESCE(certification_ysws_reviews.reviewed_at, certification_ysws_reviews.returned_at)",
          sla_hours: 72,
          path: ->(h) { h.admin_certification_ysws_reviews_path }
        },
        {
          key: "mission_reviews",
          label: "Mission reviews",
          scope: -> { ::Mission::Submission.where(deleted_at: nil) },
          pending: -> { ::Mission::Submission.where(deleted_at: nil, status: "pending") },
          unclaimed: -> { ::Mission::Submission.where(deleted_at: nil, status: "pending", claimed_at: nil) },
          entered_at: "COALESCE(mission_submissions.pending_at, mission_submissions.created_at)",
          decided_at: "mission_submissions.reviewed_at",
          sla_hours: 72,
          path: ->(h) { h.admin_mission_reviews_path }
        },
        {
          key: "fraud_orders",
          label: "Shop orders (fraud)",
          scope: -> { ::ShopOrder.all },
          pending: -> { ::ShopOrder.where(aasm_state: ::ShopOrder::REVIEW_QUEUE_STATES) },
          unclaimed: nil,
          entered_at: "shop_orders.created_at",
          decided_at: ::ShopOrder::DECIDED_AT_SQL,
          sla_hours: ::ShopOrder::LONG_WAIT_DAYS * 24,
          path: ->(h) { h.admin_fraud_path }
        },
        {
          key: "fraud_reports",
          label: "Fraud reports",
          # Every internally-raised reason, not just the literal "fraud" one.
          # Reviewers flag through report_fraud on the ship and YSWS queues,
          # which writes "Shipwrights project flag" / "YSWS project flag", so
          # filtering on "fraud" alone misses every reviewer-raised report.
          scope: -> { ::Project::Report.where(reason: ::Project::Report::REASONS - ::Project::Report::USER_REASONS) },
          pending: -> { ::Project::Report.where(reason: ::Project::Report::REASONS - ::Project::Report::USER_REASONS).pending },
          unclaimed: nil,
          entered_at: "project_reports.created_at",
          decided_at: "CASE WHEN project_reports.status = 0 THEN NULL ELSE project_reports.updated_at END",
          sla_hours: 72,
          path: ->(h) { h.admin_fraud_path }
        },
        {
          key: "integrity_reviews",
          label: "Integrity reviews",
          scope: -> { ::Certification::Integrity.all },
          pending: -> { ::Certification::Integrity.pending },
          unclaimed: -> { ::Certification::Integrity.pending.where(claimed_at: nil) },
          entered_at: "certification_integrities.created_at",
          decided_at: "certification_integrities.reviewed_at",
          sla_hours: 48,
          path: ->(h) { h.admin_certification_integrity_reviews_path }
        },
        {
          key: "shop_fulfillment",
          label: "Shop fulfillment",
          scope: -> { ::ShopOrder.all },
          pending: -> { ::ShopOrder.where(aasm_state: "awaiting_periodical_fulfillment") },
          unclaimed: -> { ::ShopOrder.where(aasm_state: "awaiting_periodical_fulfillment", assigned_to_user_id: nil) },
          entered_at: "shop_orders.awaiting_periodical_fulfillment_at",
          decided_at: "shop_orders.fulfilled_at",
          sla_hours: 7 * 24,
          path: ->(h) { h.admin_shop_orders_path(view: "fulfillment", status: "awaiting_periodical_fulfillment") }
        },
        {
          key: "hardware_design",
          label: "Hardware design (funding)",
          scope: -> { ::Certification::FundingRequest.all },
          pending: -> { ::Certification::FundingRequest.where(status: :pending) },
          unclaimed: -> { ::Certification::FundingRequest.where(status: :pending, claimed_at: nil) },
          entered_at: "certification_funding_requests.created_at",
          decided_at: "certification_funding_requests.decided_at",
          sla_hours: ::Certification::FundingRequest::SLA_DAYS * 24,
          path: ->(h) { h.design_admin_certification_hardware_reviews_path }
        },
        {
          key: "payout_reviews",
          label: "Payout reviews",
          scope: -> { ::Post::ShipEvent.approved.voting_payout_path },
          pending: -> { ::Post::ShipEvent.ready_for_payout },
          unclaimed: nil,
          entered_at: "post_ship_events.voting_completed_at",
          decided_at: "post_ship_events.paid_at",
          sla_hours: (::Post::ShipEvent::Payouts::PAYOUT_REVIEW_WINDOW / 1.hour).to_i,
          path: ->(h) { h.admin_payout_reviews_path }
        },
        {
          key: "vote_flags",
          label: "Vote flags",
          scope: -> { ::Vote::Event.vote_flags },
          pending: -> { ::Vote::Event.pending_vote_flags },
          unclaimed: nil,
          entered_at: "vote_events.created_at",
          decided_at: nil,
          sla_hours: 72,
          # A flag is resolved by a separate event row rather than a column, so
          # the entered/decided pairing is a join instead of the generic scan.
          pairs: ->(since) {
            resolutions = ::Vote::Event.resolved_vote_flags.pluck(:vote_id, :created_at).to_h
            ::Vote::Event.vote_flags.pluck(:vote_id, :created_at).map do |vote_id, created_at|
              resolved_at = resolutions[vote_id]
              next if resolved_at && resolved_at < since

              [ created_at, resolved_at ]
            end.compact
          },
          path: ->(h) { h.admin_vote_flags_path }
        },
        {
          key: "super_stars",
          label: "Super star nominations",
          scope: -> { ::Project.where.not(nominated_fire_at: nil) },
          pending: -> { ::Project.fire_nomination_pending },
          unclaimed: nil,
          entered_at: "projects.nominated_fire_at",
          decided_at: "projects.marked_fire_at",
          sla_hours: 7 * 24,
          path: ->(h) { h.admin_super_stars_path }
        },
        {
          key: "certificates",
          label: "Certificates",
          scope: -> { ::Certificate.all },
          pending: -> { ::Certificate.pending },
          unclaimed: nil,
          entered_at: "certificates.created_at",
          decided_at: "CASE WHEN certificates.status = 'pending' THEN NULL ELSE certificates.updated_at END",
          sla_hours: 72,
          path: ->(h) { h.admin_certificates_path }
        }
      ].freeze

      def self.all
        @all ||= REGISTRY.map { |attrs| Definition.new(**{ pairs: nil }.merge(attrs)) }
      end

      def self.find(key)
        all.find { |queue| queue.key == key }
      end

      def self.keys = all.map(&:key)
    end
  end
end
