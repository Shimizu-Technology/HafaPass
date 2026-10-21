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
      disputed = order.disputes.where(status: [:open, :lost]).exists?
      amount = order.refundable_cents
      status = if disputed || amount.zero?
        :skipped
      elsif order.payment_method == "door_cash"
        :needs_manual
      else
        :pending
      end
      run.items.find_or_create_by!(order: order) do |item|
        item.amount_cents = disputed ? 0 : amount
        item.status = status
        item.last_error = "Disputed order" if disputed
      end
    end
    AuditLogger.record!(action: "event.cancellation_refunds_started", auditable: event, actor: actor,
      organization: event.organization, metadata: preview(event))
    run
  end
end
