# frozen_string_literal: true

module Commerce
  # P10 strict at every payout entry point (docs/design/never-fulfilled-
  # captures.md §8.7, §10.1): no payout on an event with an open
  # never-fulfilled item is created, released from hold, submitted or
  # recorded as paid. The same codes back the database fence
  # (hafapass_payout_repayment_fence), so an older release's payout writers
  # fail closed too; this check gives the new release a clear message first.
  #
  # never_fulfilled_buyer_overpaid is not a hold (P4): a proven platform-only
  # over-return alerts and audits without holding the organizer. The hold is
  # per event, so unrelated events' payouts are never held by it.
  module NeverFulfilledPayoutHold
    CODES = FinancialIntegrity::PAYOUT_BLOCKING_CODES
    MESSAGE = "A buyer repayment on this event is unresolved; resolve it in Refund issues before paying out"

    def self.blocked?(event)
      order_ids = Order.where(event_id: event.id).select(:id)
      open = ReconciliationException.open.where(code: CODES)
      open.where(order_id: order_ids).or(open.where(payment_id: Payment.where(order_id: order_ids).select(:id))).exists?
    end
  end
end
