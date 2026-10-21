# frozen_string_literal: true

class EventCancellationRefundRun < ApplicationRecord
  belongs_to :event
  belongs_to :started_by, class_name: "User"
  has_many :items, class_name: "EventCancellationRefundItem", dependent: :restrict_with_error

  enum :status, { processing: 0, completed: 1, needs_attention: 2 }

  def summary
    counts = items.group(:status).count.transform_keys { |key| EventCancellationRefundItem.statuses.key(key) || key.to_s }
    { id: id, status: status, total_orders: items.count, total_cents: items.sum(:amount_cents),
      refunded: counts.fetch("refunded", 0), pending: counts.fetch("pending", 0),
      failed: counts.fetch("failed", 0), needs_manual: counts.fetch("needs_manual", 0),
      skipped: counts.fetch("skipped", 0),
      waiting_on_pending_refund: counts.fetch("waiting_on_pending_refund", 0),
      waiting_on_dispute: counts.fetch("waiting_on_dispute", 0), completed_at: completed_at,
      items: items.includes(:order).order(:id).map { |item| {
        id: item.id, order_id: item.order_id, order_reference: item.order.reference,
        status: item.status, amount_cents: item.amount_cents, error: item.last_error
      } } }
  end
end
