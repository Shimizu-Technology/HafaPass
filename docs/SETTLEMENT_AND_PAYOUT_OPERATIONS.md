# Settlement and Payout Operations

## Statement lifecycle

1. Complete or cancel the event.
2. Resolve every pending refund and open dispute.
3. Review the live preview: gross, discounts, buyer refunds, net charged, buyer-paid HafaPass fees, actual processing costs, organizer proceeds, reserves, adjustments, payable amount, prior payouts, and negative balance.
4. Finalize the statement. An identical ledger returns the existing version; changed activity creates the next immutable version.
5. Confirm the connected account has current provider capabilities, no provider requirements, and an unexpired independent readiness approval; then confirm the organization-wide available balance is sufficient.
6. Submit the payout with a unique idempotency key.
7. Reconcile processing payouts to paid, failed, or reversed from provider/bank evidence. Every transition is audited.

## Adjustment rules

- Use `reserve_hold` with a negative amount and `reserve_release` with a positive amount.
- Use `manual_credit` and `manual_debit` only with a specific reconciliation reason and supporting evidence.
- Reverse an adjustment through its reversal operation; do not delete it.
- Never attach an event, order, or dispute from another organization.
- A lost dispute is sourced directly from the dispute ledger. Do not duplicate it with a manual `dispute_loss` adjustment.

## Incident rules

- If provider submission is uncertain, retry with the same idempotency key.
- If any sale, refund, dispute, fee, reserve, adjustment, or payout changed after finalization, finalize a new version before paying.
- A failed payout releases its reservation; a reversed payout restores funds only after the reversal is recorded.
- A post-payout liability produces a negative balance and reduces later organization payouts. Do not zero it manually.
- Escalate any cent variance, unexplained provider object, cross-currency activity, or payout without evidence; do not force reconciliation.

## Release evidence

For each production provider, retain the onboarding evidence, provider approval, connected-account identifier, signed terms, test transaction identifiers, settlement version and digest, payout identifier, bank receipt, reconciliation result, approving finance user, and audit-log request IDs. Link the restricted bundle through the append-only payment-readiness submission and independent approval described in [Gate B Payment Readiness Operations](./GATE_B_PAYMENT_READINESS_OPERATIONS.md).
