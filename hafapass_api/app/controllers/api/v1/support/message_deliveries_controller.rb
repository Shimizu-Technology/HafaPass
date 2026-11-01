# frozen_string_literal: true

class Api::V1::Support::MessageDeliveriesController < Api::V1::Support::BaseController
  around_action :with_audit_transaction, only: [:resend, :fulfill, :bulk_resend]
  BULK_RESEND_LIMIT = 500

  def index
    deliveries = MessageDelivery.includes(:order, :ticket, :event, :requested_by)
    deliveries = deliveries.where(status: params[:status]) if params[:status].present?
    deliveries = deliveries.where(order_id: params[:order_id]) if params[:order_id].present?
    deliveries = deliveries.where(event_id: params[:event_id]) if params[:event_id].present?
    deliveries = deliveries.order(created_at: :desc).limit(100)

    render json: { deliveries: deliveries.map { |delivery| delivery_json(delivery) } }
  end

  def resend
    delivery = MessageDelivery.find(params[:id])
    unless delivery.retryable?
      return render json: { error: "Only failed pre-provider deliveries can be safely replayed" },
        status: :unprocessable_entity
    end
    if delivery.suppressed_recipient?
      return render json: { error: "Recipient is suppressed after a bounce or complaint" },
        status: :unprocessable_entity
    end

    MessageDeliveryJob.perform_later(delivery.id)
    AuditLogger.record!(action: "message_delivery.replayed", auditable: delivery, actor: current_user,
      request: request)
    render json: delivery_json(delivery.reload), status: :accepted
  end

  # After a provider outage: replay up to BULK_RESEND_LIMIT failed deliveries
  # (oldest failure first) with the same per-row checks as a single replay.
  def bulk_resend
    unless params[:status].to_s == "failed"
      return render json: { error: "Bulk re-send only replays failed deliveries (status=failed)" },
        status: :unprocessable_entity
    end
    failed_after = bulk_time(:failed_after)
    failed_before = bulk_time(:failed_before) unless performed?
    return if performed?

    deliveries = MessageDelivery.failed
    deliveries = deliveries.where(failed_at: failed_after..) if failed_after
    deliveries = deliveries.where(failed_at: ...failed_before) if failed_before
    deliveries = deliveries.where(event_id: params[:event_id]) if params[:event_id].present?
    matched = deliveries.count
    queued = 0
    skipped = Hash.new(0)

    deliveries.order(:failed_at, :id).limit(BULK_RESEND_LIMIT).each do |delivery|
      if (reason = bulk_skip_reason(delivery))
        skipped[reason] += 1
        next
      end

      MessageDeliveryJob.perform_later(delivery.id)
      AuditLogger.record!(action: "message_delivery.replayed", auditable: delivery, actor: current_user,
        metadata: { bulk: true }, request: request)
      queued += 1
    end

    render json: { queued: queued, skipped: skipped, matched: matched, capped: matched > BULK_RESEND_LIMIT },
      status: :accepted
  end

  def fulfill
    order = Order.find(params[:order_id])
    delivery = FulfillmentResender.call(order: order, requested_by: current_user)
    AuditLogger.record!(action: "order.fulfillment_resent", auditable: order, actor: current_user,
      metadata: { message_delivery_id: delivery.id }, request: request)
    render json: delivery_json(delivery), status: :accepted
  rescue FulfillmentResender::ResendError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def bulk_time(key)
    return if params[key].blank?

    Time.iso8601(params[key].to_s)
  rescue ArgumentError
    render json: { error: "#{key} must be an ISO 8601 time" }, status: :unprocessable_entity
    nil
  end

  def bulk_skip_reason(delivery)
    return "provider_accepted" if delivery.provider_id.present?
    return "replay_window_expired" unless delivery.retryable?

    "suppressed_recipient" if delivery.suppressed_recipient?
  end

  def delivery_json(delivery)
    {
      id: delivery.id,
      order_id: delivery.order_id,
      ticket_id: delivery.ticket_id,
      event_id: delivery.event_id,
      template: delivery.template,
      recipient: delivery.recipient,
      provider: delivery.provider,
      provider_id: delivery.provider_id,
      status: delivery.status,
      attempts: delivery.attempts,
      last_error: delivery.last_error,
      sent_at: delivery.sent_at,
      delivered_at: delivery.delivered_at,
      bounced_at: delivery.bounced_at,
      complained_at: delivery.complained_at,
      suppressed_at: delivery.suppressed_at,
      requested_by: delivery.requested_by&.email,
      created_at: delivery.created_at
    }
  end
end
