# frozen_string_literal: true

class Api::V1::Admin::PayoutsController < Api::V1::Admin::BaseController
  def update
    payout = Payout.find(params[:id])
    status = params[:status].to_s
    unless %w[paid failed reversed].include?(status)
      return render json: { error: "Status must be paid, failed, or reversed" }, status: :unprocessable_entity
    end
    unless payout.may_reconcile_to?(status)
      return render json: { error: "Payout cannot transition from #{payout.status} to #{status}" },
        status: :unprocessable_entity
    end

    before_data = payout.attributes.slice("status", "provider_payout_id", "paid_at")
    payout.update!(
      status: status,
      provider_payout_id: params[:provider_payout_id].presence || payout.provider_payout_id,
      paid_at: status == "paid" ? (payout.paid_at || Time.current) : payout.paid_at,
      failure_code: status == "failed" ? params[:failure_code] : nil,
      failure_message: status == "failed" ? params[:failure_message] : nil
    )
    AuditLogger.record!(
      action: "payout.reconciled",
      auditable: payout,
      actor: current_user,
      organization: payout.organization,
      before_data: before_data,
      after_data: payout.attributes.slice("status", "provider_payout_id", "paid_at"),
      request: request
    )
    render json: payout.attributes.slice(
      "id", "organization_id", "event_id", "settlement_id", "provider", "provider_payout_id",
      "amount_cents", "currency", "status", "paid_at"
    )
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Payout not found" }, status: :not_found
  end
end
