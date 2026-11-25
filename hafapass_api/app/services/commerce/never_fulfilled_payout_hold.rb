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
  # never_fulfilled_buyer_overpaid is not a hold (P4): a proven platform-only
  # over-return alerts and audits without holding the organizer. The hold is
  # per event, so unrelated events' payouts are never held by it.
  module NeverFulfilledPayoutHold
    CODES = FinancialIntegrity::PAYOUT_BLOCKING_CODES
    MESSAGE = "A buyer repayment on this event is unresolved; resolve it in Refund issues before paying out"
    PAID_MESSAGE = "A buyer repayment on this event is unresolved. Only a transfer submitted and sent before " \
      "the hold opened can be recorded: confirm it was sent before the hold, with its transfer time."

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

    # Whether this payout's submission was authorized before `time`.
    def self.submitted_before?(payout, time)
      AuditLog.where(auditable: payout, action: "payout.submission_requested").where("occurred_at < ?", time).exists?
    end
  end
end
