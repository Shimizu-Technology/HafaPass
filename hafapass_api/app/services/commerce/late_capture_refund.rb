# frozen_string_literal: true

module Commerce
  # Returns a never-fulfilled capture to its buyer: a card payment that
  # succeeded after HåfaPass had already released its order (hold expired or
  # order cancelled), or a distinct second payment on a fulfilled order. The
  # order was never fulfilled by it, so the whole captured amount is owed.
  #
  # Callers: LateCaptureRefundJob (automatic; enqueued by OrderLifecycle and
  # by the evaluator) and the reconciliation queue's "Refund buyer" action.
  # Every caller goes through RefundCreator, which routes a fenced payment to
  # Commerce::BuyerRepayment (docs/design/never-fulfilled-captures.md §6):
  # one repayment operation at a time, each with its own key
  # ("late-capture:payment:<id>" for the first, ":op:<n>" after), sized to
  # what is still available under the order lock.
  class LateCaptureRefund
    CODES = %w[
      late_payment_success_after_inventory_release
      late_payment_success_after_hold_expiry
      pass_all_included_nights_cancelled
    ].freeze
    REASON = "late_capture_refund"

    class NotApplicable < StandardError; end

    # The first repayment operation's key, unchanged from the legacy
    # automatic refund so an old worker's refund is adopted as operation 1.
    def self.idempotency_key(payment)
      "late-capture:payment:#{payment.id}"
    end

    # Exceptions under which HåfaPass owes this payment back.
    def self.repayment_codes
      CODES + [NeverFulfilledClassification::SECOND_CAPTURE_CODE, NeverFulfilledResolution::REOPENED_CODE]
    end

    def self.open_issue?(payment)
      ReconciliationException.open.where(payment: payment, code: repayment_codes).exists? ||
        RepaymentOperation.open_states.exists?(payment_id: payment.id)
    end

    def self.call(payment:, requested_by: nil, source: "automatic")
      raise NotApplicable, "This payment has no open late-capture exception" unless open_issue?(payment)
      unless payment.provider == "stripe" && %w[test live].include?(payment.provider_environment)
        raise NotApplicable, "Only Stripe test or live payments can be refunded automatically"
      end
      raise NotApplicable, "This payment is not returned through the repayment workflow" unless BuyerRepayment.fenced_payment?(payment)

      RefundCreator.call(order: payment.order, payment: payment, reason: REASON, requested_by: requested_by,
        repayment_source: source)
    end
  end
end
