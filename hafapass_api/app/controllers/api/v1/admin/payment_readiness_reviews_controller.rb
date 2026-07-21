# frozen_string_literal: true

class Api::V1::Admin::PaymentReadinessReviewsController < Api::V1::Admin::BaseController
  def create
    account = ConnectedAccount.find(params[:connected_account_id])
    review = PaymentReadinessReviews::Manager.submit!(
      account: account,
      attributes: review_params,
      actor: current_user,
      request: request
    )
    render json: review_json(review), status: :created
  rescue PaymentReadinessReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def approve
    review = PaymentReadinessReviews::Manager.approve!(
      submission: PaymentReadinessReview.find(params[:id]),
      actor: current_user,
      request: request
    )
    render json: review_json(review), status: :created
  rescue PaymentReadinessReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def revoke
    review = PaymentReadinessReviews::Manager.revoke!(
      approval: PaymentReadinessReview.find(params[:id]),
      actor: current_user,
      reason: params[:reason],
      request: request
    )
    render json: review_json(review), status: :created
  rescue PaymentReadinessReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def reject
    review = PaymentReadinessReviews::Manager.reject!(
      submission: PaymentReadinessReview.find(params[:id]),
      actor: current_user,
      reason: params[:reason],
      request: request
    )
    render json: review_json(review), status: :created
  rescue PaymentReadinessReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def review_params
    permitted = params.permit(
      :evidence_reference, :evidence_digest, :provider_approval_reference, :merchant_of_record,
      :fee_tax_schedule_reference, :liability_schedule_reference, :effective_at, :expires_at
    )
    controls = params[:controls].respond_to?(:permit) ?
      params.require(:controls).permit(*PaymentReadinessReview::CONTROL_KEYS).to_h : {}
    permitted.to_h.merge(controls: controls)
  end

  def review_json(review)
    review.attributes.slice(
      "id", "connected_account_id", "parent_review_id", "actor_user_id", "decision",
      "evidence_reference", "evidence_digest", "provider_state_digest", "provider_approval_reference", "merchant_of_record",
      "fee_tax_schedule_reference", "liability_schedule_reference", "controls", "effective_at",
      "expires_at", "reason", "created_at"
    ).merge(connected_account_payout_ready: review.connected_account.reload.payout_ready?)
  end
end
