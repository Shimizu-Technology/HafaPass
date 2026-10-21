# frozen_string_literal: true

class OrderCardPresenter
  def self.call(order)
    items = order.order_items.sort_by(&:id)
    {
      id: order.id,
      reference: order.reference,
      status: order.status,
      buyer_status: order.buyer_status,
      completed_at: order.completed_at,
      created_at: order.created_at,
      event: {
        title: order.event.title,
        starts_at: order.event.starts_at,
        timezone: order.event.timezone
      },
      order_items: items.map { |item| { id: item.id, name: item.name, item_kind: item.item_kind, quantity: item.quantity } },
      item_counts: items.each_with_object(Hash.new(0)) { |item, counts| counts[item.item_kind] += item.quantity },
      subtotal_cents: order.subtotal_cents,
      service_fee_cents: order.service_fee_cents,
      discount_cents: order.discount_cents,
      total_cents: order.total_cents,
      refunded_cents: order.refunded_cents,
      refund_pending: order.refunds.any?(&:pending?),
      payment_environment: order.payment_environment,
      receipt_available: order.receipt_available?
    }
  end
end
