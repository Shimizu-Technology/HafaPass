# frozen_string_literal: true

class Api::V1::Support::MessageDeliveriesController < Api::V1::Support::BaseController
  around_action :with_audit_transaction, only: [:resend, :fulfill, :bulk_resend]
  BULK_RESEND_LIMIT = 500
  # Most candidate rows one bulk request examines, so a backlog of skipped
  # (suppressed or concurrently locked) rows can't turn one request into an
  # unbounded scan. Anything not examined is reported as remaining.
  BULK_RESEND_SCAN_LIMIT = 2000

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

    delivery.update_columns(replay_requested_at: Time.current)
    MessageDeliveryJob.perform_later(delivery.id)
    AuditLogger.record!(action: "message_delivery.replayed", auditable: delivery, actor: current_user,
      request: request)
    render json: delivery_json(delivery.reload), status: :accepted
  end

  # After a provider outage: replay up to BULK_RESEND_LIMIT failed deliveries
  # (oldest failure first) with the same checks as a single replay, examining
  # at most BULK_RESEND_SCAN_LIMIT candidates. Each queued row is stamped, so
  # running it again queues the next batch rather than the same rows, and
  # concurrent runs skip rows the other has locked. Suppression is checked in
  # one batched lookup per slice before locking, so only rows about to be
  # queued are locked.
  def bulk_resend
    unless params[:status].to_s == "failed"
      return render json: { error: "Bulk re-send only replays failed deliveries (status=failed)" },
        status: :unprocessable_entity
    end
    failed_after = bulk_time(:failed_after)
    failed_before = bulk_time(:failed_before) unless performed?
    return if performed?

    now = Time.current
    deliveries = MessageDelivery.failed
    deliveries = deliveries.where(failed_at: failed_after..) if failed_after
    deliveries = deliveries.where(failed_at: ...failed_before) if failed_before
    deliveries = deliveries.where(event_id: params[:event_id]) if params[:event_id].present?
    matched = deliveries.count
    retryable_count = deliveries.retryable(now).count
    provider_accepted = deliveries.provider_accepted.count
    eligible = deliveries.retryable(now).not_recently_replayed(now)
    eligible_count = eligible.count
    candidates = eligible.order(:failed_at, :id).limit(BULK_RESEND_SCAN_LIMIT).pluck(:id)
    skipped = Hash.new(0).merge("provider_accepted" => provider_accepted,
      "replay_window_expired" => matched - retryable_count - provider_accepted,
      "recently_queued" => retryable_count - eligible_count)
    queued = 0
    examined = 0

    while candidates.any? && queued < BULK_RESEND_LIMIT
      slice = candidates.shift(BULK_RESEND_LIMIT - queued)
      examined += slice.size
      suppressed = MessageDelivery.suppressed_recipient_ids(eligible.where(id: slice).to_a)
      skipped["suppressed_recipient"] += suppressed.size
      lockable = slice - suppressed.to_a
      locked = eligible.where(id: lockable).lock("FOR UPDATE SKIP LOCKED").index_by(&:id)
      # Gone from the eligible set (concurrently queued) or locked by another run.
      skipped["recently_queued"] += lockable.size - locked.size
      lockable.each do |id|
        next unless (delivery = locked[id])

        delivery.update_columns(replay_requested_at: now)
        MessageDeliveryJob.perform_later(delivery.id)
        AuditLogger.record!(action: "message_delivery.replayed", auditable: delivery, actor: current_user,
          metadata: { bulk: true }, request: request)
        queued += 1
      end
    end

    remaining = [eligible_count - examined, 0].max
    render json: { queued: queued, skipped: skipped.select { |_reason, count| count.positive? }, matched: matched,
                   capped: remaining.positive?, remaining: remaining }, status: :accepted
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
