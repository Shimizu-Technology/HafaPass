# frozen_string_literal: true

module Commerce
  # Returns a verified late capture to the buyer: a card payment that
  # succeeded after HåfaPass had already released its order (hold expired or
  # order cancelled). The order was never fulfilled, so the whole captured
  # amount is owed back.
  #
  # Callers: LateCaptureRefundJob (automatic, enqueued by OrderLifecycle when
  # it records the late capture) and the refund reconciliation queue's
  # "Refund buyer" action. Admin reconciliation tools should call this service
  # too, so every path shares one idempotency key per payment:
  # "late-capture:payment:<payment id>".
  #
  # RefundCreator#refundable_late_capture? verifies the released reservation
  # and exact captured amount. On success RefundCreator resolves the open
  # late-capture exceptions with an audit entry and emails the buyer.
  class LateCaptureRefund
    CODES = %w[late_payment_success_after_inventory_release late_payment_success_after_hold_expiry].freeze
    REASON = "late_capture_refund"

    class NotApplicable < StandardError; end

    def self.idempotency_key(payment)
      "late-capture:payment:#{payment.id}"
    end

    def self.open_issue?(payment)
      ReconciliationException.open.where(payment: payment, code: CODES).exists?
    end

    def self.call(payment:, requested_by: nil)
      existing = payment.order.refunds.find_by(idempotency_key: idempotency_key(payment))
      raise NotApplicable, "This payment has no open late-capture exception" unless existing || open_issue?(payment)
      unless payment.provider == "stripe" && %w[test live].include?(payment.provider_environment)
        raise NotApplicable, "Only Stripe test or live payments can be refunded automatically"
      end

      RefundCreator.call(order: payment.order, payment: payment, reason: REASON, requested_by: requested_by,
        idempotency_key: idempotency_key(payment))
    end
  end
end
