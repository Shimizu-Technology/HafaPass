# frozen_string_literal: true

module CancellationRefundActions
  extend ActiveSupport::Concern

  def cancellation_refunds
    render json: cancellation_json
  end

  def retry_cancellation_refunds
    run = @event.event_cancellation_refund_run
    return render json: { error: "Cancellation refunds have not started" }, status: :not_found unless run

    run.items.failed.find_each do |item|
      item.with_lock do
        refund = item.order.refunds.find_by(idempotency_key: item.refund_key)
        # An uncertain provider result must stay on its original key so the
        # provider can be reconciled without a second money movement.
        generation = refund&.failed? && refund.provider_refund_id.blank? ? item.retry_generation + 1 : item.retry_generation
        item.update!(status: :pending, retry_generation: generation, last_error: nil)
      end
    end
    run.update!(status: :processing, completed_at: nil)
    EventCancellationRefundJob.perform_later(run.id)
    render json: cancellation_json, status: :accepted
  end

  def mark_cash_refunded
    run = @event.event_cancellation_refund_run
    item = run&.items&.find_by(order_id: params[:order_id])
    return render json: { error: "Cash refund item not found" }, status: :not_found unless item&.needs_manual?

    item.with_lock do
      raise Commerce::RefundCreator::RefundError, "Cash refund was already recorded" unless item.needs_manual?

      refund = Commerce::RefundCreator.call(order: item.order, amount_cents: item.amount_cents,
        reason: "event_cancelled_cash_return", requested_by: current_user, idempotency_key: item.refund_key,
        cash_return: { reference: params[:reference], returned_at: params[:returned_at] })
      item.update!(status: :refunded, last_error: nil) if refund.succeeded?
      AuditLogger.record!(action: "event.cancellation_cash_refunded", auditable: @event, actor: current_user,
        organization: @event.organization, metadata: { order_id: item.order_id, refund_id: refund.id,
          amount_cents: refund.amount_cents }, request: request)
    end
    EventCancellationRefundJob.perform_later(run.id)
    render json: cancellation_json
  rescue Commerce::RefundCreator::RefundError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def cancellation_json
    { preview: EventCancellationRefunds.preview(@event),
      run: @event.event_cancellation_refund_run&.summary }
  end
end
