# frozen_string_literal: true

class EventCancellationRefundItem < ApplicationRecord
  belongs_to :event_cancellation_refund_run
  belongs_to :order
  enum :status, { pending: 0, refunded: 1, failed: 2, needs_manual: 3, skipped: 4,
    waiting_on_pending_refund: 5, waiting_on_dispute: 6 }

  def refund_key
    "event-cancellation/#{event_cancellation_refund_run.event_id}/#{order_id}/#{retry_generation}"
  end
end
