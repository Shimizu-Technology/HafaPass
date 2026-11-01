# frozen_string_literal: true

module Commerce
  # An administrator's response to a Stripe early fraud warning: refund the
  # order's remaining balance with Stripe reason "fraudulent". The refund
  # cancels every unadmitted ticket when it succeeds (RefundCreator full-refund
  # path), so the QR codes stop admitting. Refunding first usually prevents a
  # chargeback fee. The request, the note and the resolution are audited; one
  # warning can only ever produce one refund (idempotency key
  # "early-fraud-warning:<exception id>").
  class EarlyFraudWarningRefund
    class Error < StandardError; end

    CODE = "early_fraud_warning"
    REASON = "fraudulent"

    def self.call(**)
      new(**).call
    end

    def initialize(issue:, actor:, note:, request: nil)
      @issue = issue
      @actor = actor
      @note = note.to_s.strip
      @request = request
    end

    def call
      raise Error, "Add a note explaining the fraud decision" if @note.blank?
      raise Error, "Note is too long" if @note.length > 2000
      raise Error, "Only administrators can refund a fraud warning" unless @actor&.admin?
      unless @issue.code == CODE && @issue.order && @issue.payment
        raise Error, "This exception is not an early fraud warning for a known order"
      end

      key = "early-fraud-warning:#{@issue.id}"
      replay = order.refunds.find_by(idempotency_key: key)
      raise Error, "This fraud warning is already resolved" if @issue.resolved? && replay.nil?

      record!("order.fraud_refund_requested", order, outcome: "requested",
        attempt: @request&.request_id.presence || SecureRandom.uuid,
        metadata: { reconciliation_exception_id: @issue.id, payment_id: @issue.payment_id, note: @note })
      refund = RefundCreator.call(order: order, payment: @issue.payment, reason: REASON, requested_by: @actor,
        idempotency_key: key)
      resolve!(refund) if (refund.succeeded? || refund.pending?) && @issue.reload.open?
      refund
    rescue RefundCreator::RefundError => e
      raise Error, e.message
    end

    private

    def order
      @issue.order
    end

    def resolve!(refund)
      @issue.resolve!
      record!("reconciliation_exception.resolved", @issue, outcome: "succeeded",
        metadata: { code: CODE, order_id: order.id, payment_id: @issue.payment_id, refund_id: refund.id,
          refund_status: refund.status, note: @note })
    end

    def record!(action, auditable, outcome:, metadata:, attempt: nil)
      AuditLogger.record!(action: action, auditable: auditable, actor: @actor,
        organization: order.event.organization, event: order.event, source: "admin", outcome: outcome,
        deduplication_key: ["early-fraud-warning", @issue.id, action, attempt].compact.join(":"),
        metadata: metadata, request: @request)
    end
  end
end
