# frozen_string_literal: true

class EventCancellationRefundJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: ->(run_id) { run_id }, group: self.name
  retry_on StandardError, wait: :polynomially_longer, attempts: 10

  def perform(run_id)
    run = EventCancellationRefundRun.find(run_id)
    run.items.where(status: [:pending, :waiting_on_pending_refund, :waiting_on_dispute]).find_each do |item|
      # Match RefundCreator's organization -> order lock order. Read the
      # remaining amount under the order lock immediately before reserve.
      amount = run.event.organization.with_lock do
        item.order.with_lock do
          item.with_lock { prepare_item(item, run) }
        end
      end
      submit_refund(item, run, amount) if amount
    end
    run.with_lock do
      if run.items.where.not(status: [:refunded, :skipped]).none?
        unless run.completed?
          run.update!(status: :completed, completed_at: Time.current)
          AuditLogger.record!(action: "event.cancellation_refunds_completed", auditable: run.event,
            actor: run.started_by, organization: run.event.organization, metadata: run.summary)
        end
      else
        run.update!(status: :needs_attention, completed_at: nil)
      end
    end
  end

  private

  def prepare_item(item, run)
    return nil unless item.pending? || item.waiting_on_pending_refund? || item.waiting_on_dispute?

    order = item.order
    if order.disputes.open.exists?
      item.update!(status: :waiting_on_dispute, last_error: "Waiting for dispute resolution")
      return nil
    end
    existing = order.refunds.find_by(idempotency_key: item.refund_key)
    if order.disputes.lost.exists?
      if order.refunds.pending.exists?
        item.update!(status: :waiting_on_pending_refund, last_error: "Dispute lost; waiting for refund confirmation")
      else
        item.update!(status: :skipped, last_error: "Dispute lost; buyer refunded by chargeback")
      end
      return nil
    end
    if existing&.failed? || existing&.cancelled?
      item.update!(status: :failed, last_error: existing.failure_message || "Provider refund failed")
      return nil
    end
    if existing&.pending? && existing.provider_refund_id.present?
      item.update!(status: :waiting_on_pending_refund, last_error: "Refund pending provider confirmation")
      return nil
    end
    if order.refunds.pending.where.not(id: existing&.id).exists?
      item.update!(status: :waiting_on_pending_refund, last_error: "Another refund is awaiting provider confirmation")
      return nil
    end

    amount = existing&.pending? ? existing.amount_cents : order.refundable_cents
    if existing&.succeeded? && amount.positive?
      item.update!(retry_generation: item.retry_generation + 1)
      existing = nil
    end
    if amount != item.amount_cents
      previous_amount = item.amount_cents
      item.update!(amount_cents: amount)
      AuditLogger.record!(action: "event.cancellation_refund_amount_changed", auditable: run.event,
        actor: run.started_by, organization: run.event.organization,
        metadata: { order_id: order.id, previous_amount_cents: previous_amount, amount_cents: amount })
    end
    if amount.zero?
      item.update!(status: existing&.succeeded? ? :refunded : :skipped,
        last_error: existing&.succeeded? ? nil : "Order already fully refunded")
      return nil
    end

    payment = order.payments.where(status: [:succeeded, :partially_refunded]).order(:id).first
    if order.payment_method == "door_cash" || payment&.provider == "door_cash"
      item.update!(status: :needs_manual, last_error: "Return cash to buyer, then record the return")
      return nil
    end
    unless payment&.provider == "stripe"
      item.update!(status: :failed, last_error: "No refundable card payment; finance review required")
      return nil
    end

    item.update!(status: :pending, last_error: nil)
    amount
  end

  def submit_refund(item, run, amount)
    error = nil
    begin
      Commerce::RefundCreator.call(order: item.order, amount_cents: amount,
        reason: "event_cancelled", requested_by: run.started_by, idempotency_key: item.refund_key)
    rescue Commerce::RefundCreator::RefundError => e
      # A timeout remains reserved; retry_cancellation_refunds keeps its key.
      error = e.message
    end
    recalculate = false
    item.with_lock do
      refund = item.order.refunds.find_by(idempotency_key: item.refund_key)
      if refund&.succeeded?
        item.update!(status: :refunded, last_error: nil)
      elsif refund&.failed? || refund&.cancelled?
        item.update!(status: :failed, last_error: refund.failure_message || error || "Provider refund failed")
      elsif error == "Refund amount exceeds refundable balance" && refund.nil?
        item.update!(status: :pending, last_error: "Refund balance changed; recalculating")
        recalculate = true
      elsif error
        item.update!(status: :failed, last_error: error)
      else
        item.update!(status: :waiting_on_pending_refund, last_error: "Refund pending provider confirmation")
      end
    end
    EventCancellationRefundJob.perform_later(run.id) if recalculate
  end
end
