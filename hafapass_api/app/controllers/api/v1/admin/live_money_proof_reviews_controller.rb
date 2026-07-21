# frozen_string_literal: true

class Api::V1::Admin::LiveMoneyProofReviewsController < Api::V1::Admin::BaseController
  include LiveMoneyProofSerialization

  def show
    event = Event.find(params[:event_id])
    authorization = event.live_money_proof_authorizations.order(created_at: :desc).first
    render json: {
      event: event.attributes.slice("id", "title", "status", "starts_at", "live_money_proof_candidate"),
      authorization: live_money_authorization_json(authorization),
      live_money_proof: live_money_status_json(event.organization)
    }
  end

  def create
    event = Event.find(params[:event_id])
    attributes = review_params.to_h.symbolize_keys.merge(proof_event_id: event.id)
    review = LiveMoneyProofReviews::Manager.submit!(
      organization: event.organization, attributes: attributes, actor: current_user, request: request
    )
    render json: live_money_review_json(review, active: false), status: :created
  rescue LiveMoneyProofReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def approve
    review = LiveMoneyProofReviews::Manager.approve!(
      submission: LiveMoneyProofReview.find(params[:id]), actor: current_user, request: request
    )
    active = LiveMoneyProof.active_approval(review.organization)&.id == review.id
    render json: live_money_review_json(review, active: active), status: :created
  rescue LiveMoneyProofReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def reject
    review = LiveMoneyProofReviews::Manager.reject!(
      submission: LiveMoneyProofReview.find(params[:id]), actor: current_user,
      reason: params[:reason], request: request
    )
    render json: live_money_review_json(review, active: false), status: :created
  rescue LiveMoneyProofReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def revoke
    review = LiveMoneyProofReviews::Manager.revoke!(
      approval: LiveMoneyProofReview.find(params[:id]), actor: current_user,
      reason: params[:reason], request: request
    )
    render json: live_money_review_json(review, active: false), status: :created
  rescue LiveMoneyProofReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def review_params
    params.permit(
      :event_day_rehearsal_review_id, :authorization_id, :order_id, :payment_id, :partial_refund_id,
      :final_refund_id, :initial_settlement_id, :payout_id, :post_payout_settlement_id,
      :evidence_reference, :evidence_digest, :effective_at, :expires_at,
      entity_results: LiveMoneyProofReview::ENTITY_FIELDS,
      provider_results: LiveMoneyProofReview::PROVIDER_FIELDS,
      reconciliation_results: LiveMoneyProofReview::RECONCILIATION_FIELDS,
      communication_results: LiveMoneyProofReview::COMMUNICATION_KEYS.index_with {
        LiveMoneyProofReview::COMMUNICATION_FIELDS
      },
      controls: LiveMoneyProofReview::CONTROL_KEYS
    )
  end
end
