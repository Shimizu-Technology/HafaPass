# frozen_string_literal: true

class Api::V1::Admin::PlatformCapabilityReviewsController < Api::V1::Admin::BaseController
  def create
    review = PlatformCapabilityReviews::Manager.submit!(
      capability: params[:capability], attributes: review_params, actor: current_user, request: request
    )
    render json: review_json(review), status: :created
  rescue PlatformCapabilityReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def approve
    review = PlatformCapabilityReviews::Manager.approve!(
      submission: PlatformCapabilityReview.find(params[:id]), actor: current_user, request: request
    )
    render json: review_json(review), status: :created
  rescue PlatformCapabilityReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def reject
    review = PlatformCapabilityReviews::Manager.reject!(
      submission: PlatformCapabilityReview.find(params[:id]), actor: current_user, reason: params[:reason], request: request
    )
    render json: review_json(review), status: :created
  rescue PlatformCapabilityReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def revoke
    review = PlatformCapabilityReviews::Manager.revoke!(
      approval: PlatformCapabilityReview.find(params[:id]), actor: current_user, reason: params[:reason], request: request
    )
    render json: review_json(review), status: :created
  rescue PlatformCapabilityReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def review_params
    permitted = params.permit(:evidence_reference, :evidence_digest, :effective_at, :expires_at)
    control_keys = PlatformCapabilities.required_controls(params[:capability])
    controls = params[:controls].respond_to?(:permit) ? params.require(:controls).permit(*control_keys).to_h : {}
    permitted.to_h.merge(controls: controls)
  rescue ArgumentError
    {}
  end

  def review_json(review)
    review.attributes.slice(
      "id", "parent_review_id", "actor_user_id", "capability", "decision", "evidence_reference",
      "evidence_digest", "configuration_digest", "controls", "effective_at", "expires_at", "reason", "created_at"
    ).merge(active: review.active?)
  end
end
