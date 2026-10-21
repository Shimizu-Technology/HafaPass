# frozen_string_literal: true

require "timeout"

class EventCancellationRefundJob < ApplicationJob
  class RunDeadlineExceeded < StandardError; end

  RUN_DEADLINE = 30.minutes
  queue_as :default
  limits_concurrency to: 1, key: ->(run_id) { run_id }, duration: RUN_DEADLINE + 5.minutes, group: self.name
  retry_on StandardError, wait: :polynomially_longer, attempts: 10

  def perform(run_id)
    Timeout.timeout(RUN_DEADLINE, RunDeadlineExceeded) { process_run(run_id) }
  end

  private

  def process_run(run_id)
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
    run.reconcile_status!
  end

  def prepare_item(item, run)
    return nil unless item.pending? || item.waiting_on_pending_refund? || item.waiting_on_dispute?

    order = item.order
    live_payment_ids = Payment.live_or_legacy_capture.where(order_id: order.id).select(:id)
    disputes = order.disputes
    pending_refunds = order.refunds.pending
    if Rails.env.production?
      disputes = disputes.where(payment_id: live_payment_ids)
      pending_refunds = pending_refunds.where(payment_id: live_payment_ids)
    end
    if disputes.open.exists?
      item.update!(status: :waiting_on_dispute, last_error: "Waiting for dispute resolution")
      return nil
    end
    existing = order.refunds.find_by(idempotency_key: item.refund_key)
    if existing&.failed? || existing&.cancelled?
      item.update!(status: :failed, last_error: existing.failure_message || "Provider refund failed")
      return nil
    end
    if existing&.pending? && existing.provider_refund_id.present?
      item.update!(status: :waiting_on_pending_refund, last_error: "Refund pending provider confirmation")
      return nil
    end
    if pending_refunds.where.not(id: existing&.id).exists?
      item.update!(status: :waiting_on_pending_refund, last_error: "Another refund is awaiting provider confirmation")
      return nil
    end

    amount = existing&.pending? ? existing.amount_cents : EventCancellationRefunds.balance_cents(order)
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
      message = if existing&.succeeded?
        nil
      elsif disputes.lost.exists?
        "Dispute lost; buyer refunded by chargeback"
      else
        "Buyer balance already resolved"
      end
      item.update!(status: existing&.succeeded? ? :refunded : :skipped,
        last_error: message)
      return nil
    end

    eligible_payments = order.payments.where(status: [:succeeded, :partially_refunded])
    eligible_payments = eligible_payments.merge(Payment.live_or_legacy_capture) if Rails.env.production?
    payment = eligible_payments.order(:id).first
    if order.payment_method == "door_cash" || payment&.provider == "door_cash"
      item.update!(status: :needs_manual, last_error: "Return cash to buyer, then record the return")
      return nil
    end
    unless payment&.provider == "stripe"
      item.update!(status: :needs_manual,
        last_error: "Return the card payment through its provider, then record the return with a reference")
      return nil
    end

    item.update!(status: :pending, last_error: nil)
    amount
  end

  def submit_refund(item, run, amount)
    error = nil
    begin
      payment = item.order.payments.where(status: [:succeeded, :partially_refunded])
      payment = payment.merge(Payment.live_or_legacy_capture) if Rails.env.production?
      Commerce::RefundCreator.call(order: item.order, payment: payment.order(:id).first, amount_cents: amount,
        reason: "event_cancelled", requested_by: run.started_by, idempotency_key: item.refund_key)
    rescue Commerce::RefundCreator::RefundError => e
      # A timeout remains reserved; retry_cancellation_refunds keeps its key.
      error = e.message
    end
    item.with_lock do
      refund = item.order.refunds.find_by(idempotency_key: item.refund_key)
      if refund&.succeeded?
        item.update!(status: :refunded, last_error: nil)
      elsif refund&.failed? || refund&.cancelled?
        item.update!(status: :failed, last_error: refund.failure_message || error || "Provider refund failed")
      elsif error == "Refund amount exceeds refundable balance" && refund.nil?
        item.update!(status: :failed, last_error: "Refund amount exceeds refundable balance; finance review is required")
      elsif error
        item.update!(status: :failed, last_error: error)
      else
        item.update!(status: :waiting_on_pending_refund, last_error: "Refund pending provider confirmation")
      end
    end
  end
end
