# frozen_string_literal: true

class EventCancellationRefunds
  PAID_STATUSES = [:completed, :partially_refunded, :refunded].freeze

  # A cash return is a succeeded Refund with cash_return evidence, so it is
  # included once in the succeeded-refund total.
  def self.balance_cents(order)
    captured = order.payments.where(status: [:succeeded, :partially_refunded, :refunded]).sum(:amount_cents)
    reserved_or_returned = order.refunds.where(status: [:pending, :succeeded]).sum(:amount_cents)
    chargebacks = order.disputes.lost.sum(:amount_cents)
    [captured - reserved_or_returned - chargebacks, 0].max
  end

  def self.outstanding_balance_cents(event)
    live_paid_orders(event).sum { |order| balance_cents(order) }
  end

  def self.unresolved?(event)
    return false unless event.cancelled?

    live_paid_orders(event).any? do |order|
      balance_cents(order).positive? || order.refunds.pending.exists? || order.disputes.open.exists?
    end
  end

  def self.live_paid_orders(event)
    event.orders.where(status: PAID_STATUSES).order(:id).reject do |order|
      order.payments.nonlive_stripe.exists? && !order.payments.live_or_legacy_capture.exists?
    end
  end

  # Caller holds the order and item locks (and the organization lock first).
  def self.refresh_cash_item!(item, actor:)
    return unless item.needs_manual?

    amount = balance_cents(item.order)
    if amount != item.amount_cents
      previous_amount = item.amount_cents
      item.update!(amount_cents: amount)
      event = item.event_cancellation_refund_run.event
      AuditLogger.record!(action: "event.cancellation_refund_amount_changed", auditable: event,
        actor: actor, organization: event.organization,
        metadata: { order_id: item.order_id, previous_amount_cents: previous_amount, amount_cents: amount })
    end
    if item.order.refunds.pending.exists?
      item.update!(status: :waiting_on_pending_refund, last_error: "Waiting for an existing refund")
    elsif amount.zero?
      item.update!(status: :skipped, last_error: "Buyer balance already resolved")
    end
    amount
  end

  def self.preview(event)
    orders = Rails.env.production? ? live_paid_orders(event) : event.orders.where(status: PAID_STATUSES).order(:id)
    refundable = orders.select { |order| balance_cents(order).positive? }
    { count: refundable.length, total_cents: refundable.sum { |order| balance_cents(order) },
      cash_count: refundable.count { |order| order.payment_method == "door_cash" } }
  end

  def self.prepare!(event:, actor:)
    run = event.event_cancellation_refund_run || event.create_event_cancellation_refund_run!(started_by: actor)
    orders = event.orders.where(status: PAID_STATUSES)
    orders = orders.excluding_test_payments if Rails.env.production?
    orders.find_each do |order|
      open_dispute = order.disputes.open.exists?
      lost_dispute = order.disputes.lost.exists?
      amount = balance_cents(order)
      pending_refund = order.refunds.pending.exists?
      status = if open_dispute
        :waiting_on_dispute
      elsif pending_refund
        :waiting_on_pending_refund
      elsif amount.zero?
        :skipped
      elsif order.payment_method == "door_cash"
        :needs_manual
      else
        :pending
      end
      run.items.find_or_create_by!(order: order) do |item|
        item.amount_cents = amount
        item.status = status
        item.last_error = "Waiting for dispute resolution" if open_dispute
        item.last_error = "Dispute lost; buyer refunded by chargeback" if lost_dispute && amount.zero? && !pending_refund
        item.last_error = "Waiting for an existing refund" if status == :waiting_on_pending_refund
        item.last_error = "Order already fully refunded" if status == :skipped && !lost_dispute
      end
    end
    AuditLogger.record!(action: "event.cancellation_refunds_started", auditable: event, actor: actor,
      organization: event.organization, metadata: preview(event))
    run
  end
end
