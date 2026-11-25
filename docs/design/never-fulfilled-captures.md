# Never-fulfilled captures: prevention, classification and buyer-owed ledger

**Status:** design for review (PR #248). No code in this change.
**Base:** `origin/main` `7bcd97c2` (#247) plus the #248 branch at `57de7f15`.
**Decisions needed from Leon and the CPA:** see [Open questions](#9-open-questions-for-leon-and-the-cpa).

## Summary

A never-fulfilled capture is a Stripe payment that succeeds after HåfaPass has already released the order's hold or inventory. The lifecycle records a late-capture exception, issues no tickets, leaves `orders.completed_at` null and refunds the buyer automatically. The buyer gets the money back, but four review rounds in a row found reporting and settlement bugs. They come from two habits:

1. **Classification by inference.** Readers decide "never fulfilled" from a null `completed_at` plus an exception row found within a time window. Hand-added, backdated or late exception rows change the answer.
2. **Allocations that don't match.** Refunds use their item-level split; disputes use a separate proration. Comparing the two gives false excess in one case and misses real excess in another.

This design replaces both:

- **Prevention:** cancel the PaymentIntent or expire the Checkout Session at Stripe *before* releasing inventory locally, and keep the inventory counted for a short grace period until Stripe confirms. This makes most of these captures impossible. A few remain (event changes, provider outages), so the accounting still has to be right.
- **Durable classification:** `orders.never_fulfilled_at` and `orders.never_fulfilled_payment_id`, written once in the same transaction that records the late capture, never cleared, and constrained so the order can never be completed.
- **One buyer-owed ledger:** captured gross, minus every refund and lost dispute at gross, recognized no earlier than the capture. Excess is measured on cumulative gross. One cumulative allocation gives the ticket and fee shares, so a full return always clears the full ticket share.
- **Settlement:** never-fulfilled orders leave every organizer total and statement line. Each one gets a single zero-amount informational line.
- **Exception resolution:** "still owed" comes from the ledger, lost disputes included. Refunds never ask Stripe for money already returned, and a repaid capture closes itself with an audit entry.

---

## 1. Upstream prevention

### 1.1 How the path is reached today

| Flow | Buyer deadline | Who releases | Provider step today | How a capture can still land after release |
| --- | --- | --- | --- | --- |
| Online PaymentIntent checkout (`OrderCreator`, `allowed_payment_method_types: ["card"]`) | `HOLD_DURATION` = 10 min (`order_creator.rb:7`) | `ExpireInventoryHoldsJob` → `OrderLifecycle.expire!` every minute; buyer `cancel!` | `expire!` first retrieves the PaymentIntent (`succeeded_provider_payment`, 5 s timeout). If it already succeeded, it completes late. Otherwise it releases locally, commits, **then** cancels the PaymentIntent (`cancel_provider_payments!`). | (a) The buyer confirms (often a 3DS return) between the retrieve and the cancel. The cancel then fails and records `provider_payment_cancel_failed`, and the success webhook arrives for a released order. (b) The retrieve times out or errors during a rush. `succeeded_provider_payment` returns `nil` and the order is released as if unpaid. (c) The success webhook is delayed past the deadline and the inventory has meanwhile sold (`InventoryHold.current` stops counting a hold at `expires_at`, whether or not the job has run). In every case `complete!` fulfills late if capacity is still free, and only otherwise records `late_payment_success_after_hold_expiry` or `..._after_inventory_release`. |
| Door-card Checkout Session (`OnlineDoorSale`) | `ONLINE_DOOR_HOLD_DURATION` = 35 min. The Session's `expires_at` equals `order.expires_at` (`persist_session!` checks this). | `ExpireInventoryHoldsJob` → `expire!` (door orders skip the provider check), the `checkout.session.expired` webhook, staff `OnlineDoorSale.cancel!` | Staff cancel expires the Session first and releases only after Stripe returns `expired` (correct order). The expiry job releases locally first and enqueues `ExpireDoorCheckoutSessionJob` after commit. | A buyer who pays seconds before the deadline has their signed `payment_intent.succeeded` processed after the local release. `reopen_expired` reuses the naturally expired holds when capacity is free. The capture is never fulfilled when the door allotment sold meanwhile, door admission ended (`door_admission_ended?`), seats were involved, or the event was unpublished. |
| Multi-night pass (either flow) | Same as the flow | Same, with all nights locked in ascending ID order (`docs/LOCKING.md`, "Multi-night pass completion…") | Same | Same races, plus `pass_all_included_nights_cancelled`: every included night was cancelled while payment was pending. Capacity must also be free on every night. |

**How often:** production has had no real sales, so there are no counts to quote. Qualitatively:

- Online checkout is rare in normal traffic. It becomes plausible in exactly the case that matters, the Copa on-sale rush (Jan 4, 2027): Stripe latency makes (b) likely, and sold-out ticket types turn a late capture into a never-fulfilled one instead of a late fulfillment.
- Door-card checkout is likelier per sale: small door allotments, a queue, staff-held 35-minute links and a hard admission end.
- Passes add organizer-driven night cancellations.

The design adds a weekly count (section 6) so we can measure it after launch.

### 1.2 What Stripe guarantees

- **Cancelling a PaymentIntent is final.** A PaymentIntent can be cancelled in `requires_payment_method`, `requires_capture`, `requires_confirmation`, `requires_action` or, rarely, `processing`. After cancellation "no additional charges are made by the PaymentIntent and any operations on the PaymentIntent fail with an error." A `succeeded` PaymentIntent cannot be cancelled. ([Cancel a PaymentIntent](https://docs.stripe.com/api/payment_intents/cancel), [PaymentIntent lifecycle](https://docs.stripe.com/payments/paymentintents/lifecycle)) Our intents are card-only, so `processing` is not expected; treat it as "unknown, keep the hold".
- **Expiring a Checkout Session is final.** Only an `open` Session can be expired; afterwards the customer cannot complete it. Expiring a `complete` Session errors. `StripeService.expire_door_checkout_session` already falls back to retrieving the Session to read its state. A custom `expires_at` must be 30 minutes to 24 hours after creation. For Checkout, the PaymentIntent itself can be cancelled only in `requires_capture`; otherwise expire the Session. ([Expire a Checkout Session](https://docs.stripe.com/api/checkout/sessions/expire), [Manage limited inventory](https://docs.stripe.com/payments/checkout/managing-limited-inventory), [Checkout Session object](https://docs.stripe.com/api/checkout/sessions/object))
- **Webhooks are not ordered.** Stripe does not guarantee events arrive in the order they were generated, so a dispute's events can reach us before the capture's. ([Webhooks: event ordering](https://docs.stripe.com/webhooks#event-ordering))
- **Disputes and refunds.** While a dispute is open, the charge cannot be refunded outside the dispute process (`refund_disputed_payment`). After a partial refund, the customer can normally dispute only the remaining balance. If a refund is pending when a dispute opens, Stripe recommends accepting or challenging the dispute rather than refunding, to avoid paying the buyer twice. ([How disputes work](https://docs.stripe.com/disputes/how-disputes-work), [Respond to disputes](https://docs.stripe.com/disputes/responding), [Error codes](https://docs.stripe.com/error-codes)) The ledger still handles excess defensively, because issuers and manual Dashboard actions do not always follow the normal rules.

### 1.3 Recommended preventions

All Stripe calls stay **outside** database transactions (`docs/LOCKING.md`, paragraph 1). Lock order is unchanged: event context → order → payment and holds → ticket types → tiers → seat session (LOCKING rows "Completion, cancellation, failure, or expiry without a claimed offer" and "Multi-night pass completion…"). The lifecycle rechecks state after taking its locks, as it does now.

**P1. Provider-first expiry and cancellation for online checkout (recommended, high value).** Change `OrderLifecycle.expire!` and `cancel!` for Stripe PaymentIntents:

1. Without locks, cancel the PaymentIntent with the existing key `cancel:payment:<id>`.
2. If Stripe returns `canceled`, take the usual lifecycle locks, recheck that the order is pending, and release. No later capture is possible.
3. If Stripe refuses because the intent `succeeded`, retrieve it and call `complete!(…, late_completion: true)` with the provider amount and currency. The holds are still counted (P2), so this fulfills.
4. If the result is `processing`, an error or a timeout, **do not release.** Leave the order pending and let the next job run retry. After the grace period (P2) capacity frees naturally, and today's late-capture handling is the fallback.

`provider_payment_cancel_failed` is then only recorded when the order is actually released without a confirmed cancel. A provider-check failure must never count as "not paid", which fixes case (b).

**P2. Capacity grace after the buyer deadline (recommended, needed by P1 and P3).** Keep the buyer-facing deadline (`orders.expires_at`, the checkout countdown in `CheckoutPage.jsx`, the Session `expires_at`). Set each inventory, catalog and seat hold's `expires_at` to deadline + `PROVIDER_RELEASE_GRACE`, so `InventoryHold.current` keeps counting the hold while the provider step finishes:

- online: 2 minutes;
- door: 3 minutes, which also covers Stripe's own Session expiry and webhook delivery.

`ExpireInventoryHoldsJob` still selects orders by `orders.expires_at`. The cost is that an abandoned cart holds inventory for 12 minutes instead of 10 during a sell-out rush (open question Q7).

**P3. Expire-first for door-card Sessions (recommended).** In `expire!` for `online_door_card?` orders, expire the Session at Stripe before releasing locally, as staff cancel already does. Then:

- `expired`: release;
- `complete`: keep the hold and wait for the signed `payment_intent.succeeded` (only a signed webhook may settle a door payment). The grace period keeps the inventory counted while it arrives;
- error: retry on the next job run.

`ExpireDoorCheckoutSessionJob` remains as a safety net.

**P4. Close pending payments before event-driven releases (recommended, low cost).** Before a night is cancelled or an event is unpublished, run P1/P3 for the pending orders it would release (pass orders that include the night, and door links). Only orders whose payment had already succeeded become never-fulfilled, and those are fulfilled-then-refunded by the normal cancellation path when the inventory still exists.

**P5. Don't open door links that outlive admission (product decision, Q6).** Stripe requires `expires_at` ≥ 30 minutes, so a door link opened in the last 30 minutes before admission ends can be paid after admission closes. Either refuse door-card links in that window (staff use card-present or cash), or accept the rare `admission_ended` refund.

**Not recommended:** extending the hold to match the Session (35 min) or a PaymentIntent (no expiry) for online sales. That keeps inventory off sale for abandoned carts during the rush.

P1 to P4 make the remaining cases: Stripe refusing or timing out for longer than the grace period, an event changing while a payment confirms, and `admission_ended`. They reduce frequency; they do not replace sections 2 to 5.

---

## 2. Durable classification

### 2.1 Columns

Additive migration on `orders`:

| Column | Type | Meaning |
| --- | --- | --- |
| `never_fulfilled_at` | `datetime`, null | Recording time of the qualifying capture: `GREATEST(COALESCE(payment.succeeded_at, payment.created_at), payment.created_at)` as written in that transaction. It is both the classification and the month anchor. |
| `never_fulfilled_payment_id` | `bigint` FK → `payments`, null, partial index | The captured payment that was never fulfilled. |
| `never_fulfilled_code` | `string`, null | The `Commerce::LateCaptureRefund::CODES` value, for display and audit. |

Check constraints (added `NOT VALID`, then validated in a second migration, following the repo's add/validate pattern):

- all three columns are null, or all three are set;
- `never_fulfilled_at IS NULL OR completed_at IS NULL`, so the database refuses to complete a never-fulfilled order.

Classify all three columns as financial, 7-year retention, in `config/data_retention.yml`. They contain no PII.

**Why on `orders` rather than `payments` or a ledger table:** every reader filters orders, and the "never completed" guard must sit on the same row as `completed_at` for a check constraint to enforce it. The FK still names the exact payment, which Sol's finding 5 asks for.

**Why no trigger for set-once:** the repo dumps `db/schema.rb`, which cannot represent triggers, and CI fails on any schema diff (#235). Set-once is enforced in the model instead:

- a `before_update` guard refuses any change to these columns once they are set;
- lifecycle code writes them with `update!`, never `update_columns`;
- a spec covers both;
- the CPA export's `current_integrity_alerts` lists any never-fulfilled order that has `completed_at` set or tickets in a state other than `cancelled`. Neither should be possible.

### 2.2 Lifecycle

- **Set:** only in `Commerce::OrderLifecycle.complete_with_audit!`, in the three branches that already create a `LateCaptureRefund::CODES` exception, in the same transaction and under the same event → order → payment locks, right after `mark_payment_succeeded!`. No new locks. A duplicate notice for the same payment finds the columns set and changes nothing. That branch already skips the duplicate exception.
- **Never unset.** Refunds, disputes, resolving the exception and retention leave the columns alone. Retention anonymizes PII, and these columns hold none.
- **Tickets issued later:** not possible through current code.
  - `reopen_expired` requires that no late-capture exception exists for the payment.
  - `sync_pass_holders` reads only active completed pass orders.
  - Comp and guest-list tickets are separate orders.
  - Guest recovery and transfers move existing tickets and never create them.

  The check constraint makes a future mistake fail loudly. `issue_tickets!` also raises when `never_fulfilled_at` is set. If a buyer still wants tickets, staff sell a new order and the never-fulfilled capture is refunded as usual. We never convert it.
- **Hand-added exceptions:** an exception row on its own no longer classifies anything (finding 5). Only the lifecycle writes the columns.

### 2.3 Existing rows

Production has 0 events and 0 real sales. Staging and QA databases may have test rows. Add a rake task, `never_fulfilled:backfill`, with `DRY_RUN=1` as the default. It prints candidates and the reason for each skipped row, and writes an `order.never_fulfilled_backfilled` audit per row. A candidate must meet all of these:

- `completed_at IS NULL`;
- exactly one captured payment (`succeeded`, `partially_refunded` or `refunded`) whose amount equals `orders.total_cents`;
- a `LateCaptureRefund::CODES` exception linked to that payment and order, created within 60 seconds after the capture's recording time (the same transaction in practice), never before it;
- no tickets other than `cancelled`, no `order.completed` audit, and no consumed holds.

Anything else is skipped for manual review. Readers use only the columns, so a legacy row the backfill skips is treated as fulfilled, which was the behavior before #247. The migration itself does not backfill.

`Commerce::NeverFulfilledCapture` becomes a thin reader over the columns: `order_sql` returns `orders.never_fulfilled_at IS NOT NULL`, and `recorded_at` is the column. `EVIDENCE_WINDOW_SECONDS` and the exception join are removed.

### 2.4 Provider qualification (the minor finding)

The classification is a provider fact and ignores the environment: test-mode captures are classified too. Each reader then applies the environment scope it already applies to every other order:

- the CPA export and BPT export use live USD agent captures;
- the calculator uses `Order.excluding_test_payments`, which filters only in production.

Move the CPA's `LIVE_AGENT_CAPTURE_SQL` and the matching filter in `TaxReports#bpt_event_rows` into one `Payment.live_agent_capture` scope used by the CPA custodial query, the non-custodial bridge and the BPT export. That also removes half of deferred Clover residual 5 in `docs/CPA_MONTHLY_EXPORT_GUIDE.md`. The bridge's `never_fulfilled_capture_order_ids` switches from `completed_at IS NULL` to the column, which removes the other half.

---

## 3. Buyer-owed ledger

### 3.1 Source of truth

`Commerce::BuyerOwedLedger` is a read-only service over immutable rows. It stores nothing itself, because every writer already writes an append-only or status-once row. A second stored ledger would need every refund and dispute writer to keep it in sync, which is the kind of drift this design removes.

For a never-fulfilled order *o*, with payment *p* = `never_fulfilled_payment`:

| Symbol | Definition |
| --- | --- |
| *C* | Captured gross, `p.amount_cents`. `RefundCreator#late_capture_payment` already requires this to equal `o.total_cents`. |
| *T* | Ticket share, `Σ order_items.organizer_proceeds_cents` (tickets and add-ons, the part the CPA books as proceeds). *C − T* is the fee and tax share. |
| *t₀* | `o.never_fulfilled_at` |
| Movements *mᵢ* | Every **succeeded** refund on *p* at gross `refunds.amount_cents`, whatever its source (automatic `late_capture_refund`, admin, organizer, fraud, `provider_webhook_reconciliation` from `ExternalRefundRecovery`), recorded at `COALESCE(refunds.succeeded_at, refunds.created_at)`. Every **lost** dispute on *p* at gross `disputes.amount_cents`, recorded at `COALESCE(dispute_lost_audit.created_at, disputes.closed_at)` (the CPA's `DISPUTE_LOST_AT_SQL`). Auditless lost disputes without `closed_at` stay integrity alerts, as today. |
| Recognition time | *rᵢ* = `GREATEST(recordedᵢ, t₀)`. A return is never recognized before its capture (finding 3). When *recordedᵢ* < *t₀*, the CPA note says: "Lost dispute recorded 28 Feb 2027, before its capture was recorded; recognized 1 Mar 2027." |
| In flight (not movements) | Pending refunds (including `provider_result_unknown`) and open disputes on *p*. They block new refunds and closing the exception. They are not returns. |

At any time *t*:

- *R(t)* = Σ *mᵢ* with *rᵢ* < *t* (cumulative gross returned)
- *A(t)* = min(*R(t)*, *C*) (applied to the debt)
- *X(t)* = *R(t)* − *A(t)* (excess: money returned twice, a HåfaPass loss)
- *O(t)* = *C*·[*t₀* < *t*] − *A(t)* (gross still owed, never negative)

### 3.2 One allocation

The ticket and fee shares of the applied amount come from a single cumulative allocation, never from each movement's own split:

```
ticket(A) = Commerce::MoneyAllocator.call(A, [T, C − T]).first
fee(A)    = A − ticket(A)
```

Properties, for two weights and `MoneyAllocator`'s floor-plus-remainder-to-first rule:

- `ticket(0) = 0` and `ticket(C) = T` exactly, so **a full gross return always clears the full ticket balance** (finding 2b).
- `ticket` and `fee` are both non-decreasing in *A*. `fee(A) = ⌊A(C−T)/C⌋` rises by at most 1 per cent of *A*, so neither share moves backwards between months.
- Excess is decided on gross *R* against *C* alone, so a refund's item split can no longer create or hide excess (findings 2a and 2b).

The BPT export splits `fee(A)` between `fee_cents + organizer_fee_cents` and `tax_cents` with the same cumulative allocator over the order items' totals. For never-fulfilled orders, the CPA and BPT exports use this allocation **instead of** `RefundItem` splits. The refund rows themselves are unchanged and still drive refund mechanics. A full automatic refund gives the same numbers either way. A partial refund can differ from its `RefundItem` split by at most one cent per share, so the CPA guide must say which rule applies.

### 3.3 Month projection and identities

For Guam month *M* = [*s*, *e*):

| CPA column (never-fulfilled share only) | Value |
| --- | --- |
| `opening_buyer_refunds_owed` | *T*·[*t₀* < *s*] − ticket(*A(s)*) |
| `buyer_refund_captures` | *T*·[*s* ≤ *t₀* < *e*] |
| `buyer_refunds_paid` | ticket(*A(e)*) − ticket(*A(s)*) |
| `closing_buyer_refunds_owed` | *T*·[*t₀* < *e*] − ticket(*A(e)*) |
| `fee_revenue_gross` | (*C* − *T*)'s fee part when *s* ≤ *t₀* < *e* (unchanged rule) |
| `fee_refunds` | fee(*A(e)*) − fee(*A(s)*), fee part (Q2 covers the lost-dispute part) |
| reconciliation note | *X(e)* − *X(s)* in month, *X(e)* cumulative, **at gross** |
| `chargebacks`, `proceeds_*`, `organizer_processing_deducted` | always 0 for never-fulfilled orders (processing is under the switch, section 4.2) |

Identities, which hold by construction:

- **Roll-forward:** opening + captures − paid = closing, because both sides equal *T*·[*t₀* < *e*] − ticket(*A(e)*).
- **Continuity:** closing(*M*) = opening(*M*+1), because both are evaluated at *e*.
- **Bounds:** 0 ≤ closing ≤ *T*. A month before *t₀* has *A* = 0 because every *rᵢ* ≥ *t₀*, so no negative opening can appear (finding 3).
- **Gross:** applied + owed = captured, and returned = applied + excess.
- **Closed-month stability:** every input is an immutable recording time, or *t₀*, which is written once in the capture transaction. A later movement only changes months after its own recognition time.

`buyer_returns_by_event` in `cpa_monthly_report.rb` is replaced by a call to the ledger. Never-fulfilled orders are rare, so loading them and computing in Ruby (as the current code does) is fine. If volume ever grows, the same rule can move into SQL with window sums.

### 3.4 Excess

When a movement makes *R* > *C*, the writer creates a `never_fulfilled_buyer_overpaid` reconciliation exception in the same transaction (`RefundCreator` success, or dispute finalization in `StripeWebhookProcessor#process_dispute!`). It records the gross excess and the movement IDs. The CPA note reports the same excess. It never touches organizer or buyer columns, and it is never charged to the organizer. Whether it blocks payouts is Q4. The working default is that it blocks like any open exception and can be resolved with a note, because no money movement can fix it.

---

## 4. Settlement and payout

### 4.1 Calculator

In `Settlements::Calculator`:

- `orders` excludes `never_fulfilled_at IS NOT NULL`. A never-fulfilled order enters today's scope only after a refund flips its status to `partially_refunded` or `refunded`, which is why a partial refund leaves an organizer payable (finding 1).
- Excluding the orders removes their sale lines, platform-fee lines, refund lines and processing lines, their lost disputes, and the order-level totals (`gross`, `discount`, `charged`, `refund_cents`, `net_cents`, `platform_fee_cents`, `organizer_proceeds_cents`). Delete the special cases #248 added (`never_fulfilled_platform_processing?` and the `lost_disputes` reject); exclusion replaces them.
- One informational item per never-fulfilled order of the event, whatever its status. Use `kind: "adjustment"`, so no `SettlementItem::KINDS` or UI change is needed:
  - `amount_cents: 0`, `source: Order`, `occurred_at: never_fulfilled_at`;
  - description: "Payment returned to the buyer; HåfaPass never fulfilled this order";
  - metadata: `{ order_id, adjustment_kind: "never_fulfilled_capture", captured_cents: C, returned_cents: A, owed_cents: O, excess_cents: X, refund_ids, dispute_ids, processing_bearer, platform_processing_cents }`, with all values taken from the ledger at calculation time.
- The `platform_processing_fee_cents` attribute still includes these orders' processing, so the statement's "processing covered by HåfaPass" total stays truthful. Read it from the excluded orders' `FeeComponent`s directly.

### 4.2 Processing bearer: one switch

`Commerce::NeverFulfilledCapture::ORGANIZER_BEARS_PROCESSING`, default **false**: HåfaPass bears it, pending Leon and the CPA (Q1). Every reader asks `organizer_bears_processing?`:

- **false:** the calculator puts the processing in `platform_processing_fee_cents` only. The CPA books it in `stripe_processing_costs_informational` only. `PlatformRevenue` counts it as a platform cost.
- **true:** the calculator adds a `processing_fee` item of −amount for each component (description "Card processing on a payment returned to the buyer"), and `processing_fee_cents` includes it. The CPA books it in `organizer_processing_deducted`. `PlatformRevenue` counts it as organizer-borne.

Stripe dispute fees on never-fulfilled captures follow the same switch (Q5).

`Commerce::PlatformRevenue` currently mirrors the calculator's split but includes refunded never-fulfilled orders through `SETTLED_STATUSES` and charges the organizer's share. It needs the same exclusion.

### 4.3 Digests and re-finalization

The source digest covers kind, amount, source and metadata, so it changes for every event that has a never-fulfilled order:

- the informational item is new;
- sale, refund, platform-fee and processing lines disappear (they appeared only after a refund);
- lost-dispute items disappear;
- the metadata changes as returns progress.

Events without one keep the same digest. Production has 0 events, so nothing needs re-finalizing today. For any environment with finalized statements, the operations docs instruct: after deploying, finalize the affected events again before paying. `PayoutCreator` already refuses a stale digest. Flipping the bearer switch has the same effect.

---

## 5. Exception resolution

All of these read `BuyerOwedLedger.for(order)` and recheck it under the existing org → event → order locks before moving money:

- **Still owed:** `late_capture_owed_cents` = max(*C* − succeeded refunds − pending refunds − lost disputes, 0). This replaces the refunds-only sum in `admin/reconciliation_exceptions_controller.rb` (around line 206), `RefundReconciliationActions`, `RefundReconciliationQueue` and `LateCaptureRefundJob`.
- **Refund submission never asks for money already returned:**
  - `Commerce::LateCaptureRefund.call` passes `amount_cents:` = owed, and refuses when owed is 0 or a dispute on *p* is open. The admin message: "The buyer disputed this payment. Wait for the outcome; a lost dispute returns the money."
  - `LateCaptureRefundJob` exits quietly in both cases.
  - When the dispute closes as won (or `warning_closed`), dispute finalization enqueues the job again so the remaining money is repaid.
  - The idempotency key stays `late-capture:payment:<id>` for the first automatic refund. A later top-up uses `late-capture:payment:<id>:<owed cents>:<sorted movement IDs>`, so a retry of the same decision cannot double-refund.
- **Provider facts are always recorded.** `ExternalRefundRecovery` and webhooks book an external refund even when the ledger says nothing is owed; the excess path (3.4) flags it.
- **Audited close.** The late-capture exception (and its companion codes) is resolved automatically when all of these hold:
  - *A* = *C*, meaning the buyer is fully repaid by any mix of refunds and lost disputes;
  - no pending or unknown refund on *p*;
  - no open dispute on *p*.

  This happens inside the transaction of the movement that completes repayment: `RefundCreator#resolve_repaid_late_capture!`, which today requires `payment.refunded?` and changes to this ledger condition, and a new identical call in `process_dispute!` when a dispute is lost. Both write `reconciliation_exception.resolved` with a note such as "Late capture repaid: refunds $X, lost disputes $Y". A manual resolve is allowed under the same conditions with a note (it currently returns 422, finding 4). A never-fulfilled capture that is still owed money can never be resolved with a note.
- **Finalizer** (`settlements/finalizer.rb:22`): no change to `open_money_blocker`. Open disputes and pending refunds still block. Once the ledger closes the exception, nothing else blocks.
- **Admin screen:** show captured, refunded, lost in disputes, pending, owed and excess from the ledger, and the disputed-wait reason, instead of the single owed number.

---

## 6. Readers and writers

| Component | Role | Change |
| --- | --- | --- |
| `Commerce::OrderLifecycle` | Writer: classification; P1, P3 and P4 | **Changes** (set the columns; provider-first expiry and cancel; grace on holds; `issue_tickets!` guard) |
| `OrderCreator`, `OnlineDoorSale` | Writers: hold and Session expiry | **Changes** (hold `expires_at` = deadline + grace; P5 if chosen) |
| `ExpireInventoryHoldsJob`, `ExpireDoorCheckoutSessionJob` | Writers | Small change (retry without releasing on an unknown provider result) |
| `EventLifecycle` (night cancel, unpublish) | Writer | **Changes** (P4) |
| `Order` model, migration, `data_retention.yml` | Schema | **New** columns, constraints, set-once guard |
| `Commerce::NeverFulfilledCapture` | Shared predicate | **Rewritten** over the columns; keeps the bearer switch |
| `Commerce::BuyerOwedLedger` | Shared ledger | **New** |
| `Commerce::RefundCreator` | Writer: refunds; auto-resolve | **Changes** (ledger-based repaid check, excess exception, recheck owed under lock) |
| `Commerce::LateCaptureRefund`, `LateCaptureRefundJob` | Writers | **Change** (amount = owed; wait on an open dispute) |
| `StripeWebhookProcessor#process_dispute!` | Writer: disputes | **Changes** (auto-resolve on loss, excess exception, re-enqueue refund on a win) |
| `Commerce::ExternalRefundRecovery` | Writer | No logic change (books provider facts; the excess path flags them). Spec added. |
| `RefundReconciliationQueue`, `RefundReconciliationActions` | Reader and actions | **Change** (owed from the ledger) |
| `Api::V1::Admin::ReconciliationExceptionsController` | Reader and actions | **Changes** (owed, blockers, resolution rule, JSON breakdown) |
| Admin exceptions screen (frontend) | Reader | Small change (breakdown and wait reason); strings per `docs/TRANSLATIONS.md` |
| `Settlements::Calculator` | Reader | **Changes** (exclude orders; informational item; switch) |
| `PayoutStatement` | Reader via the calculator | Probably no code change; check that "processing covered by HåfaPass" still comes from `platform_processing_fee_cents` |
| `OrganizationFinanceSummary`, `OrganizationPayoutBalance`, `PayoutSchedule`, `PayoutCreator`, `PayoutHoldRelease`, `EventSeriesReport`, `PilotCloseout`, `LiveMoneyProofReview`, organizer `FinancesController`, admin `PayoutsController` | Readers via the calculator | No code change; numbers and digests change as in section 4.3 |
| `Settlements::Finalizer`, `EventLifecycle#archive_blocker` | Readers | No change (unblocked by the auto-resolve) |
| `CpaMonthlyReport` | Reader | **Changes** (columns, ledger, `Payment.live_agent_capture`, bridge exclusion by column, recognition notes, gross excess note) |
| `TaxReports#bpt_event_rows` (BPT detail CSV) | Reader | **Changes** (shared capture scope; never-fulfilled fee refunds from the ledger allocation; lost-dispute fee share per Q2) |
| `Commerce::PlatformRevenue` | Reader | **Changes** (exclude never-fulfilled orders; processing per the switch) |
| `FinanceExports` (organizer CSV, `processing_by_order`) | Reader | Check: never-fulfilled orders should be labelled "Not fulfilled — returned to buyer" with $0 proceeds, or left out (Q8) |
| `BoxOfficeCardSalesController` status | Reader | Optional: show "returned" when the ledger has *A* = *C* |
| Monitoring (#220) | New reader | Add a weekly count of new never-fulfilled captures by code, and open excess exceptions |

---

## 7. Test matrix

Fixture unless stated otherwise: one $12.00 ticket plus a $1.60 HåfaPass fee, so *C* = 1360 and *T* = 1200. Processing is $0.69 and the bearer snapshot is `organizer`, so the never-fulfilled switch is what decides. Times are Guam (ChST). "Calc" means `Settlements::Calculator` attributes, and "Stmt" means `PayoutStatement`. Allocation values: ticket(470) = 415, ticket(500) = 442, ticket(1) = 1.

| # | Scenario | CPA (event row) | Calc / Stmt | Exceptions and admin |
| --- | --- | --- | --- | --- |
| F1 | Sol 1: capture Jan 10; external refund $5.00 Jan 12 (`ExternalRefundRecovery`) | Jan: captures 12.00, paid 4.42, closing owed 7.58; custody 0; fee refunds 0.58 | payable 0, organizer_proceeds 0, refund_cents 0; Stmt: no sale or refund line, one $0.00 info line (returned 500, owed 860) | Owed $8.60; **Refund buyer** refunds $8.60 → closing 0, exception auto-resolved |
| F2a | Sol 2a, two-price order (adult $8.00 + child $4.00, fees $1.07 + $0.53): refund $4.70 Jan 10; lost dispute $8.91 Feb 20 (beyond Stripe's normal rule; defensive) | Jan: paid 4.15, closing 7.85. Feb: paid 7.85, closing 0; note "$0.01 returned twice (gross)" | payable 0, adjustment 0 | Late capture auto-resolved Feb 20; `never_fulfilled_buyer_overpaid` $0.01 opened |
| F2b | Sol 2b: refund $0.01 Jan 10; lost dispute $13.59 Feb 20 | Jan: paid 0.01, closing 11.99. Feb: paid 11.99, closing 0; **no** flag | payable 0 | Auto-resolved; no overpaid exception |
| F3 | Sol 3: dispute lost recorded Feb 28 23:59:50; capture recorded Mar 1 00:00:10 | Feb: no row (capture not yet in scope). Mar: opening 0, captures 12.00, paid 12.00, closing 0; note on the Feb 28 loss | payable 0 | Exception auto-resolved at capture (ledger already repaid); job does nothing |
| F4 | Sol 4: capture Feb 10 10:00; dispute opened 10:02, before the job's refund; lost Feb 20 for $13.60 | Feb: paid 12.00, closing 0, chargebacks 0 | payable 0 | While open: Refund buyer hidden with the dispute reason; Finalizer blocked by the open dispute. After the loss: auto-resolved; manual resolve also allowed; Finalizer unblocked |
| F4b | F4, but the dispute is won on Feb 20 | Feb: paid 12.00 when the re-enqueued refund succeeds | payable 0 | Job re-enqueued on the win; refund $13.60; auto-resolved |
| F5 | Sol 5: legacy fulfilled order, `completed_at` null, issued ticket, hand-added backdated exception | proceeds 12.00, organizer processing 0.69, custody 11.31; buyer columns 0 | processing 69, payable 1131 | Backfill skips it ("has tickets"); no classification |
| R3-1 | Capture recorded Feb 28 23:59:59, exception stamped Mar 1 00:00:00; auto refund Mar 1 00:05 | Feb: captures 12.00, closing 12.00, informational processing 0.69, organizer processing 0, unchanged after the refund. Mar: opening 12.00, paid 12.00, closing 0 | payable 0, processing 0, platform processing 69 | Auto-resolved by the refund |
| R3-1b | Exception inserted by hand weeks after a capture on a pending→expired order, with no classification | Treated as fulfilled legacy (as in F5). It cannot arise from the lifecycle | as F5 | Backfill skips it (exception outside 60 s) |
| R3-2 | Organizer-bearer snapshot, auto refund; switch false / true | false: organizer processing 0, informational 0.69. true: `organizer_processing_deducted` 0.69, `closing_organizer_deficits` 0.69 | false: processing 0, platform processing 69, payable 0, Stmt covered 69. true: processing 69, negative balance 69 | — |
| R3-3a | Lost dispute $13.60 Feb 20, then a refund $13.60 Mar 2 anyway (external) | Feb: paid 12.00, closing 0. Mar: paid 0; note "$13.60 returned twice (gross)" | payable 0, negative 0 | `LateCaptureRefund` refuses (owed 0); the external refund is recorded; overpaid exception $13.60 |
| R3-3b | Refund $13.60 Feb 10, lost dispute $13.60 Mar 20 | Feb: paid 12.00. Mar: paid 0; excess $13.60 | payable 0 | Overpaid exception |
| G1 | Regression: normal fulfilled sale | proceeds 12.00, processing 0.69, custody 11.31 | processing 69, payable 1131 | — |
| G2 | Regression: fulfilled late capture (completed Mar 1 00:10) with a $5.00 refund Mar 5 | Mar: proceeds 12.00, refunded 5.00, processing 0.69, closing 6.31 | unpaid 631 | — |
| G3 | Regression: legacy completed order, `completed_at` null, no exception | proceeds 12.00, processing 0.69 | payable 1131 | — |
| G4 | Regression: ordinary lost dispute on a fulfilled sale, platform bearer | chargebacks 13.60, closing −1.60, deficits 1.60 | adjustment −1360, negative 160; Stmt −160 | — |
| G5 | Regression: Clover-linked: legacy Clover order with `completed_at` null ($12.00 bridge) plus a `sim_` Stripe payment row on the same event | Event stays in the report; bridge 12.00 (fixes deferred residual 5) | unchanged | — |
| G6 | Never-fulfilled capture and a fulfilled sale on the same event | Custody shows only the fulfilled sale; buyer columns only the never-fulfilled one | payable = fulfilled only + one info line | — |
| L1 | Classification set once: a duplicate success webhook, then the expiry job's own check | Columns unchanged; one exception, one job | — | — |
| L2 | Try to complete a never-fulfilled order or issue its tickets | DB check constraint / `issue_tickets!` raise | — | — |
| L3 | Pass order: all nights cancelled while paying (`pass_all_included_nights_cancelled`) | As F1 with no partial refund; pass event only | payable 0 on the pass event and every night event | — |
| L4 | Concurrency: refund success and dispute loss committing at the same time (two connections, latch) | Exactly one auto-resolve; excess computed once | — | No deadlock (org → event → order in both) |
| L5 | Concurrency: `LateCaptureRefundJob` racing a dispute-created webhook | Refund refused or not submitted once the dispute is recorded; Stripe's `refund_disputed_payment` handled as "wait" | — | — |
| P1a | Online expiry: Stripe cancel returns `canceled` | Order expired; no exception | — | — |
| P1b | Online expiry: cancel refused, intent `succeeded`, ticket type now "sold out" by count | Fulfilled (holds still counted during grace) | — | No late-capture exception |
| P1c | Online expiry: Stripe timeout | Order stays pending; retried next run; released after a confirmed cancel | — | — |
| P3a/b | Door expiry: Session `expired` → release; `complete` → hold until the signed webhook, then fulfill | — | — | — |
| P4 | Night cancelled with a pending pass checkout | Pending intent cancelled before release | — | — |

Every CPA scenario also asserts the roll-forward and continuity identities, closed-month byte stability after later movements, and that the calculator's unpaid balance matches the CPA bridge expression the current spec uses.

---

## 8. Implementation plan

**Recommended split: two PRs, accounting first.**

### PR A: classification, ledger, readers and resolution (rework #248)

1. Migrations: add the three columns, FK and partial index; add the check constraints `NOT VALID`; validate them in a second migration. Update `data_retention.yml`. Run `schema:load` → `migrate` → `schema:dump` on the task DB.
2. `Order` set-once guard; set the columns in `OrderLifecycle`; `issue_tickets!` guard; the backfill rake task (dry run by default).
3. `BuyerOwedLedger` with unit specs for the allocation properties (monotone, ticket(C) = T, excess on gross).
4. Rewrite `NeverFulfilledCapture` over the columns; add `Payment.live_agent_capture`.
5. CPA export, BPT export, calculator, `PlatformRevenue`.
6. Refund and dispute writers (auto-resolve, excess exception, owed amounts), `LateCaptureRefund` and its job, the admin controller and queue, the small admin UI change.
7. Docs: CPA guide, settlement operations, LOCKING (no new order; note the dispute → exception resolve step).
8. Specs: the whole section 7 matrix except P*, plus the concurrency specs L4 and L5 in the latch style of `payout_lock_order_spec.rb`.

Risk: medium. It touches money readers, but it mostly deletes inference code, and production has no rows. Estimate: 2–3 agent days plus two review rounds.

### PR B: prevention (P1–P4, optionally P5)

It touches the expiry and cancel paths that #232 (rush capacity) tuned, so it needs its own lock-order and concurrency review and a rush-load check. It is independent of PR A's schema.

Risk: medium-high (lifecycle and capacity). Estimate: 1.5–2 agent days plus review.

Both should land before sales open on Jan 4, 2027. If time runs short, PR A is the one that cannot slip: without it, real money is misreported. Without PR B, the path is only more frequent.

---

## 9. Open questions for Leon and the CPA

1. **Processing bearer.** Who bears Stripe processing on a capture HåfaPass never fulfilled? The working default is HåfaPass, because the organizer never had the sale. One switch, `ORGANIZER_BEARS_PROCESSING`.
2. **BPT treatment of a lost dispute on a never-fulfilled capture.** The working default treats the fee share of the lost dispute as a fee refund (`fee_refunds`), the same as a refund: the buyer got the whole payment back, so no fee was earned. Ordinary lost disputes on fulfilled sales do not reduce fee revenue today. Confirm both.
3. **Buyer-owed at ticket share or gross?** The CPA buyer columns carry the ticket share. The fee share runs through fee revenue and fee refunds. Should `*_buyer_refunds_owed` show the full gross the buyer is owed instead?
4. **Excess (paid back twice).** Should a `never_fulfilled_buyer_overpaid` exception hold the organizer's payouts until finance notes it, given the loss is HåfaPass's? Do we try to recover the excess from the buyer, and is there a threshold below which we just write it off?
5. **Stripe dispute fees** on never-fulfilled captures: under the same bearer switch?
6. **Door links near the end of admission** (P5): refuse door-card links in the last 30 minutes before admission ends, or accept the rare automatic refund?
7. **Grace length during the rush** (P2): 2 minutes online and 3 minutes door, so an abandoned cart holds inventory up to 12 minutes instead of 10. Acceptable for Copa?
8. **Organizer visibility.** Should organizer exports and finance screens list never-fulfilled orders as $0 "not fulfilled — returned to buyer" lines (the statement will show the info line), or leave them out?
9. **PR shape.** Rework #248 as PR A (keeps the review history), or close it and open fresh PRs A and B?
