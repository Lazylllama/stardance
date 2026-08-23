module ExternalDashboard
  class ReviewerPayoutStatusProcessor
    TEST_CONNECTION_SLACK_ID = "test".freeze

    Result = Struct.new(:status, :body, keyword_init: true)

    def self.call(slack_id:)
      new(slack_id).call
    end

    def initialize(slack_id)
      @slack_id = slack_id.to_s.presence
    end

    def call
      return ok_test if slack_id == TEST_CONNECTION_SLACK_ID
      return error(:bad_request, "missing slackId") if slack_id.nil?

      user = User.find_by(slack_id: slack_id)
      return error(:not_found, "no Stardance user for slackId=#{slack_id.inspect}") if user.nil?

      pending = ::ReviewerPayoutRequest.pending_for(user)
      history = ::ReviewerPayoutRequest.history_for(user)

      ok(
        user: { slackId: user.slack_id, displayName: user.display_name },
        availableBalance: ::ReviewerPayoutRequest.available_to_request_for(user),
        pendingRequest: pending && pending_json(pending),
        requests: history.map { |request| request_json(request) }
      )
    end

    private

    attr_reader :slack_id

    def pending_json(request)
      { id: request.id, amount: request.amount, createdAt: request.created_at.iso8601 }
    end

    def request_json(request)
      {
        id: request.id,
        status: request.aasm_state,
        amount: request.amount,
        adjustedAmount: request.adjusted_amount,
        paidAmount: request.paid_amount,
        adjustment: adjustment_delta(request),
        reason: request.adjust_reason,
        processedBy: processed_by_json(request),
        createdAt: request.created_at.iso8601,
        decidedAt: request.decided_at&.iso8601
      }
    end

    def adjustment_delta(request)
      return nil if request.adjusted_amount.nil?
      request.adjusted_amount - request.amount
    end

    def processed_by_json(request)
      return nil unless request.admin
      { slackId: request.admin.slack_id, displayName: request.admin.display_name }
    end

    def ok(body)
      Result.new(status: :ok, body: body)
    end

    def ok_test
      Result.new(status: :ok, body: { status: "ok", test: true })
    end

    def error(status_sym, message)
      Rails.logger.warn "[ExternalDashboard::ReviewerPayoutStatusProcessor] #{status_sym} #{message}"
      Result.new(status: status_sym, body: { error: message })
    end
  end
end
