# Gate H — Low-Value Live-Money Proof

## Purpose

Gate H proves that the approved Guam business, organizer, production charge provider, payout path, and settlement bank can move and explain real money from end to end. It is deliberately separate from sandbox testing, platform-capability approval, accounting unit tests, Gate G rehearsal, and the later public pilot.

HafaPass does not claim this proof has happened merely because the controls exist. The real charge, provider refunds, payout, bank receipt, communications, and restricted evidence bundle must be produced by the named finance team and independently inspected.

Never store card data, bank numbers, identity documents, provider secrets, unredacted statements, or buyer PII in this record or Git. Store them in the approved restricted system. HafaPass retains stable references, SHA-256 digests, provider object IDs, local immutable record IDs, cent totals, actors, and timestamps.

## Why the proof path is separate

Normal paid events fail closed on Gate H, but Gate H cannot exist until one genuine transaction has run. HafaPass resolves that circularity with an intentionally narrow proof-candidate path—not a generic gate bypass:

- an administrator marks the event as a live-money proof candidate before Gates E–G;
- the candidate flag is part of the material event digest, so changing it invalidates later event approvals;
- the event title must begin `[LIVE MONEY TEST]`;
- it must have capacity one, exactly one general-admission ticket, no pricing tiers, add-ons, promo codes, or assigned seating, and a base price from 1–500 cents;
- the final order total, including fees, must remain within the separately authorized maximum of at most 500 cents;
- proof candidates are excluded from marketplace results, public event detail, favorites/referrals, organizer/venue discovery, Open Graph pages, and the sitemap;
- only a signed-in HafaPass administrator may open the explicit private proof view or submit the order;
- a different administrator must approve an authorization locked to the candidate, current Gate G approval, buyer-email digest, connected account, provider configuration, deployed revision, maximum amount, and a maximum two-hour window; and
- the authorization is consumed by one order. A failed or uncertain run requires finance review and a new authorization; it is never silently reused.

The candidate must be configured before Gate E, then complete Gates E, F, and G like any production candidate. Do not mark a normal pilot event temporarily, publish a discoverable test event, share the private path, or edit the database to bypass these controls.

## Prerequisites

Before requesting an authorization, verify all of the following:

1. Gate A legal, tax, privacy, accessibility, insurance, and operational decisions are current.
2. Gate B contains written Guam approval for the actual entity/model and a current independently approved connected account.
3. The `stripe_live` platform capability is configured and independently approved for the exact production credential revision. HafaPass currently implements Stripe for browser live charges; a PayPal charge flow is not implemented and must not be represented as proven.
4. The proof event has current Gate E, Gate F, and Gate G approvals tied to its candidate flag and exact event configuration.
5. The actual organizer, bank, production provider account, finance lead, independent approver, and restricted evidence location are named.
6. Support can identify the proof order, payment, refunds, settlement, payout, and outbound messages without seeing bank/card secrets.

## Execution sequence

### 1. Authorize the one-time charge

In Admin → Events → Gate H:

1. enter the finance operator's exact sign-in email;
2. set a final-order ceiling from 1–500 cents;
3. set an expiry no more than two hours away;
4. submit the authorization; and
5. have a different administrator inspect the candidate, current Gate G approval, live provider/account state, amount, buyer, and expiry before approving.

The approved operator opens the private proof checkout from the Gate H dialog. Confirm the displayed event, quantity, total, live-mode banner, provider, and receipt email before submitting. Do not retry an ambiguous provider result with a new authorization or idempotency key until reconciliation determines whether a charge exists.

### 2. Confirm the charge and communications

Wait for the signed provider webhook to mark the local payment successful. Record the redacted provider charge reference, local order/payment IDs, charged cents, currency, processing-fee evidence, buyer receipt, message-delivery status, and support trace. The provider and local charge totals must match exactly.

### 3. Prove partial refund and initial settlement

Issue a genuine partial provider refund and wait for a successful provider/local result. Confirm the buyer notice and refund allocation. Complete the controlled event, resolve every pending refund/dispute/reconciliation exception, and finalize the first immutable settlement. Record its version, source digest, payable amount, processing fees, and organizer statement visibility.

### 4. Prove payout and bank receipt

Submit the payout from the first settlement using the approved connected account and an idempotency key. For a manual local-bank path, `processing` means finance must execute and reconcile the controlled bank transfer; it is not evidence of payment. Mark it paid only from provider/bank facts, replace the local placeholder with the actual redacted transfer reference, retain the bank receipt in restricted storage, and verify provider payout cents = local payout cents = bank receipt cents.

### 5. Prove the post-payout liability

After the payout is paid, refund the remaining charge so the order is fully refunded. Confirm the final buyer notice. Finalize a new immutable settlement version after the payout and final refund. It must match the current ledger digest and show the resulting positive negative-balance amount. This demonstrates that HafaPass carries a real post-payout liability instead of erasing it or paying the same entitlement twice.

The required chronology is:

`live charge → partial refund → first settlement → paid payout/bank receipt → final refund → negative-balance settlement`

## Reconciliation and evidence submission

Before submitting Gate H, reconcile and enter all of these facts:

- actual legal entity, organizer, bank, provider approval, charge provider, payout provider, and production-environment references;
- local event, Gate G approval, authorization, order, payment, both refunds, both settlements, and payout IDs;
- charge, refund, processing-fee, payout, bank-receipt, and negative-balance cents from provider/bank and local records;
- provider payment/refund/payout references and immutable settlement/bank-receipt SHA-256 digests;
- buyer charge receipt, both buyer refund notices, organizer statement, organizer payout notice, and support trace; and
- zero charge, refund, processing, payout, and negative-balance variance, with zero open reconciliation exceptions, disputes, or pending refunds.

The submission fails if any linked record crosses an event or organization, any provider reference is simulated, the authorization did not create the order, the two refunds do not equal the charge, the payout is not paid, the bank amount differs, the post-payout settlement is stale/non-negative, the chronology is wrong, an external fact differs from its local record, a required communication is missing, or any unexplained variance/count is nonzero.

A different administrator must inspect the restricted source bundle and approve or reject the immutable submission. Self-approval and duplicate/conflicting decisions fail closed. Revoke immediately after a provider/account/entity/bank/configuration/revision change, an evidence-integrity concern, a newly discovered mismatch, or loss of approval. Provider state, platform credential revision, or application revision changes automatically make the old approval inactive.

## Release effect

- Normal paid events require a current organization/account Gate H approval in addition to their event-specific Gates E–G.
- Proof candidates do not require a pre-existing Gate H approval, but they require the one-use authorization above.
- Free events do not require live-money proof, but still require their applicable policy, organizer, event, validation, and rehearsal gates.
- Gate H is organization/account/configuration-specific; it does not approve a different provider, bank, entity, organizer account, credential revision, or HafaPass revision.
- Gate H is necessary but not sufficient for public launch. Gate I governs the bounded live pilot and Gate J governs closeout and expansion.

## Exit evidence

Gate H is externally complete only when the restricted bundle contains the actual approved entity/organizer/bank/provider decisions, real provider IDs, both refund results, both immutable settlement digests, paid payout, bank receipt and digest, buyer/organizer/support evidence, cent-exact reconciliation, two distinct administrators, and zero unexplained variance or open exception.
