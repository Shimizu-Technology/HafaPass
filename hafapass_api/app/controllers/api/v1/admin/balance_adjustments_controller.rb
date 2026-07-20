# frozen_string_literal: true

class Api::V1::Admin::BalanceAdjustmentsController < Api::V1::Admin::BaseController
  def create
    organization = Organization.find(params[:organization_id])
    event = organization.events.find(params[:event_id]) if params[:event_id].present?
    adjustment = organization.balance_adjustments.create!(
      event: event,
      order_id: params[:order_id],
      dispute_id: params[:dispute_id],
      created_by_user: current_user,
      kind: params[:kind],
      amount_cents: params[:amount_cents],
      currency: organization.currency,
      status: :posted,
      reason: params[:reason],
      effective_at: params[:effective_at].presence || Time.current
    )
    AuditLogger.record!(
      action: "balance_adjustment.posted",
      auditable: adjustment,
      actor: current_user,
      organization: organization,
      after_data: adjustment_json(adjustment),
      request: request
    )
    render json: adjustment_json(adjustment), status: :created
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Organization or event not found" }, status: :not_found
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def destroy
    adjustment = BalanceAdjustment.status_posted.find(params[:id])
    reversal = nil
    BalanceAdjustment.transaction do
      adjustment.lock!
      reversal = adjustment.organization.balance_adjustments.create!(
        event: adjustment.event,
        order: adjustment.order,
        dispute: adjustment.dispute,
        created_by_user: current_user,
        reversed_by_user: current_user,
        reversal_of: adjustment,
        kind: reversal_kind(adjustment),
        amount_cents: -adjustment.amount_cents,
        currency: adjustment.currency,
        status: :posted,
        reason: params[:reason].presence || "Reversal of adjustment #{adjustment.id}",
        effective_at: Time.current
      )
      adjustment.update!(status: :reversed, reversed_by_user: current_user)
    end
    AuditLogger.record!(
      action: "balance_adjustment.reversed",
      auditable: reversal,
      actor: current_user,
      organization: adjustment.organization,
      metadata: { original_adjustment_id: adjustment.id },
      request: request
    )
    render json: adjustment_json(reversal), status: :created
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Posted adjustment not found" }, status: :not_found
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  private

  def reversal_kind(adjustment)
    return "reserve_release" if adjustment.kind == "reserve_hold"
    return "reserve_hold" if adjustment.kind == "reserve_release"

    adjustment.amount_cents.positive? ? "manual_debit" : "manual_credit"
  end

  def adjustment_json(adjustment)
    adjustment.attributes.slice(
      "id", "organization_id", "event_id", "order_id", "dispute_id", "kind", "amount_cents",
      "currency", "status", "reason", "effective_at", "reversal_of_id", "created_at"
    )
  end
end
