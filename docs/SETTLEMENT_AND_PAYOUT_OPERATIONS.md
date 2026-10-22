# Settlement and Payout Operations

## Statement lifecycle

1. Complete or cancel the event.
2. Resolve every pending refund and open dispute.
3. Review the live preview: gross, discounts, buyer refunds, net charged, buyer-paid HafaPass fees, actual processing costs deducted from the organizer, processing covered by HåfaPass, organizer proceeds, reserves, adjustments, payable amount, prior payouts, and negative balance. Each order's processing-fee bearer snapshot decides which processing column it uses; see [Stripe processing fee evidence](./STRIPE_PROCESSING_FEE_OPERATIONS.md#who-bears-the-processing-cost).
4. Finalize the statement. An identical ledger returns the existing version; changed activity creates the next immutable version.
5. Confirm the connected account has current provider capabilities, no provider requirements, and an unexpired independent readiness approval; then confirm the organization-wide available balance is sufficient.
6. Submit the payout with a unique idempotency key.
7. Reconcile processing payouts to paid, failed, or reversed from provider/bank evidence. Every transition is audited.

The organizer's **Request payout** action reserves a request. A `processing` result does not confirm a transfer. Production simulation cannot mark a payout paid. Manual processing remains reserved until an administrator records a confirmed outcome.

## Recording a confirmed outcome

The administrator endpoint `PATCH /api/v1/admin/payouts/:id` accepts `status` (`paid`, `failed`, or `reversed`), an optional `provider_payout_id`, and an `evidence` object containing:

- `reference`: an opaque reference to the restricted bank/provider confirmation;
- `confirmed_at`: the actual confirmation timestamp in ISO8601 with an offset, after the request and not in the future;
- `reason`: what was reconciled, including the matched cents and outcome.

Recording `paid` requires a real provider/bank transfer identifier; `sim_*` and `manual_po_*` placeholders are rejected. A reversal retains the original transfer identifier and records its own confirmation reference. Failed/reversed outcomes also require confirmation evidence before releasing reserved funds. Store bank documents in the restricted evidence location and send only their reference, never account credentials or full bank documents.

The status change and append-only actor/evidence audit commit together under the organization's payout lock. Competing terminal outcomes cannot both win. An exact retry returns the saved outcome; changed evidence or a conflicting outcome is refused. This endpoint records an operator's confirmation; it does not query a bank, send money, or independently verify the supplied document.

Late submission results use the same locks. A late processing reply or error cannot overwrite an evidence-backed terminal outcome. A conflicting paid reply reopens `processing` with `provider_result_conflict`, preserves the earlier transfer identity and both outcomes in the audit trail, and blocks organization payouts. Review the conflict and restricted confirmation evidence before resolving it. The refusal response supplies `conflict_audit_id`; the new reconciliation's `evidence.conflict_audit_id` must acknowledge that exact latest conflict. Retrying the earlier request without this acknowledgment keeps the hold.

Automated production payout adapters remain disabled. Before enabling one, implement and test crash-safe dispatch ownership that prevents a failed/reversed reconciliation from releasing funds while its original provider submission can still pay. Session advisory locks require a direct PostgreSQL connection and must not be added to the pooled application URL. The current manual gateway makes no external transfer; administrator evidence records the separate bank outcome.

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

Before a paid public pilot, complete the real chronological charge → partial refund → settlement → payout/bank receipt → final refund → negative-balance settlement proof and approval in [Gate H Low-Value Live-Money Proof](./GATE_H_LIVE_MONEY_PROOF.md). A simulated payout, a `processing` manual transfer, or a provider dashboard screenshot without matching local/bank cents is not Gate H evidence.
