# frozen_string_literal: true

module Commerce
  # P10 strict at every payout entry point (docs/design/never-fulfilled-
  # captures.md §8.7, §10.1, §6.7): no payout on an event with an open
  # never-fulfilled item is created, released from hold, submitted,
  # finalized or recorded as paid. The same codes back the database guards
  # (hafapass_payout_repayment_fence on payouts, the submission audit and
  # statement finalization), so an older release's payout writers fail
  # closed too; this check gives the new release a clear message first.
  #
  # Money that already left is still recorded: a payout whose submission was
  # authorized before the earliest open item opened, with a transfer
  # confirmed before that time, may be recorded as paid with an explicit,
  # audited confirmation. A payout first submitted after the hold opened
  # never can (the submission itself is refused).
  #
  # never_fulfilled_buyer_overpaid is a hold only until its capture is proven
  # platform-only (P4, §8.7): then it alerts and audits without holding the
  # organizer. The proof is the database's own hafapass_overpaid_platform_only,
  # which hafapass_payout_block_start also uses, so every reader and fence
  # agrees. The hold is per event, so unrelated events' payouts are never
  # held by it.
  module NeverFulfilledPayoutHold
    CODES = FinancialIntegrity::PAYOUT_BLOCKING_CODES
    MESSAGE = "A buyer repayment on this event is unresolved; resolve it in Refund issues before paying out"
    PAID_MESSAGE = "A buyer repayment on this event is unresolved. Only a transfer submitted and sent before " \
      "the hold opened can be recorded: confirm it was sent before the hold, with its transfer time."

    OVERPAID_CODE = FinancialIntegrity::OVERPAID_CODE
    PROVEN_SQL = "hafapass_overpaid_platform_only(reconciliation_exceptions.payment_id)"

    # Open over-return exceptions that do not hold payouts or finalization.
    def self.proven_platform_only_overpaid(relation = ReconciliationException.open)
      relation.where(code: OVERPAID_CODE).where(PROVEN_SQL)
    end

    # Open exceptions that hold the organizer's payouts and statements: every
    # open item except a proven platform-only over-return.
    def self.holding_exceptions(relation = ReconciliationException.open)
      relation.where("reconciliation_exceptions.code <> ? OR NOT #{PROVEN_SQL}", OVERPAID_CODE)
    end

    def self.blocked?(event)
      block_started_at(event).present?
    end

    # When the earliest open blocking item on the event opened (the database
    # guards' own function), or nil.
    def self.block_started_at(event)
      value = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(["SELECT hafapass_payout_block_start(?)", event.id])
      )
      value && ActiveRecord::Type::DateTime.new.cast(value)
    end

    # CodeRabbit 4703321645: a verified Stripe fee on an organizer-borne
    # payment-scope capture has no fee component (A1 §4.6 item 8), so no
    # statement line charges it yet. Its open review exception already
    # blocks finalization (Settlements::Finalizer); a payout on a version
    # finalized earlier is also held here, at creation, submission and
    # release, until finance books the exact cost and closes the review.
    # HåfaPass-borne (the default snapshot) opens no review and holds nothing.
    ORGANIZER_PROCESSING_MESSAGE = "Card processing on a payment returned to a buyer is waiting for review before " \
      "it can be charged on this statement; resolve it in Refund issues before paying out"

    ORGANIZER_PROCESSING_PAID_MESSAGE = "Card processing on a payment returned to a buyer is waiting for review. " \
      "Only a transfer submitted and sent before the review opened can be recorded: confirm it was sent before the " \
      "hold, with its transfer time."

    def self.organizer_processing_held?(event)
      organizer_processing_started_at(event).present?
    end

    # When the earliest open organizer-borne processing review on the event
    # opened (its recorded creation, like hafapass_payout_block_start), or
    # nil. The dated prior-send exception for paid recording uses it.
    def self.organizer_processing_started_at(event)
      ReconciliationException.open.where(code: StripeProcessingFees::REVIEW_CODE)
        .where(payment_id: UnfulfilledCapture.payment_scope.where(processing_bearer: "organizer")
          .where(order_id: event.orders.select(:id)).select(:payment_id))
        .minimum(:created_at)
    end

    # Whether this payout's submission was authorized before `time`.
    def self.submitted_before?(payout, time)
      AuditLog.where(auditable: payout, action: "payout.submission_requested").where("occurred_at < ?", time).exists?
    end
  end
end
