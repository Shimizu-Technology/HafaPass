# frozen_string_literal: true

# Admin → Payouts → Due. Lists bank transfers and reserve releases that need
# finance, and runs the schedule's own steps: hold the standard reserve,
# finalize the statement, release the reserve. Requesting and recording the
# payout stay on Api::V1::Admin::PayoutsController. Nothing here moves money.
class Api::V1::Admin::PayoutSchedulesController < Api::V1::Admin::BaseController
  before_action :set_event, except: :index

  def index
    render json: AdminPayoutDueList.call(filter: params[:filter])
  end

  def hold_reserve
    adjustment = PayoutReserves.hold!(event: @event, actor: current_user, amount_cents: params[:amount_cents],
      note: params[:note], request: request)
    render json: adjustment_json(adjustment), status: :created
  rescue PayoutReserves::ReserveError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def release_reserve
    adjustment = PayoutReserves.release!(event: @event, actor: current_user,
      early_release_reason: params[:early_release_reason], request: request)
    render json: adjustment_json(adjustment), status: :created
  rescue PayoutReserves::ReserveError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # skip_reserve=true finalizes without the standard reserve; it needs a
  # skip_reason and writes payout_reserve.skipped (who, why, which version),
  # even when an identical statement was already finalized.
  def finalize
    skip = ActiveModel::Type::Boolean.new.cast(params[:skip_reserve])
    if skip && params[:skip_reason].to_s.strip.length < PayoutReserves::MIN_EARLY_REASON_LENGTH
      return render json: { error: "Explain why this event is paid without a reserve (at least 10 characters)" },
        status: :unprocessable_entity
    end

    settlement = Settlements::Finalizer.call(event: @event, actor: current_user, request: request)
    PayoutReserves.skip!(event: @event, actor: current_user, skip_reason: params[:skip_reason], settlement: settlement,
      request: request) if skip
    render json: { id: settlement.id, version: settlement.version, payable_cents: settlement.payable_cents,
      reserve_cents: settlement.reserve_cents, available_to_payout_cents: settlement.available_to_payout_cents,
      reserve_skipped: skip }, status: :created
  rescue Settlements::Finalizer::FinalizationError, PayoutReserves::ReserveError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_event
    @event = Event.find_by(id: params[:event_id])
    render json: { error: "Event not found" }, status: :not_found unless @event
  end

  def adjustment_json(adjustment)
    adjustment.attributes.slice("id", "event_id", "kind", "amount_cents", "currency", "status", "reason", "effective_at")
  end
end
