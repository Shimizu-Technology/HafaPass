# frozen_string_literal: true

class Api::V1::Admin::PayoutsController < Api::V1::Admin::BaseController
  def update
    payout = Payout.find(params[:id])
    evidence = params[:evidence]
    PayoutReconciler.call(payout: payout, actor: current_user, status: params[:status].to_s,
      provider_payout_id: params[:provider_payout_id],
      evidence: evidence.is_a?(ActionController::Parameters) ? evidence.permit(:reference, :confirmed_at, :reason).to_h : nil,
      request: request
    )
    render json: payout.attributes.slice(
      "id", "organization_id", "event_id", "settlement_id", "provider", "provider_payout_id",
      "amount_cents", "currency", "status", "paid_at"
    )
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Payout not found" }, status: :not_found
  rescue PayoutReconciler::ReconciliationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
