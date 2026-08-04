class Api::V1::MACAnalysesController < Api::V1::BaseController
  def create
    review = Certification::Ysws.find(params.require(:review_id))

    analysis = review.mac_analysis || review.build_mac_analysis
    analysis.report = params.require(:report)
    analysis.generated_at = params[:generated_at] || Time.current

    if analysis.save
      render json: { id: analysis.id }, status: :ok
    else
      render json: { errors: analysis.errors.full_messages }, status: :unprocessable_entity
    end
  end

  alias_method :update, :create

  private

    def credential_api_keys
      Array.wrap(Rails.application.credentials.dig(:mac_analysis, :api_key) || ENV["MAC_ANALYSIS_API_KEY"])
    end
end
