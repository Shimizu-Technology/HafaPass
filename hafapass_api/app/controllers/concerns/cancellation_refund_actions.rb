# frozen_string_literal: true

module CancellationRefundActions
  extend ActiveSupport::Concern

  def cancellation_refunds
    payload = if OrganizationAuthorization.allowed?(user: current_user, organization: @event.organization,
        permission: :view_finance, event: @event)
      cancellation_json
    else
      { preview: EventCancellationRefunds.preview(@event), run: nil }
    end
    render json: payload
  end

  def retry_cancellation_refunds
    run = @event.event_cancellation_refund_run
    return render json: { error: "Cancellation refunds have not started" }, status: :not_found unless run

    run.items.failed.find_each do |item|
      item.with_lock do
        refund = item.order.refunds.find_by(idempotency_key: item.refund_key)
        # An uncertain provider result must stay on its original key so the
        # provider can be reconciled without a second money movement.
        generation = (refund && (refund.failed? || refund.cancelled?) &&
          refund.failure_code != "provider_result_unknown") ? item.retry_generation + 1 : item.retry_generation
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

    @event.organization.with_lock do
      item.order.with_lock do
        item.with_lock do
          amount = EventCancellationRefunds.refresh_cash_item!(item, actor: current_user)
          if item.needs_manual? && amount.positive?
            refund = Commerce::RefundCreator.call(order: item.order, amount_cents: amount,
              reason: "event_cancelled_cash_return", requested_by: current_user, idempotency_key: item.refund_key,
              cash_return: { reference: params[:reference], returned_at: params[:returned_at] })
            item.update!(status: :refunded, last_error: nil) if refund.succeeded?
            AuditLogger.record!(action: "event.cancellation_cash_refunded", auditable: @event, actor: current_user,
              organization: @event.organization, metadata: { order_id: item.order_id, refund_id: refund.id,
                amount_cents: refund.amount_cents }, request: request)
          end
        end
      end
    end
    EventCancellationRefundJob.perform_later(run.id)
    render json: cancellation_json
  rescue Commerce::RefundCreator::RefundError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def mark_card_refunded
    run = @event.event_cancellation_refund_run
    item = run&.items&.find_by(order_id: params[:order_id])
    return render json: { error: "Manual card refund item not found" }, status: :not_found unless item&.needs_manual?

    @event.organization.with_lock do
      item.order.with_lock do
        item.with_lock do
          payments = item.order.payments.where(status: [:succeeded, :partially_refunded])
          payments = payments.merge(Payment.live_or_legacy_capture) if Rails.env.production?
          payment = payments.order(:id).first
          unless item.order.payment_method == "door_card" && payment && !%w[stripe door_cash].include?(payment.provider)
            return render json: { error: "Only captured non-Stripe card payments can use this action" },
              status: :unprocessable_entity
          end
          amount = EventCancellationRefunds.balance_cents(item.order)
          if amount.zero?
            item.update!(status: :skipped, last_error: "Buyer balance already resolved")
          else
            refund = Commerce::RefundCreator.call(order: item.order, payment: payment, amount_cents: amount,
              reason: "event_cancelled_manual_card_return", requested_by: current_user, idempotency_key: item.refund_key,
              manual_card_return: { reference: params[:reference], returned_at: params[:returned_at] })
            item.update!(status: :refunded, amount_cents: amount, last_error: nil) if refund.succeeded?
            AuditLogger.record!(action: "event.cancellation_card_refunded", auditable: @event, actor: current_user,
              organization: @event.organization, metadata: { order_id: item.order_id, payment_id: payment.id,
                refund_id: refund.id, amount_cents: refund.amount_cents }, request: request)
          end
        end
      end
    end
    EventCancellationRefundJob.perform_later(run.id)
    render json: cancellation_json
  rescue Commerce::RefundCreator::RefundError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def cancellation_json
    { preview: EventCancellationRefunds.preview(@event),
      run: @event.event_cancellation_refund_run&.summary(page: params[:page] || 1) }
  end
end
