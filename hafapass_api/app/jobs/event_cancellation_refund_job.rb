# frozen_string_literal: true

class EventCancellationRefundJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 10

  def perform(run_id)
    run = EventCancellationRefundRun.find(run_id)
    run.items.pending.find_each do |item|
      item.with_lock do
        next unless item.pending?

        order = item.order
        if order.disputes.where(status: [:open, :lost]).exists?
          item.update!(status: :skipped, last_error: "Disputed order")
          next
        end
        existing = order.refunds.find_by(idempotency_key: item.refund_key)
        if existing&.succeeded?
          item.update!(status: :refunded, last_error: nil)
          next
        end
        if existing&.failed? || existing&.cancelled?
          item.update!(status: :failed, last_error: existing.failure_message || "Provider refund failed")
          next
        end
        if order.refundable_cents.zero? && !existing&.pending?
          if order.refunds.pending.exists?
            item.update!(last_error: "Another refund is awaiting provider confirmation")
          else
            item.update!(status: :refunded, last_error: nil)
          end
          next
        end
        payment = order.payments.where(status: [:succeeded, :partially_refunded]).order(:id).first
        if order.payment_method == "door_cash" || payment&.provider == "door_cash"
          item.update!(status: :needs_manual, last_error: "Return cash to buyer, then record the return")
          next
        end
        unless payment&.provider == "stripe"
          item.update!(status: :failed, last_error: "No refundable card payment; finance review required")
          next
        end

        begin
          refund = Commerce::RefundCreator.call(order: order, amount_cents: item.amount_cents,
            reason: "event_cancelled", requested_by: run.started_by, idempotency_key: item.refund_key)
          if refund.succeeded?
            item.update!(status: :refunded, last_error: nil)
          elsif refund.failed? || refund.cancelled?
            item.update!(status: :failed, last_error: refund.failure_message || "Provider refund failed")
          else
            item.update!(last_error: "Refund pending provider confirmation")
          end
        rescue Commerce::RefundCreator::RefundError => e
          item.update!(status: :failed, last_error: e.message)
        end
      end
    end
    run.with_lock do
      if run.items.where(status: [:pending, :failed, :needs_manual]).none?
        unless run.completed?
          run.update!(status: :completed, completed_at: Time.current)
          AuditLogger.record!(action: "event.cancellation_refunds_completed", auditable: run.event,
            actor: run.started_by, organization: run.event.organization, metadata: run.summary)
        end
      else
        run.update!(status: :needs_attention)
      end
    end
  end
end
