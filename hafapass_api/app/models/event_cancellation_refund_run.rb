# frozen_string_literal: true

class EventCancellationRefundRun < ApplicationRecord
  belongs_to :event
  belongs_to :started_by, class_name: "User"
  has_many :items, class_name: "EventCancellationRefundItem", dependent: :restrict_with_error

  enum :status, { processing: 0, completed: 1, needs_attention: 2 }

  def summary(page: 1)
    counts = items.group(:status).count.transform_keys { |key| EventCancellationRefundItem.statuses.key(key) || key.to_s }
    total_orders = items.count
    page = [[page.to_i, 1].max, [(total_orders.to_f / 50).ceil, 1].max].min
    { id: id, status: status, total_orders: total_orders, total_cents: items.sum(:amount_cents),
      item_page: page, item_total_pages: (total_orders.to_f / 50).ceil,
      refunded: counts.fetch("refunded", 0), pending: counts.fetch("pending", 0),
      failed: counts.fetch("failed", 0), needs_manual: counts.fetch("needs_manual", 0),
      skipped: counts.fetch("skipped", 0),
      waiting_on_pending_refund: counts.fetch("waiting_on_pending_refund", 0),
      waiting_on_dispute: counts.fetch("waiting_on_dispute", 0), completed_at: completed_at,
      items: items.includes(:order).order(:id).offset((page - 1) * 50).limit(50).map { |item| {
        id: item.id, order_id: item.order_id, order_reference: item.order.reference,
        status: item.status, amount_cents: item.amount_cents, error: item.last_error,
        payment_method: item.order.payment_method, order_created_at: item.order.created_at
      } } }
  end

  def reconcile_status!
    with_lock do
      if items.where.not(status: [:refunded, :skipped]).none?
        unless completed?
          update!(status: :completed, completed_at: Time.current)
          AuditLogger.record!(action: "event.cancellation_refunds_completed", auditable: event,
            actor: started_by, organization: event.organization,
            metadata: { total_orders: items.count, total_cents: items.sum(:amount_cents) })
        end
      elsif !needs_attention?
        update!(status: :needs_attention, completed_at: nil)
      end
    end
    if completed? && !EventCancellationRefunds.unresolved?(event)
      event.payouts.status_held.find_each do |payout|
        PayoutHoldRelease.call(payout: payout, actor: started_by, automatic: true)
      end
    end
  end
end
