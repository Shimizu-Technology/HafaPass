# frozen_string_literal: true

class Api::V1::Organizer::FinancesController < Api::V1::Organizer::BaseController
  before_action :set_event
  before_action :require_finance_visibility

  def show
    preview = Settlements::Calculator.call(@event)
    render json: {
      preview: preview.attributes.except(:organization, :event),
      settlements: @event.settlements.order(version: :desc).map { |settlement| settlement_json(settlement) },
      payouts: @event.payouts.order(created_at: :desc).map { |payout| payout_json(payout) },
      connected_account: connected_account_json(current_organization.payout_account || current_organization.connected_accounts.first)
    }
  end

  def finalize
    return unless authorize_organization!(:manage_finance, event: @event)

    settlement = Settlements::Finalizer.call(event: @event, actor: current_user, request: request)
    render json: settlement_json(settlement), status: :created
  rescue Settlements::Finalizer::FinalizationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def payout
    return unless authorize_organization!(:payout, event: @event)

    idempotency_key = request.headers["Idempotency-Key"].presence
    return render json: { error: "Idempotency-Key header is required" }, status: :unprocessable_entity unless idempotency_key

    settlement = @event.settlements.status_finalized.find(params[:settlement_id])
    payout = PayoutCreator.call(
      settlement: settlement,
      actor: current_user,
      idempotency_key: idempotency_key,
      amount_cents: params[:amount_cents],
      request: request
    )
    render json: payout_json(payout), status: :created
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Settlement not found" }, status: :not_found
  rescue PayoutCreator::PayoutError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_event
    @event = find_organization_event(params[:event_id])
  end

  def require_finance_visibility
    authorize_organization!(:view_finance, event: @event) if @event
  end

  def settlement_json(settlement)
    settlement.attributes.slice(
      "id", "version", "status", "currency", "source_digest", "gross_cents", "discount_cents",
      "refund_cents", "net_cents", "platform_fee_cents", "processing_fee_cents",
      "organizer_proceeds_cents", "reserve_cents", "adjustment_cents", "payable_cents", "paid_cents",
      "negative_balance_cents", "calculated_at", "finalized_at"
    ).merge(available_to_payout_cents: settlement.available_to_payout_cents)
  end

  def payout_json(payout)
    payout.attributes.slice(
      "id", "settlement_id", "provider", "provider_payout_id", "amount_cents", "currency", "status",
      "failure_code", "failure_message", "initiated_at", "paid_at", "created_at"
    )
  end

  def connected_account_json(account)
    return unless account

    account.attributes.slice(
      "id", "provider", "status", "charges_enabled", "payouts_enabled", "details_submitted",
      "requirements_due", "capabilities", "last_synced_at"
    ).merge(payout_ready: account.payout_ready?)
  end
end
