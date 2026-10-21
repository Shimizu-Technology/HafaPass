# frozen_string_literal: true

class EventCancellationRefunds
  def self.preview(event)
    orders = event.orders.where(status: [:completed, :partially_refunded]).includes(:refunds).to_a
    refundable = orders.select { |order| order.refundable_cents.positive? && !order.disputes.where(status: [:open, :lost]).exists? }
    { count: refundable.length, total_cents: refundable.sum(&:refundable_cents),
      cash_count: refundable.count { |order| order.payment_method == "door_cash" } }
  end

  def self.prepare!(event:, actor:)
    run = event.event_cancellation_refund_run || event.create_event_cancellation_refund_run!(started_by: actor)
    event.orders.where(status: [:completed, :partially_refunded, :refunded]).find_each do |order|
      open_dispute = order.disputes.open.exists?
      lost_dispute = order.disputes.lost.exists?
      amount = order.refundable_cents
      pending_refund = order.refunds.pending.exists?
      status = if open_dispute
        :waiting_on_dispute
      elsif lost_dispute && pending_refund
        :waiting_on_pending_refund
      elsif lost_dispute || (amount.zero? && !pending_refund)
        :skipped
      elsif amount.zero?
        :waiting_on_pending_refund
      elsif order.payment_method == "door_cash"
        :needs_manual
      else
        :pending
      end
      run.items.find_or_create_by!(order: order) do |item|
        item.amount_cents = amount
        item.status = status
        item.last_error = "Waiting for dispute resolution" if open_dispute
        item.last_error = "Dispute lost; buyer refunded by chargeback" if lost_dispute && !pending_refund
        item.last_error = "Waiting for an existing refund" if status == :waiting_on_pending_refund
        item.last_error = "Order already fully refunded" if status == :skipped && !lost_dispute
      end
    end
    AuditLogger.record!(action: "event.cancellation_refunds_started", auditable: event, actor: actor,
      organization: event.organization, metadata: preview(event))
    run
  end
end
