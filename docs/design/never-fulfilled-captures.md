# Never-fulfilled captures: release decisions, classification, buyer-owed ledger and repayment

**Status:** design v2 for review (PR #248). Specification and rollout plan only; no application code in this change.
**Base:** `origin/main` `7bcd97c2` (#247, live in production) plus the #248 branch. v1 of this document is commit `846f808a`; the interim code it reviewed is `57de7f15`. Both stay in the branch history.
**Reviews this version answers:** the design review of `846f808a` (required changes 1–8 and its test-matrix additions), the code review of `57de7f15` (findings 1–5), and #247 rounds R1–R3, including the still-open **R2-2**. Section 0 maps each point to the section, code boundary and tests that close it.
**Decision owners:** every policy is one named switch or one documented rule (section 1). Each is marked **Default** (engineering ships it), **Leon** (Leon's decision; defaults in this brief applied) or **CPA** (needs the CPA's approval before the books are final). A default is never presented as CPA-approved.

## Summary

A never-fulfilled capture is a card payment that HåfaPass received for an order it did not fulfil, usually because the payment finished after the order's hold was released. No tickets are issued and the money belongs to the buyer. Four review rounds found reporting, payout and repayment bugs on this path. v1 fixed the inference habits. This version also specifies what v1 left implicit:

1. **When inventory may be released.** Release only on verified provider state for the exact payment, account and environment, or at an explicit, recorded hard cap (section 3).
2. **Who owns the classification.** A database-enforced, set-once, per-payment record written by the lifecycle, guarded at every ticket-issuing boundary (section 4).
3. **How returns are booked.** An append-only posting per returned-money movement, carrying its gross amount, the applied and excess parts, its allocation and one durable recognition time (section 5).
4. **How the buyer is repaid.** One locked workflow for every refund entry point, with owed, in flight and available tracked separately (section 6), and one evaluator that closes, reopens or escalates (section 7).
5. **How every finance reader treats it.** An exhaustive reader register enforced in CI, with custody, cost, holds and re-finalization rules (section 8).

PR A (sections 4–8) is required before Copa sales open on **Mon Jan 4, 2027** and ships as three ordered deploys, A1 → A2 → A3, so old application workers never meet an inconsistent finance or repayment state (section 10). PR B (section 3) follows: B1 is P1/P3 with the shared release policy, and B2 is the staged event transition P4 as a separate PR.

## Revision history

| Version | Commit | Change |
| --- | --- | --- |
| v1 | `846f808a` | Prevention P1–P5, `orders.never_fulfilled_*` columns, read-only gross ledger, settlement exclusion, ledger-based resolution. |
| v2 | this commit | Verified-state release decision and hard cap; per-payment classification table with DB triggers; append-only return postings; allocation policy with proof and the 75¢ counterexample; one repayment workflow; one evaluator; exhaustive reader register; R2-2 fix; A1/A2/A3 rollout with mixed-version and rollback evidence. v1's "≤1¢ difference" claim is withdrawn (section 5.5). |

---

## 0. Review closure matrix

| Review point | Closed in | Implementation boundary | Tests |
| --- | --- | --- | --- |
| **1** Release decision by verified provider state, exact identity, race | §3.1 | `Commerce::ProviderRelease` (new), `OrderLifecycle.expire!/cancel!`, `OnlineDoorSale.cancel!`, `StripeWebhookProcessor#process_door_session_expiry!`/`#process_door_success!` | P-01…P-12 |
| **2** Fair expiry/retry, hard cap, explicit unknown release, all capacity paths | §3.2 | `ExpireInventoryHoldsJob`, `ExpireSeatHoldsJob`, hold `expires_at` writers in `OrderCreator#create_ledger!` and `Seating::SessionLifecycle#claim!` | P-13…P-20, X-01, X-02 |
| **3** Staged P4 gate, outside-lock drain, final locked revalidation, covered mutations | §3.3 | `EventLifecycle`, `events.transition_gate_*` (new), checkout gate checks in `OrderCreator`/`OnlineDoorSale`/`CashSaleCreator` | P-21…P-27, X-03, X-04 |
| **4** DB ownership, set-once, issuance guards, second captures, provenance/recheck/quarantine, writers-first | §4, §10 | `never_fulfilled_captures` (new), `orders.never_fulfilled_at`, `lib/financial_integrity.rb` (new, schema-dump hook), `OrderLifecycle#complete_with_audit!`, `Passes::Issuance`, `never_fulfilled:reconcile` | C-01…C-14, M-01…M-04 |
| **5** Durable gross postings, allocation, `max(return, capture)` before every CPA/BPT bucket, proof, 75¢, late wins | §5 | `buyer_return_postings` (new), `Commerce::BuyerReturnPosting`, `Commerce::BoundedAllocator`, `CpaMonthlyReport`, `TaxReports` | L-01…L-16 |
| **6** One locked repayment workflow, owed/in flight/available, attempt identities, dispute waits | §6 | `Commerce::BuyerRepayment` (new) inside `RefundCreator#reserve_refund!` and `#provider_submission_allowed?(mark_unknown: true)` | R-01…R-12, X-05, X-06 |
| **7** One evaluator, refund/dispute before binding, recovery, excess dedupe | §7 | `Commerce::NeverFulfilledResolution` (new), `Commerce::ProviderEvidenceReplay` (new), `ExternalRefundRecovery.ingest!` | E-01…E-10, X-07 |
| **8** Exhaustive finance readers, custody, cost, holds, re-finalization | §8 | Reader register `config/never_fulfilled_readers.yml` (new, CI-enforced) and every reader listed there | F-01…F-18 |
| **R2-2** Historical BPT payout eligibility | §8.6 | `TaxReports#paid_payouts`/`#bpt_event_rows` | F-12, F-13 |
| Code review `57de7f15` findings 1–5 | §9.1 examples E1–E7 | as above | L-*, R-*, F-* |
| Test-matrix additions from the design review | §9 | — | all |

---

## 1. Policy register

Each row is the only place the rule lives. Code reads the switch; for the bearer and allocation switches, the value is **snapshotted onto the `never_fulfilled_captures` row** at classification, so a later change is prospective. Restating an earlier capture needs a data migration with finance approval and re-finalization (§8.8).

| # | Policy | Switch or rule | Value shipped | Status |
| --- | --- | --- | --- | --- |
| P1 | Processing on a never-fulfilled capture | `Commerce::NeverFulfilledCapture::ORGANIZER_BEARS_PROCESSING` (existing name), snapshotted as `never_fulfilled_captures.processing_bearer` | `false`: HåfaPass bears it | **Leon default; CPA** confirms the accounting treatment |
| P2 | BPT treatment of the fee and tax share of a **lost dispute** on a never-fulfilled capture | `Commerce::NeverFulfilledCapture::LOST_DISPUTE_FEE_SHARE` | `:fee_refund`: the fee/tax share reverses through `fee_refunds` in the posting's recognition month, as for a refund (v1 default). Ordinary lost disputes on fulfilled sales keep today's rule (no fee reversal) | **Default; CPA** must approve both halves |
| P3 | Buyer liability presentation in the CPA CSV | `CpaMonthlyReport::BUYER_LIABILITY_PRESENTATION` | `:gross_with_ticket_bridge`: existing ticket-share columns stay; new gross columns plus a stated bridge (§8.5) | **Leon default; CPA** chooses journal presentation |
| P4 | Buyer repaid twice (excess) | `Commerce::NeverFulfilledCapture::OVERPAID_HOLDS_PAYOUTS` | `false`: open a deduplicated `never_fulfilled_buyer_overpaid` exception, alert and audit; organizer payouts are not held once the capture is proven platform-only. No automatic recovery and no write-off threshold; finance resolves with a note | **Leon default**; recovery and write-off policy **pending Leon/CPA** |
| P5 | Actual Stripe dispute fees on these captures | `Commerce::NeverFulfilledCapture::DISPUTE_FEE_BEARER`, snapshotted | `:platform` | **Leon default; CPA** confirms |
| P6 | Door-card link cutoff before admission ends | `Commerce::OnlineDoorSale::LINK_CUTOFF_BEFORE_ADMISSION_END` | `35.minutes`, equal to `OrderCreator::ONLINE_DOOR_HOLD_DURATION` (the Session lifetime) | **Leon default** |
| P7 | Provider-release grace (= hard cap) after the buyer deadline | `Commerce::ProviderRelease::ONLINE_GRACE`, `DOOR_GRACE` | `2.minutes` online, `3.minutes` door | **Leon default, trial values**; tuned from the rush measurement in §10.4, not a delivery guarantee |
| P8 | Organizer visibility | Documented rule | One `$0.00` statement line, **"Payment received, order unfulfilled"**, plus a live return status (§8.3). Sales totals, sales CSVs and analytics omit these orders | **Leon default** |
| P9 | Allocation of returned money between ticket proceeds, fees and tax | `Commerce::BuyerOwedLedger::ALLOCATION_POLICY`, snapshotted | `:item_record` (§5.4); alternative `:cumulative_pro_rata`. They differ by **$0.75** on the §5.5 counterexample | **Default; CPA approval required** before the January 2027 close |
| P10 | Organizer payout and finalization holds for classified captures | `Commerce::NeverFulfilledCapture::PAYOUT_HOLD` | `:unknowns_only` (§8.7): hold only while classification is missing or quarantined, or a provider outcome is unknown; `:strict` restores today's "any open exception blocks" | **Engineering recommendation** (extends Leon's P4 principle); **Leon** confirms |
| P11 | Return recognition time | Documented rule (§5.3) | `max(return recorded, capture recorded, start of the Guam month in which it was posted)` for never-fulfilled postings; `max(return recorded, order custody booked)` for every other CPA/BPT return bucket | **Default; CPA** review |
| P12 | BPT payout eligibility (R2-2) | Documented rule (§8.6) | As-of qualifying-capture evidence at the payout's paid recording time | **Default; CPA** review |

---

## 2. Terms

- **Capture recorded time** (*t₀*): `payments.succeeded_at` as written by `OrderLifecycle#mark_payment_succeeded!` in the transaction that records the capture. Section 4 makes it set-once.
- **Classified payment**: a payment with a `never_fulfilled_captures` row. **Classified order**: an order whose `never_fulfilled_at` is set (every capture on it is unfulfilled).
- **Movement**: a provider fact that returns money to the buyer (a succeeded refund, a lost dispute) or reverses one (a late dispute win, a finance-confirmed refund failure after success).
- **Verified provider state**: a Stripe object retrieved or returned over the authenticated API, or delivered in a signed webhook, whose ID, `livemode`, account and amount match the local payment. Anything else is **unknown**.

---

## 3. Prevention: release decisions (PR B)

### 3.1 Release decision by verified provider state

Both checkout flows are card-only with automatic capture: `StripeService.create_payment_intent` sets `allowed_payment_method_types: ["card"]` and `create_door_checkout_session` sets `payment_method_types: ["card"]`; neither sets `capture_method`. **Keep both constraints for this rollout.** `card_only_intent?` already records a policy mismatch. Any state that only async or manual-capture methods produce is handled as unexpected below. It is never treated as closed.

`Commerce::ProviderRelease.decide(order)` runs **outside every transaction**. It returns a value object, `Decision(kind:, payment_id:, provider_object_id:, environment:, account_id:, evidence:)`, with `kind` ∈ `closed_verified`, `paid_verified`, `paid_awaiting_signed_event`, `unknown`.

**Online PaymentIntent**

| Provider state observed | Evidence required | Decision | Action |
| --- | --- | --- | --- |
| Cancel returns `canceled` | `intent.id == payment.provider_payment_id`, `livemode` matches `provider_environment`, account matches `provider_account_id` | `closed_verified` | Locked release (below). Stripe: a cancelled PaymentIntent makes no further charges ([Cancel](https://docs.stripe.com/api/payment_intents/cancel)) |
| Cancel refused; retrieve shows `succeeded` | As above, plus `amount_received == payment.amount_cents` and currency | `paid_verified` | `OrderLifecycle.complete!(late_completion: true)` from outside any transaction (§3.3, "ordinary completion") |
| `requires_payment_method`, `requires_confirmation`, `requires_action` | Same identity | Cancel is permitted in these states; repeat the cancel | `closed_verified` only after a `canceled` response. A 3DS confirmation racing the cancel resolves as one of the two rows above |
| `requires_capture` | Same identity | Unexpected (automatic capture). Cancel voids the authorization | `closed_verified` on `canceled`. Record `provider_unexpected_state` either way |
| `processing` | Same identity | Unexpected for cards; Stripe only sometimes permits cancel here | `closed_verified` only on `canceled`; otherwise `unknown` |
| Timeout, network error, 5xx, rate limit | — | `unknown` | Retry (§3.2) |
| No `provider_payment_id` and **no** `setup_attempted_at` | The committed setup mark (`OrderCreator#create_provider_payment!` writes it before any POST) | `closed_verified` | No Stripe request was ever sent, so nothing can charge |
| No `provider_payment_id`, `setup_attempted_at` present (lease live or expired) | — | `unknown` | Replay the create with the payment's original idempotency key while `payment.created_at` is within `RefundCreator::PROVIDER_REPLAY_WINDOW` (23 h): bind the returned intent under order → payment locks, then cancel it. An expired local lease never proves closure |
| Identity mismatch (ID, mode, account, amount) | — | `unknown`, plus `payment_context_mismatch` | Never release as verified |

**Door Checkout Session**

| Provider state observed | Evidence required | Decision | Action |
| --- | --- | --- | --- |
| Expire returns `expired`, or the signed `checkout.session.expired` webhook | `session.id == payment.stripe_checkout_session_id` (or bound by `door_metadata_matches?`), `livemode` and account match | `closed_verified` | Locked release. Stripe: an expired Session cannot be completed ([Expire](https://docs.stripe.com/api/checkout/sessions/expire)) |
| `complete` and `payment_status == "paid"` | Same identity and `amount_total` | `paid_awaiting_signed_event` | Keep the hold (§3.2, "door paid wait"). Only the signed `payment_intent.succeeded` webhook, or an API-retrieved `Event` of that type for the same intent, may fulfil (`OnlineDoorSale.provider_paid?` stays warning-only) |
| `complete` with `payment_status` `unpaid` or `no_payment_required` | — | Unexpected (card-only); a complete Session can be unsettled ([Session object](https://docs.stripe.com/api/checkout/sessions/object)) | `unknown`; alert |
| `open` after an expire call | — | `unknown` | Retry |
| No Session ID saved, `door_checkout_setup_attempted_at` present | — | `unknown` | Wait for the signed expired webhook, which binds by metadata (`process_door_session_expiry!` already handles a missing ID), or replay the create with its key |
| No Session ID, no setup mark | — | `closed_verified` | — |

**Locked release.** `OrderLifecycle.release_verified!(order, decision)` takes the existing lifecycle prefix (`lock_event_context!` → order → payment and holds → offer → inventory). It then rechecks four things: the order is still `pending`, `decision.payment_id` is still the order's pending payment, the payment's provider object ID equals `decision.provider_object_id` (a Session or intent created during the probe changes it), and the payment's environment and account are unchanged. Any mismatch discards the decision and re-probes. Release then marks the payment `cancelled` with `provider_payload.release_evidence` (kind, object ID, observed at). Today `expire!`/`cancel!` mark pending payments `cancelled` *before* the provider call (`order_lifecycle.rb:224`, `:255`). In v2, local `cancelled` always means verified closed.

**Two "expired" sources stay separate.** `expire!(…, provider_expired: true)` today has two callers with different evidence: the signed Session-expired webhook (`stripe_webhook_processor.rb:219`, and `OnlineDoorSale#open_session!` when Stripe returns `expired`), and the door-success path on an unpublished event (`stripe_webhook_processor.rb:243`). In the second case Stripe reported a **successful payment**. B1 replaces the boolean with `release_verified!(order, decision)` for the first source. The second becomes an eligibility release inside the completion transaction (§3.3), recorded as a never-fulfilled capture with `details.reason = "event_not_published"`. It is never logged as a provider expiry.

**Race outcomes.** Cancel or expire versus 3DS or checkout completion has two outcomes, both safe. If the cancel wins, Stripe refuses the confirmation. If the payment wins, the cancel is refused, the retrieve shows `succeeded`, and the order completes under locks. The hold is still counted during grace, so it fulfils. Duplicate or delayed signed events find the order completed, or released with a classification, and change nothing (§4.3, C-05).

### 3.2 Expiry, retry, grace and the hard cap

**Constraint from production.** Deployed job concurrency is **one** (`docs/RENDER_DEPLOYMENT_CONTRACT.md`: "Solid Queue … one job thread"; `config/queue.yml` `threads: 1`). Today `ExpireInventoryHoldsJob` expires orders serially in ID order with a 45 s budget. A 5 s timeout per order caps a run at nine orders, so a surge can use up the grace before an order gets its first attempt.

**Design (B1).**

1. **Hold lifetime = deadline + grace.** `OrderCreator#create_ledger!` writes `inventory_holds.expires_at` and `catalog_item_holds.expires_at` as `orders.expires_at + grace`. `Seating::SessionLifecycle#claim!` writes the claimed `seat_hold_sessions.expires_at` the same way (today it copies `order.expires_at`). The buyer deadline (`orders.expires_at`, checkout countdown, Session `expires_at`) is unchanged. Grace is also the **hard cap**: one setting per flow (P7).
2. **Release state on the order** (B1 migration, financial 7-year retention): `provider_release_state` (`none`, `probing`, `closed_verified`, `paid_awaiting_signed_event`, `released_unknown`), `provider_release_attempts`, `provider_release_next_at`, `provider_release_last_error`.
3. **Fair scheduling.** Each run selects due pending orders by `ORDER BY provider_release_attempts ASC, orders.expires_at ASC` (no order gets a second try while one still waits for its first; earliest deadline first). It probes them in **bounded parallel HTTP**: up to `PROBE_CONCURRENCY = 4` threads, each receiving plain values (intent or Session ID, account, environment, idempotency key, resolved client options) and **no ActiveRecord access**. Today `StripeService` reads `SiteSetting.instance`, so options are resolved before fan-out. Locked releases then run serially on the job's own connection. Backoff after `unknown`: 0 s, 15 s, 30 s, then every 30 s until the cap.
4. **At the cap, with the decision still `unknown`:** `release_unknown!` takes the lifecycle locks. It releases inventory with `release_reason: "provider_unknown_at_cap"` and keeps the payment `pending` with `provider_release_state = released_unknown`. It opens `inventory_released_provider_unknown` (an alert, not a refund code) and records `order.released_provider_unknown`. A reconciler retries the cancel or expire every 5 minutes for 24 hours. On `closed_verified` it marks the payment cancelled and resolves the exception with an audit entry. On capture, the normal late-capture path classifies it (§4). After 24 hours it escalates to finance.
5. **Door paid wait.** On `paid_awaiting_signed_event`, the job extends the order's holds once, under locks, by `DOOR_PAID_WEBHOOK_WAIT = 10.minutes` and audits the extension; the buyer has paid. If no signed event is processed by then, `ProviderEvidenceReplay` lists the intent's `payment_intent.succeeded` events through the API and processes the match through the same `process_door_success!` path. If that also fails, it alerts staff ("Paid at Stripe, not yet confirmed here").
6. **Implicit lapse.** If the job itself stalls, `InventoryHold.current` stops counting at `expires_at`. That is safe from overselling, because every late completion rechecks capacity under locks (`late_capacity_available?`), but it is unrecorded. Monitoring alerts when an `active` hold is more than 2 minutes past `expires_at` (job stalled).

**Every capacity path, and how it agrees.** All of them use the same hold `expires_at`, so writing deadline + grace there makes them agree.

| Path | Code | Counts a hold while | v2 change |
| --- | --- | --- | --- |
| Ticket type availability | `TicketType#available_quantity` → `active_holds_quantity` → `InventoryHold.current` | `active` and `expires_at > now` | none (expiry value changes) |
| Door allotment | `TicketType#door_held_quantity` | same, `source = box_office` | none |
| Pricing tiers | `late_capacity_available?` tier sum, `PricingTier` seat count | `inventory_holds.current`, seat sessions `expires_at > now` | seat session expiry written with grace |
| Event and pass-night capacity | `EventCapacity.direct_holds`, `pass_holds_targeting` | `expires_at > at` | none |
| Catalog stock | `CatalogItem` → `CatalogItemHold.current` | same | catalog hold expiry written with grace |
| Claimed seats | `SeatHoldSession#…expires_at > at`; `ExpireSeatHoldsJob` | same | `ExpireSeatHoldsJob` stops calling `OrderLifecycle.expire!` directly for claimed sessions; it defers to the order's release decision |
| Waitlist offers | `WaitlistOffer.holding_inventory` (offered only) | `expires_at > at` | none: a claimed offer is held by the order's holds and released through the lifecycle's rank-4 locks |
| Admission close | `OrderLifecycle#door_admission_ended?` | — | unchanged; also gated by P6 at link creation |

### 3.3 Event transitions (B2, separate PR)

**Covered mutations.** `EventLifecycle::TRANSITIONS` has no "unpublish" action. The only transitions out of `published` are `postpone`, `cancel` and `complete`. P4 covers `cancel` (single events and pass nights; a night is cancelled as its own event) and `postpone`. `complete` needs no gate: it only runs after the event ends (`CompletePastEventsJob`, 6 h after the end), when door admission has ended and online sales are closed. Organizer and platform sales suspensions (`organizer_sales_suspended_at`, `sales_suspended_at`) stop new checkouts but do not release orders, so payments already in progress may still complete.

**Staged transition.**

1. **Gate (committed).** A short transaction under organization (`FOR NO KEY UPDATE`) → event sets `events.transition_gate_action`, `transition_gate_token` and `transition_gate_at`, with audit `event.transition_gated`. `OrderCreator`, `OnlineDoorSale` (`reserve!` and `claim_setup!`) and `CashSaleCreator` already hold the event lock (or all involved events) and refuse new orders or new Session setup while any involved event is gated. A pass checkout touching a gated night is refused.
2. **Drain (outside locks).** List the affected pending orders: orders on the event, and pass orders whose included nights would *all* be ineligible after the change. **Pass orders that still have an eligible sibling night are not drained.** Their completion issues children only for eligible nights (`Passes::Issuance#resolve_included_events`). Run `ProviderRelease.decide` on each. `closed_verified` orders release. `paid_verified` orders complete through the ordinary path, where the eligibility recheck below records them as never-fulfilled. `unknown` orders keep the transition waiting: staff see "2 payments are still confirming with Stripe" and can retry. After `TRANSITION_DRAIN_WAIT = 2.minutes`, an admin may choose **Proceed anyway**, which calls `release_unknown!` for those orders (explicit and audited).
3. **Final transition under the documented locks.** `EventLifecycle` takes organization → event (and linked pass orders → child tickets as today). It rechecks the gate token, rechecks that no affected order is still `pending` without a recorded `released_unknown`, recomputes `EventCancellationRefunds.preview` against the staff-confirmed count and total (existing), commits, and clears the gate. Abandoning clears the gate with an audit entry. B2 also changes `EventLifecycle`'s organization lock from `with_lock` (`FOR UPDATE`) to `FOR NO KEY UPDATE`, removing the EVENT → audit-FK `KEY SHARE` cycle listed in STATUS.md's lock-order follow-up (LOCKING rank 1 already prescribes this mode for other money writers).

**Ordinary completion and eligibility (B1).** Every success path calls `OrderLifecycle.complete!` from outside any transaction, so it acquires the full event context itself, including the claimed-offer organization prefix (`lock_event_context!`). The one exception, `process_door_success!`, already owns the context and passes `event_context_locked: true`. Under those locks `complete_with_audit!` separates:

- **still-owned holds** (`active`, `expires_at > now`): fulfil if the event is eligible;
- **lapsed holds**: today's `late_capacity_available?` check;
- **event eligibility**, checked in both cases: the order's event is `published`, has no transition gate, and for passes still has an eligible night; door orders also need admission to be open. **Ineligible → release and classify as never-fulfilled in the same transaction.** No tickets, no confirmation email and no fulfil-then-refund. Today a still-owned hold on a cancelled or postponed event fulfils (`order_lifecycle.rb:126` checks only `lapsed`).

Recommendation (beyond the given defaults): treat `postponed` as ineligible. The buyer started checkout for the original date, and a refund avoids issuing a ticket whose date changed mid-payment.

### 3.4 Door link cutoff (P6)

`OnlineDoorSale.call` refuses to open a door-card link when `admission end − now < LINK_CUTOFF_BEFORE_ADMISSION_END` (35 min), with the message "Take card-present or cash for the last 35 minutes of admission." This mirrors the existing guard in `claim_setup!` (`expires_at < 31.minutes.from_now`). The cutoff equals the Session lifetime, so no link can outlive admission.

### 3.5 Not in scope

Manual capture (authorize, then capture under HåfaPass locks) strengthens the invariant, but it needs a durable authorization → capture-pending → completion flow, handling for authorization expiry and unknown capture results, and its own webhook reconciliation. **Not for Copa.** Revisit after launch if the monitored frequency (§8.9) justifies it ([Place a hold](https://docs.stripe.com/payments/place-a-hold-on-a-payment-method)).

---

## 4. Durable classification (PR A1)

### 4.1 Schema

**`never_fulfilled_captures`**: one row per unfulfilled captured payment. Append-only, no PII, financial 7-year retention in `config/data_retention.yml`.

| Column | Type | Rule |
| --- | --- | --- |
| `order_id`, `payment_id` | bigint, NOT NULL | Composite FK `(payment_id, order_id)` → `payments(id, order_id)`, backed by a new unique index on `payments(id, order_id)` (built concurrently). A payment from another order is rejected by the database |
| `payment_id` | | UNIQUE: one classification per payment, never overwritten |
| `scope` | string | `order` (no capture on the order was fulfilled) or `payment` (a distinct second capture on an order fulfilled by another payment) |
| `code` | string | One of `LateCaptureRefund::CODES`, plus `unfulfilled_second_capture` and `event_not_eligible` (§3.3) |
| `captured_cents`, `currency` | | Equal to `payments.amount_cents` and currency (CHECK through the trigger) |
| `proceeds_cents`, `fee_cents`, `organizer_fee_cents`, `tax_cents` | integer | Component snapshot (`order`-scope rows: Σ of order items' `organizer_proceeds_cents`, `fee_cents`, `organizer_fee_cents`, `tax_cents`); CHECK sum = `captured_cents` |
| `capture_recorded_at` | timestamptz | *t₀* |
| `processing_bearer`, `dispute_fee_bearer`, `allocation_policy`, `policy_version` | string | Snapshots of P1, P5 and P9 |
| `provenance` | string | `lifecycle` or `backfill` |
| `provenance_evidence` | jsonb | Exception ID, webhook event ID, audit IDs; for backfill, the evidence list in §4.5 |
| `created_at` | timestamptz | DB default `clock_timestamp()` |

**`orders`**: `never_fulfilled_at` (first `order`-scope classification time) and `fulfilled_by_payment_id` (FK, set once in the completion transaction: the payment that fulfilled the order).

**`payments.succeeded_at`**: made set-once by trigger (it is already written only once, by `mark_payment_succeeded!`).

### 4.2 Database enforcement

`schema.rb` *can* carry triggers here: `config/initializers/audit_log_schema_dump.rb` prepends `AuditLogIntegrity::SchemaDump`, which appends executable DDL to the dump, and `spec/models/audit_log_integrity_spec.rb` proves bypasses fail. v1 said a trigger was impossible; that was wrong. A1 adds `lib/financial_integrity.rb` on the same pattern (its own `SchemaDump` module and the same `pg_trigger` existence check), so `db:schema:load`/`test:prepare` restore every trigger, and #235's schema round-trip CI step fails on drift.

| Guard | Mechanism | Rejects |
| --- | --- | --- |
| Set-once order marker | BEFORE UPDATE trigger on `orders` | Any change to `never_fulfilled_at` or `fulfilled_by_payment_id` once set; setting `never_fulfilled_at` with no `order`-scope capture row for that order |
| Never completed | CHECK `never_fulfilled_at IS NULL OR (completed_at IS NULL AND status NOT IN (pending, completed))` (`NOT VALID`, validated in a second migration) | Completing a classified order, or leaving it pending |
| Append-only classification | BEFORE UPDATE OR DELETE trigger on `never_fulfilled_captures`; TRUNCATE trigger with the synthetic-purge opt-in used by audit logs | Clearing, editing or deleting a classification |
| Ownership | Composite FK plus a BEFORE INSERT trigger | Wrong order, amount ≠ payment amount, non-captured payment status |
| Ticket issuance | BEFORE INSERT OR UPDATE OF `order_id`, `status` trigger on `tickets` | Any non-`cancelled` ticket on a classified order. This covers `OrderLifecycle#issue_tickets!` (`order_lifecycle.rb:442`, `:458`), `Passes::Issuance` child creation (`passes/issuance.rb:29`), and any future staff insert or `update_all` |
| Capture time | BEFORE UPDATE trigger on `payments` | Changing a non-null `succeeded_at` |

Model callbacks stay as fast feedback, but **these triggers are the guarantee**: `update_columns`, `update_all` and raw SQL all fail (C-02).

### 4.3 Writers and issuance boundaries

`Commerce::NeverFulfilledCapture.classify!(order:, payment:, code:, provenance:)` runs only inside a transaction that already holds the lifecycle locks (event context → order → payment). It inserts the capture row and, for `order` scope, sets `orders.never_fulfilled_at`. It then posts every movement already recorded on the payment (§5.2) and calls the evaluator (§7). Callers:

| Boundary | Code today | v2 |
| --- | --- | --- |
| Capture after the order left `pending` | `order_lifecycle.rb:70–86` | `classify!(code: late_payment_success_after_inventory_release)` replaces the bare exception; the exception is still written (admin queue) |
| All pass nights cancelled | `order_lifecycle.rb:106–120` | `classify!(code: pass_all_included_nights_cancelled)` |
| Unusable, lapsed without capacity, admission ended | `order_lifecycle.rb:126–141` | `classify!(code: late_payment_success_after_hold_expiry)` |
| Event not eligible with owned holds (§3.3) | new | `classify!(code: event_not_eligible)` |
| **Distinct second capture** on a completed, partially refunded or refunded order | `order_lifecycle.rb:63–66` silently calls `mark_payment_succeeded!` | When `payment.id != order.fulfilled_by_payment_id` (legacy null: the earliest captured payment), `classify!(scope: payment, code: unfulfilled_second_capture)`. The order marker stays unset, and the order stays fulfilled by its first payment |
| Distinct second capture on an already-classified order | the same branch | A second `order`-scope row for the new payment; `never_fulfilled_at` keeps the first time. Readers exclude per payment, so the second capture is never hidden by the first marker |
| Duplicate notice for the same payment | — | The unique `payment_id` makes it a no-op; `classify!` returns the existing row |
| Rebooking | — | A buyer who still wants tickets buys a **new order**. A classified order is never converted |

`reopen_expired` (`order_lifecycle.rb:68`) switches from "no late-capture exception exists" to "the payment is not classified", the same evidence moved to the owned table.

### 4.4 Readers

`Commerce::NeverFulfilledCapture` becomes a thin reader. `order_sql` becomes `orders.never_fulfilled_at IS NOT NULL`, and `payment_sql` becomes `EXISTS (… never_fulfilled_captures WHERE payment_id = payments.id)`. A3 removes `EVIDENCE_WINDOW_SECONDS` and the exception join. Provider qualification stays per reader through one shared scope, `Payment.live_agent_capture`, which replaces CPA's `LIVE_AGENT_CAPTURE_SQL` and `TaxReports#bpt_event_rows`'s inline filter (the minor finding). This also closes deferred Clover residual 5.

### 4.5 Existing rows: positive provenance, recheck, quarantine

`never_fulfilled:reconcile` (rake task plus a temporary recurring job in A1, removed in A3) is idempotent and `DRY_RUN=1` by default. It classifies **only** with positive lifecycle provenance. A candidate needs **all** of:

1. A captured Stripe payment whose `amount_cents == orders.total_cents` and currency matches.
2. A `LateCaptureRefund::CODES` exception linked to that payment and order, created at or after `payments.succeeded_at` and within 5 seconds of it. A matching exception within a time window is **not enough on its own**; points 3–5 are also required.
3. An `order.expired` or `order.cancelled` audit (or, for `pass_all_included_nights_cancelled`, the release audit with that reason) whose `created_at` is not after the exception.
4. No tickets other than `cancelled`, no `order.completed` audit, no consumed inventory, catalog or seat holds, no `promo_redemptions` in `finalized`, and no `promoter_commission_entries` of kind `earned`.
5. Either a refund with key `late-capture:payment:<id>` (the lifecycle enqueued the job), or the exception's `webhook_event_id` pointing at a `payment_intent.succeeded` receipt for this payment.

The task re-reads each candidate under the lifecycle locks and classifies with `provenance: backfill` and the evidence IDs. Anything that fails a test, or has refunds, disputes or adjustments linked to it, gets an open **`never_fulfilled_backfill_ambiguous`** exception instead. That exception blocks the organization's payouts under every `PAYOUT_HOLD` setting. Finance decides each one with an audited action: classify with a note, or "fulfilled, not a never-fulfilled capture". A classification that would restate a **finalized settlement or a closed CPA month** requires finance review before it is written: the task lists those separately and writes them only with `CONFIRM_RESTATEMENT=<ids>`.

---

## 5. Gross movements, posting and allocation (PR A1 writes, A2 reads)

### 5.1 Why postings instead of a read-only projection

v1 computed the ledger on the fly from refunds and disputes. That leaves the period of a return open to anything that changes those rows later: a late audit row, a backfill, a status flip, a provider correction. A posting freezes, at the time the movement is recorded, everything a reader needs: the gross amount, the part that repaid the debt, the excess, the allocation and the recognition time.

### 5.2 `buyer_return_postings`

Append-only (triggered like §4.2), no PII, financial retention.

| Column | Meaning |
| --- | --- |
| `never_fulfilled_capture_id` | Classified payment |
| `kind` | `refund`, `dispute_loss`, `dispute_loss_reversal` (late win), `refund_reversal` (finance-confirmed failure after success) |
| `source_type`, `source_id` | `Refund` or `Dispute`; UNIQUE (`kind`, `source_type`, `source_id`), so one provider movement posts once |
| `gross_cents` | Signed gross movement (`refunds.amount_cents`, `disputes.amount_cents`; negative for reversals) |
| `applied_cents`, `excess_cents` | `applied + excess = gross`, computed under the order lock against the previous postings |
| `proceeds_cents`, `fee_cents`, `organizer_fee_cents`, `tax_cents` | Allocation of `applied_cents` (§5.4); sum = `applied_cents` |
| `recorded_at` | The movement's own durable time: `refunds.succeeded_at` (set once in `RefundCreator#finalize_observed_refund!`); the dispute loss time (first `dispute.lost` audit, which is also when `closed_at` is set); the reversal's audit time |
| `posted_at` | DB `clock_timestamp()` |
| `recognized_at` | §5.3 |
| `note` | For example "Lost dispute recorded 28 Feb 2027, before its capture was recorded; recognized 1 Mar 2027" |

**Writers** (all under organization → event → order, the existing refund and dispute prefix): `RefundCreator#finalize_observed_refund!` on `succeeded` (`refund_creator.rb:563`); `StripeWebhookProcessor#process_dispute!` on `lost`; the new late-win branch (§5.6); `classify!` for movements recorded before classification; and `never_fulfilled:reconcile` for movements recorded by an older worker during a deploy overlap.

**Order.** Postings for one capture are ordered by `(recognized_at, id)`. They are inserted under the order lock, so `id` order equals evaluation order.

### 5.3 Recognition time, everywhere

For a never-fulfilled posting:

```
recognized_at = GREATEST(recorded_at, capture_recorded_at, guam_month_start(posted_at))
```

- `capture_recorded_at` stops a return being recognized before its capture (code-review finding 3; the design review's "pre-capture returns under both delivery orders").
- `guam_month_start(posted_at)` stops a late posting moving into a month already closed. A backfill, a replay after binding, or a provider correction lands in the month it is posted, and the note keeps the original date. In normal operation `posted_at` falls in the same transaction as `recorded_at`, so this term does nothing.

**Before every CPA and BPT bucket.** The same rule, using the reader's own custody booking time, applies to every return-like bucket. A month can therefore never show a return before the capture it reverses:

| Reader | Bucket | Recognition |
| --- | --- | --- |
| `CpaMonthlyReport` | `buyer_refunds_paid`, gross buyer columns, `fee_refunds` (classified) | `buyer_return_postings.recognized_at` |
| | `proceeds_refunded`, `fee_refunds` (fulfilled) | `GREATEST(COALESCE(refunds.succeeded_at, refunds.created_at), order_custodial_at)` where `order_custodial_at` is the existing `ORDER_CUSTODIAL_AT_SQL` |
| | `chargebacks` | `GREATEST(DISPUTE_LOST_AT_SQL, order_custodial_at)` |
| | `organizer_processing_deducted`, `stripe_processing_costs_informational` | `GREATEST(fee_components.created_at, order_custodial_at or capture_recorded_at)` |
| | `non_custodial_settlement_bridge` refunds, processing, disputes | `GREATEST(movement time, the bridge order's booking time)` |
| `TaxReports#bpt_event_rows` | `returned_fees` | as CPA `fee_refunds` (shared SQL helper `Commerce::RecognitionTime`) |
| `TaxReports#months`, `#organizers` | `fees_refunded_cents`, refunds | same helper |

For fulfilled orders this only changes rows where a return was recorded before its order's custody booking. The known case is a legacy capture backfilled by `StripeWebhookProcessor#backfill_legacy_payment`. A2's rollout evidence (§10.5) lists any closed-month row the rule would move before deploying.

### 5.4 Allocation policy and proof

**Inputs.** The capture's component vector **K** = (proceeds, fee, organizer_fee, tax) from the capture row. Validate `ΣK = C` at classification; a mismatch quarantines. For `payment`-scope captures (a second payment on a fulfilled order), **K** = (C, 0, 0, 0): no fee or tax was earned on that payment, so the whole amount is buyer principal, carried in the first slot. Readers never treat it as organizer proceeds (§8).

**Applied amount for movement k** (positive *gross*): `aₖ = min(grossₖ, C − Aₖ₋₁)`, with excess `xₖ = grossₖ − aₖ`, where `Aₖ₋₁` = Σ previous `applied_cents`. Excess is decided on **gross** against C alone (code-review findings 2a and 2b).

**Component allocation of `aₖ`** under `:item_record` (default, P9):

1. **Refund, fully applied (`aₖ = grossₖ`), with `RefundItem` rows that fit the remaining components:** use the refund's own `RefundItem` split. In A1, `RefundCreator#allocate_items!` for a classified payment allocates against the **ledger's remaining components** (**K** − Σ previous postings) instead of refund-only remainders (`refund_creator.rb:630`, which ignores lost disputes). This keeps `RefundItem` rows and postings identical.
2. **Lost dispute, partly applied refund, or an older refund whose items don't fit:** `Commerce::BoundedAllocator.call(aₖ, remaining)`. It computes `MoneyAllocator`'s floors and hands out remainder cents in the same index order, **skipping any component already at its remaining balance**. It equals `MoneyAllocator` whenever `MoneyAllocator` stays within bounds. Plain `MoneyAllocator` can give a remainder cent to a zero-weight component (weights `[0, 1, 1]`, total 1 puts 1¢ on index 0), so it cannot be used against remaining balances.

**Reversal (negative `grossₖ`, magnitude d):** excess absorbs first. `xₖ = −min(d, X)`, `aₖ = −(d − min(d, X))`, and `aₖ` is allocated with `BoundedAllocator` over the **net cumulative returned components** (Σ previous postings), negated.

**Proof (between reversals).** Let **Rₖ** = **K** − Σᵢ₌₁ᵏ allocᵢ.

1. *Feasibility:* `aₖ ≤ C − Aₖ₋₁ = ΣRₖ₋₁`. `BoundedAllocator` returns 0 ≤ allocₖ ≤ **Rₖ₋₁** componentwise with Σ allocₖ = aₖ. The floors satisfy ⌊aR_j/ΣR⌋ ≤ R_j, and spare capacity Σ(R_j − floor_j) ≥ aₖ − Σfloor_j, so the remainder always fits. A refund's own items are used only if they fit. So **Rₖ** ≥ 0.
2. *Monotone:* allocₖ ≥ 0, so every component's cumulative return is non-decreasing, and no share moves backwards between months.
3. *Full return clears every share:* if A = C then Σ**R** = 0 with **R** ≥ 0, so **R** = 0. Proceeds returned = T exactly, fees returned = the fee share exactly.
4. *Gross identities:* `A + O = C·[t₀ < t]`, `A + X = R` (cumulative gross returned), `0 ≤ O ≤ C`.
5. *Month projection:* for Guam month [s, e), a column's value is a sum of postings with `s ≤ recognized_at < e`. Opening(M) = Σ before s, closing(M) = Σ before e, so **opening + captures − paid = closing** and **closing(M) = opening(M+1)** hold by construction. No input changes after posting.
6. *Closed months stay closed:* a new posting has `recognized_at ≥ guam_month_start(posted_at)`, so it cannot enter an earlier month. Its allocation depends only on earlier postings, which are immutable.

Across a reversal, monotonicity (2) does not hold, by design. The reversal is a current-period movement, and (1), (3)–(6) still hold because the reversal is itself a posting and |aₖ| ≤ A.

### 5.5 The 75¢ counterexample (why CPA must approve P9)

Order: one $12.00 ticket with a $1.60 HåfaPass fee, and one $12.00 add-on with no fee. C = $25.60, proceeds $24.00, fee $1.60. An admin refunds **$13.60**. `RefundCreator#allocate_items!` walks items in ID order, so the ticket item takes the whole $13.60 = $12.00 proceeds + $1.60 fee.

| Policy | Fee reversed by the $13.60 refund | Proceeds share returned | After a second refund of $12.00 |
| --- | --- | --- | --- |
| `:item_record` (default) | **$1.60** | $12.00 | fee $1.60, proceeds $24.00 total |
| `:cumulative_pro_rata` (v1) | **$0.85** (⌊1360 × 160 / 2560⌋) | $12.75 | fee $1.60, proceeds $24.00 total |
| Difference | **$0.75** in `fee_refunds` / BPT base, opposite sign in `buyer_refunds_paid` | | none at full return |

v1's "at most one cent per share" claim is false and is withdrawn. Both policies are exact, monotone and clear every share at full return. They disagree only on *which month's* fee revenue a partial return reverses. **Recommendation: `:item_record`.** It reconciles cent for cent with the `RefundItem` rows that the BPT detail CSV (`tax_reports.rb:114`), `TaxReports#months` and the settlement calculator already read, so no reader needs a bridge. It also matches what the buyer saw: "this ticket was refunded". CPA approval of P9 is required, and the CPA guide must state the rule and show this example.

### 5.6 Late wins and other reversals

Stripe documents rare late wins after a loss ([late-win disputes](https://docs.stripe.com/disputes/how-disputes-work#late-win-disputes)). Today `process_dispute!` ignores any update to a dispute already `won` or `lost` (`stripe_webhook_processor.rb:437`). A1 adds a branch for verified `lost → won` (a signed `charge.dispute.closed`/`updated` with `status = won`, or `warning_closed` per Stripe's object):

- `disputes.status` stays `lost`, and `closed_at` is not rewritten. CPA's loss month (`lost_disputes_base` is status-based) stays byte-identical. A new set-once column, `disputes.loss_reversed_at`, plus audit `dispute.loss_reversed` records the reversal.
- Classified payment: post `dispute_loss_reversal` in the current period, then run the evaluator, which may reopen repayment (§7).
- Fulfilled order: open `dispute_late_win` for finance. The organizer-side treatment (a current-period credit) is a residual (§11); nothing is lost, because the reversal is recorded.
- A provider refund that turns `failed` after `succeeded` stays `refund_terminal_status_conflict` (existing). Only a finance-confirmed audited action posts `refund_reversal`.

---

## 6. One repayment workflow (PR A1)

### 6.1 Ledger quantities

`Commerce::BuyerOwedLedger.for(capture)`, read under the order lock:

| Quantity | Definition |
| --- | --- |
| **Owed** O | `C − Σ applied_cents` over postings |
| **In flight** | Σ amounts of `pending` refunds on the payment (including `provider_result_unknown` and `submission_requested`) + Σ amounts of `open` disputes on the payment + any unreplayed provider evidence for the payment (§7.2) |
| **Available to submit** | `max(O − in_flight, 0)`, and **0** if any refund on the payment is pending or unknown, any dispute is open, the last attempt failed with `refund_disputed_payment`, or evidence is unreplayed |
| **Excess** X | Σ `excess_cents` |

A pending $13.60 refund leaves O = $13.60 and available = $0 until it succeeds.

### 6.2 Where it is enforced

`Commerce::BuyerRepayment.check!(order:, payment:, amount:, source:)` runs inside `RefundCreator` under organization → event → order, **at reservation** (`reserve_refund!`, `refund_creator.rb:164`) and **again at the last local submission gate** (`provider_submission_allowed?(mark_unknown: true)`, `:275`), where `submission_requested` is persisted before the HTTP call. For a classified payment it refuses an amount above *available*, refuses while anything is in flight, and refuses organizer-initiated refunds outright ("HåfaPass returns this payment to the buyer"). Every outbound refund path reaches `RefundCreator`, so one check covers them all:

| Entry point | File | On a classified payment |
| --- | --- | --- |
| Automatic late-capture refund | `LateCaptureRefundJob` → `LateCaptureRefund.call` | Amount = available; waits quietly at 0 |
| Admin "Refund buyer" | `admin/reconciliation_exceptions_controller.rb:139` | Same; shows the wait reason |
| Refund queue retry and late-capture actions | `refund_reconciliation_actions.rb:104`, `:149`, `:238` | Same |
| Admin order refund | `admin_order_refund.rb:97` | Capped at available |
| Fraud refund | `early_fraud_warning_refund.rb:44` | Capped at available |
| Organizer refunds | `organizer/refunds_controller.rb:34` | Refused |
| Event cancellation refunds | `event_cancellation_refund_job.rb:125`, `cancellation_refund_actions.rb:45`, `:82` | `EventCancellationRefunds.balances` excludes classified orders and payments. Today `PAID_STATUSES` includes `partially_refunded`/`refunded`, so a partly returned never-fulfilled order **would be refunded a second time** by an event cancellation |
| Buyer ticket and event-change refunds | `orders_controller.rb:288`, `:406` | Unreachable (no tickets); the check still refuses |
| Inbound provider refunds | `ExternalRefundRecovery.ingest!` | **Not an outbound submission:** recorded even when nothing is owed (§7.3) |

### 6.3 Attempt identities

Refund idempotency key: `late-capture:payment:<payment_id>` for attempt 1, the exact key used today, so a refund already in flight from an old worker is attempt 1. After that it is `late-capture:payment:<payment_id>:attempt:<n>`. Under the order lock, *n* = 1 + the number of late-capture refunds on the payment in a **verified terminal failure** (`failed` or `cancelled` from the provider; `provider_result_unknown` is not terminal). A retry of the same operation computes the same *n*, and therefore the same key. *n* only advances after a verified terminal outcome. v1's `<owed cents>:<movement IDs>` key could repeat after a definitive failure with unchanged balances; this one cannot. Before any new attempt, the workflow reconciles an existing pending or unknown refund with `recover_provider_refund` (`StripeService.find_refund` by key) and never creates a second operation while one is unresolved.

### 6.4 Disputes

- **Dispute open:** available = 0. While a dispute is open Stripe refuses refunds (`refund_disputed_payment`) and recommends accepting or contesting rather than refunding ([Respond to disputes](https://docs.stripe.com/disputes/responding)).
- **Stripe refuses with `refund_disputed_payment`** although no dispute is recorded locally (the dispute was created after our lock was released): the refund fails with that code (no money moved), which counts as in flight. `ProviderEvidenceReplay` lists the charge's disputes through the API, ingests the dispute, and the evaluator waits for its outcome before any replacement attempt.
- **Lost:** posted; usually O = 0. **Won / `warning_closed`:** the evaluator enqueues repayment of the remaining *available*.

### 6.5 Excess detection

HåfaPass's own submissions are serialized and capped, so excess can only come from outside: Dashboard refunds, issuer credits, a dispute recorded after a refund. Every posting with `excess_cents > 0` opens one `never_fulfilled_buyer_overpaid` exception, deduplicated on `(capture_id, posting_id)` and listing the movement IDs and gross amounts. Under P4 it alerts and audits and does not hold organizer payouts.

---

## 7. One resolution evaluator (PR A1)

### 7.1 `Commerce::NeverFulfilledResolution.evaluate!(capture, trigger:)`

Idempotent. It runs inside the caller's organization → event → order transaction at **every** relevant transition: classification (the design review's F3 point), refund `succeeded`/`failed`/`cancelled`/unknown→resolved, dispute `opened`/`lost`/`won`/loss reversal, inbound external refund, and evidence replay. Outcomes:

| State | Action |
| --- | --- |
| O = 0, nothing in flight | Resolve the capture's open `LateCaptureRefund::CODES` and companion (`provider_payment_cancel_failed`) exceptions. Audit `reconciliation_exception.resolved` with `payment_id`, posting IDs, refund and dispute IDs, gross, applied and excess amounts, pending state = none, and a reason such as "Repaid: refunds $X, lost disputes $Y". Replaces `RefundCreator#resolve_repaid_late_capture!` (`refund_creator.rb:699`), which requires `payment.refunded?` and so missed lost disputes (code-review finding 4) |
| O > 0, available > 0 | Enqueue `LateCaptureRefundJob` after commit |
| O > 0, available = 0 | Wait; record the wait reason on the exception (`dispute_open`, `refund_pending`, `refund_unknown`, `evidence_unreplayed`) |
| O > 0 after an earlier resolution (late win, finance-confirmed refund reversal) | Open a linked `never_fulfilled_repayment_reopened` exception (`details.previous_exception_id`), audit it, and enqueue if available |
| X increased | §6.5 |

A manual "Resolve" with a note is allowed only when the evaluator would resolve. It currently returns 422 after a full lost dispute (`resolution_rule`, `admin/reconciliation_exceptions_controller.rb:248`).

A full loss followed by the failure of a pending refund triggers the evaluator on the refund's failure. The failure returns no money, but it removes the in-flight amount, so the exception closes.

### 7.2 Evidence that arrives before binding

A door PaymentIntent is bound to its payment only in `process_door_success!`. A `refund.*`, `charge.refunded` or `charge.dispute.*` event that arrives first finds no payment (`find_payment` uses `payment_intent`). It then records `refund_operation_not_found` or `disputed_payment_not_found` with no payment. `ProviderEvidenceReplay.for_payment!(payment)` runs after commit whenever a payment gains a `provider_payment_id`. It selects stored `webhook_events` whose `data.object.payment_intent` equals the new ID and that are processed with a `*_not_found` exception, reprocesses them through `StripeWebhookProcessor` (idempotent by receipt and provider IDs), and resolves the orphan exceptions with an audit entry. Until replay finishes, the payment counts as having unreplayed evidence (in flight).

### 7.3 `ExternalRefundRecovery`

Today `ingest!` goes through `RefundCreator.call`. That path needs a completed order or `refundable_late_capture?` (which needs `succeeded_at` and a matching exception), an amount ≤ the remaining balance, and order items. It can reject real provider evidence before capture is recorded, or when a competing operation already reserved the balance (`external_refund_recovery.rb:48`, `refund_creator.rb:215`). For a classified payment, or a payment whose capture is not yet recorded, A1 changes it to:

- **Record the provider fact first:** a `Refund` row in the provider's status with key `provider:stripe:refund:<id>`, outside the remaining-balance and financial-review checks. Those limits apply to outbound submissions only.
- **Succeeded and the payment classified:** post it (applied and excess per §5.4); `RefundItem`s cover only the applied part.
- **Payment captured but not yet classified (webhook order):** keep the row pending classification. `classify!` posts it.
- **Payment not yet captured locally:** keep the receipt for replay (§7.2).
- **A competing pending HåfaPass refund with the same provider ID or key:** bind it, as `find_provider_operation` does today. A different provider ID is a separate movement, and excess detection applies.

---

## 8. Finance readers (PR A2)

### 8.1 Reader register

`config/never_fulfilled_readers.yml` lists every file under `app/` that reads order or payment money states (today the files matching `partially_refunded|:refunded|"refunded"`, about 50, plus every user of `excluding_test_payments`). Each entry has a treatment, `exclude`, `platform_only`, `info_line` or `not_money`, and the spec that proves it. A CI spec, modelled on the `data_retention.yml` check, fails when a matching file has no entry. "Exhaustive" is then checked, not claimed.

### 8.2 Treatment of the main readers

| Reader | Today | v2 treatment |
| --- | --- | --- |
| `Settlements::Calculator` | Includes refunded or partly refunded never-fulfilled orders; v1-era special cases | Exclude classified orders entirely. For `payment`-scope captures, exclude that payment's refunds, `RefundItem`s, lost disputes and processing. **Linked `BalanceAdjustment`s** (`order_id` on a classified order or `dispute_id` on a classified payment) and their reversals (`reversal_of_id` inherits) are excluded from `adjustment_cents` and listed in the integrity alerts. Remove `never_fulfilled_platform_processing?` and the `lost_disputes` reject. Add one `$0` info line per capture (§8.3) |
| `PayoutStatement` | Through the calculator | Renders the info line plus a **live** return status from the ledger (not stored) |
| `OrganizationFinanceSummary` | Sums `item_sales`, `refunded_proceeds`, `buyer_fees` directly from orders (`organization_finance_summary.rb:84–102`) | Exclude classified orders and payments in all three and in `financial_events` |
| `OrganizationPayoutBalance` | Blocks org-wide on any open exception; deducts pending refunds and open disputes org-wide; reads cancellation recovery | Under `PAYOUT_HOLD = :unknowns_only`, exceptions with codes `LateCaptureRefund::CODES`, `unfulfilled_second_capture`, `provider_payment_cancel_failed` and `never_fulfilled_buyer_overpaid` on classified payments **do not block**; `never_fulfilled_backfill_ambiguous`, `inventory_released_provider_unknown` and unreplayed evidence still do. Pending refunds and open disputes on classified payments are platform money, **not organizer debits**: excluded from `unresolved_refunds`/`unresolved_disputes` and from cancellation `already_reserved` |
| `Settlements::Finalizer.open_money_blocker`, `EventLifecycle#archive_blocker` | Same queries | The same rule as payout balance; missing processing evidence on classified orders doesn't block when the snapshot bearer is `platform` (it does under `organizer`) |
| `PayoutCreator` | Refuses a stale digest (`payout_creator.rb:186`) | Unchanged |
| `PayoutHoldRelease`, `AdminPayoutDueList`, `PayoutSchedule`, `PayoutCalendar` | Through calculator and balance | No code change; held and in-flight payouts on affected events are reviewed at rollout (§10.5) |
| `EventCancellationRefunds` | `PAID_STATUSES` includes refunded | Exclude classified (§6.2) |
| `RefundReconciliationQueue` | Owed = amount − refunds (`:138`); `recovery_amount_for_event` | Owed from the ledger; recovery excludes classified |
| `CpaMonthlyReport` | Exception-window predicate; `buyer_returns_by_event` in Ruby | Classification by table; postings for buyer columns and classified fee refunds; §5.3 recognition on every bucket; bridge exclusion by classified order IDs (closes deferred residual 5); `unallocated_refunds_exception` ignores classified payments (excess has no items by design); gross columns (P3); new integrity alerts: classified with tickets, component mismatch, quarantine |
| `TaxReports#bpt_event_rows` | RefundItem fees; payouts by current agent orders | Classified fee refunds from postings; recognition helper; R2-2 (§8.6) |
| `TaxReports#organizers` | `collected_orders` includes expired/cancelled captured orders, so never-fulfilled ticket proceeds count as organizer receipts | Exclude classified activity entirely (it is not the organizer's) |
| `TaxReports#months` | Fees and processing on collected orders | Classified fee recognized at capture and reversed by postings; processing counted as platform cost |
| `Commerce::PlatformRevenue` | `SETTLED_STATUSES` excludes released orders until a refund flips them; organizer split | Separate classified rule: fee revenue = fee share recognized − fee share returned (postings), not floored against organizer events. Actual, attributable processing (`FeeComponent` `processing`, `estimated: false`, on the classified payment's order) is a platform cost when the snapshot bearer is `platform`; the actual dispute fee per P5 |
| `FinanceExports` | Order CSV over `SETTLED_ORDER_STATUSES` | Omit classified orders from the orders CSV; the statement CSV carries the `$0` line |
| Sales, analytics and ops (`EventReportingService`, `EventSalesAnalytics`, `OrganizerSalesQuery`, `LedgerTotals`, `Operations::DailySummary`, `PilotCloseout`, `LiveMoneyProofReview`, admin dashboard) | Status-based | `Order.excluding_never_fulfilled` scope; each listed in the register |

### 8.3 Statement line and digest

One item per classified capture: `kind: "adjustment"`, `amount_cents: 0`, `source: NeverFulfilledCapture`, `occurred_at: capture_recorded_at`, description **"Payment received, order unfulfilled"**, metadata `{ adjustment_kind: "never_fulfilled_capture", order_id, payment_id, captured_cents }`. The metadata is fixed at classification, so later refunds and disputes **do not** change the digest or force a new approval. The interim `57de7f15` processing item (`calculator.rb:303`) is removed, so processing evidence arriving later does not change the digest either. `PayoutStatement` shows the live status next to the line ("Owed to buyer", "Being returned", "Returned to buyer"). Under the `organizer` bearer snapshot only, a `processing_fee` item of −amount is added; changing the bearer *does* change what the organizer is charged, so it must force re-approval.

### 8.4 Custody

A classified capture is never organizer custody. In the CPA export its principal is a **buyer liability**; its fee share stays HåfaPass fee revenue until returned (P2 governs lost disputes). The non-custodial bridge never includes it.

### 8.5 Gross buyer liability (P3)

New CPA columns, appended at the end so existing consumers don't break: `opening_buyer_owed_gross`, `buyer_owed_captures_gross`, `buyer_owed_returned_gross`, `closing_buyer_owed_gross`, `buyer_overpaid_in_month_gross`, `buyer_overpaid_cumulative_gross`. Identity: `closing_buyer_owed_gross = opening + captures − returned`. Bridge, stated in the guide and asserted by spec:

```
closing_buyer_owed_gross = closing_buyer_refunds_owed (ticket share) + fee/tax share recognized on classified captures − fee/tax share returned
```

### 8.6 R2-2: historical BPT payout eligibility

**Defect.** `TaxReports#paid_payouts` selects payouts whose `event_id` has *any current* agent order (`tax_reports.rb:183`, called with `orders: agent_orders`). A Stripe capture recorded in February therefore pulls a January payout on a Clover-only event into a regenerated January BPT CSV.

**Fix (P12, as-of evidence).** A payout appears in the BPT detail only if a **qualifying custody capture** on its event was recorded **at or before the payout's paid recording time**. That time is `COALESCE(paid_audit.created_at, payouts.paid_at)`, the CPA's `PAID_RECORDED_AT_SQL` and redaction-safe paid-audit join, shared through one helper. A qualifying capture is in `Payment.live_agent_capture`, has `capture_recorded_at ≤` that time, and is **not classified**. Classification is written in the capture's own transaction, so "not classified as of T" equals "not classified". Every input is immutable, so a later capture or classification cannot change a closed month. Month membership keeps using `paid_at` in A2. Whether BPT should move to the paid recording month, as CPA does, is a CPA residual (§11). The alternative, snapshotting custody on the payout's settlement items, was rejected: settlement items carry no payment identity, so it would need a payout-time snapshot migration and a backfill.

### 8.7 Holds versus debits (P10)

| Item on a classified capture | Organizer debit? | Blocks organizer finalization or payout? |
| --- | --- | --- |
| Owed balance, pending known refund, open dispute | No | No under `:unknowns_only`; yes under `:strict` |
| Excess (overpaid) | No | No (P4) |
| Unknown refund result, unreplayed evidence, quarantine, unknown provider release | No | **Yes**, under every setting |
| Processing (bearer `platform`) | No | No |
| Processing (bearer `organizer`) | Yes (statement item) | Missing evidence blocks |

Why `:unknowns_only` is safe: the buyer's money is in HåfaPass's Stripe balance and is excluded from the organizer payable, so paying the organizer does not touch it. The remaining risk is misclassification, which is exactly what quarantine and unknown-state blocking cover.

### 8.8 Re-finalization, history and payouts

- A2 changes the digest of every event that has a classified capture and previously showed its refund, processing or dispute lines. Finalize those events again before paying. `Finalizer` creates a new version, and the old versions and their payouts stay unchanged (`settlements` are versioned; payouts keep `settlement_id`).
- An **archived** event that needs correcting goes through the audited `unarchive` (`EventLifecycle` `:unarchive`), then finalize and archive again.
- **Held** (`held`) and **in-flight** (`pending`, `processing`) payouts on affected events are reviewed one by one before A2 is deployed (§10.5). Rule: if the payout amount exceeds the A2 calculator's available amount, finance keeps it held. `PayoutHoldRelease` is not changed blindly.
- Finalization can still be blocked after the buyer is repaid: by processing evidence on *fulfilled* orders, by cancellation refunds, or by other exceptions. The evaluator only removes the never-fulfilled blockers.
- Flipping a snapshotted switch does not restate old captures (§1).

### 8.9 Monitoring (A3)

A weekly count of new classifications by code and flow; open owed balances older than 24 h; open excess; `released_unknown` count; stalled holds (§3.2); the replay backlog.

---

## 9. Acceptance examples and test plan

### 9.1 Worked examples

Fixture unless stated: one $12.00 ticket + $1.60 HåfaPass fee; C = 1360, **K** = (1200, 160, 0, 0). Actual processing $0.69, order bearer snapshot `organizer`, P1 = HåfaPass. Times in ChST. "Calc" = `Settlements::Calculator`; "Stmt" = `PayoutStatement`.

| ID | Scenario | CPA (event row) | Calc / Stmt | Ledger, exceptions, provider calls |
| --- | --- | --- | --- | --- |
| E1 (CR F1) | Captured Jan 10; automatic job disabled in the fixture; external Stripe refund $5.00 Jan 12; admin **Refund buyer** Jan 12 | Jan: captures 12.00; paid 4.42 + 7.58 = 12.00; closing 0; fee revenue 1.60, fee refunds 0.58 + 1.02 = 1.60; gross owed after the $5.00: 8.60 | payable 0, proceeds 0, refund_cents 0; one $0.00 line "Payment received, order unfulfilled", status "Being returned" then "Returned to buyer" | $5.00 split 442/58 (`MoneyAllocator`); available 860; exactly **one** Stripe refund POST of 860 with key `late-capture:payment:<id>`; exception auto-resolved with posting IDs |
| E2 (CR F2a) | Adult $8.00 + child $4.00, fees $1.07 + $0.53; refund $4.70 Jan 10; lost dispute $8.91 Feb 20 | Jan: paid 4.15, closing 7.85. Feb: paid 7.85, closing 0; overpaid 0.01 gross | payable 0 | Refund items 415/55; dispute applied 890 = all remaining (785/105), excess 1; one overpaid exception; late capture resolved; no payout hold (P4) |
| E3 (CR F2b) | Refund $0.01 Jan 10; lost dispute $13.59 Feb 20 | Jan: paid 0.01. Feb: paid 11.99, closing 0; **no** excess | payable 0 | Resolved; no overpaid exception |
| E4 (CR F3) | Online: dispute lost recorded Feb 28 23:59:50; capture recorded Mar 1 00:00:10 | Feb: no row. Mar: opening 0, captures 12.00, paid 12.00, closing 0, fee revenue 1.60, fee refunds 1.60 (P2); note on the Feb 28 loss | payable 0 | Posting created by `classify!`, `recognized_at` = Mar 1 00:00:10; evaluator resolves at classification; **zero** refund POSTs |
| E4b | Door: dispute webhook before `payment_intent.succeeded` | as E4 | as E4 | `disputed_payment_not_found` orphan; replay after binding; orphan resolved; one posting |
| E5 (CR F4) | Captured Feb 10 10:00; dispute opened 10:02 before the job; lost Feb 20 $13.60 | Feb: paid 12.00, closing 0, chargebacks 0 | payable 0; Finalizer **not** blocked under `:unknowns_only`, blocked under `:strict` | Job waits (`dispute_open`), zero POSTs; resolved on loss; manual resolve allowed after loss |
| E6 (F4b) | E5 but won Feb 20 | Feb: paid 12.00 when the refund succeeds | payable 0 | Evaluator enqueues; one POST of 1360 (attempt 1 key) |
| E7 (CR F5) | Legacy fulfilled order, `completed_at` null, issued ticket, hand-added backdated exception | proceeds 12.00, organizer processing 0.69, custody 11.31 | payable 1131 | `reconcile` writes no classification ("has tickets"); no quarantine needed |
| E8 (R3-1) | Capture Feb 28 23:59:59; exception stamped Mar 1 00:00:00; refund Mar 1 00:05 | Feb: captures 12.00, closing owed 12.00 (gross 13.60), informational processing 0.69. Mar: opening 12.00, paid 12.00 | payable 0, platform processing 69 | One classification, *t₀* = Feb 28 23:59:59 |
| E9 (R3-2) | P1 snapshot `false` vs `true` | false: organizer processing 0. true: `organizer_processing_deducted` 0.69 | false: processing 0, Stmt "covered by HåfaPass". true: −69 item, negative 69 | Snapshot on the row; flipping the constant later leaves this row alone |
| E10 (R3-3a) | Lost dispute $13.60 Feb 20; external refund $13.60 Mar 2 | Feb: paid 12.00. Mar: paid 0; overpaid 13.60 gross | payable 0 | `ingest!` records the refund despite remaining = 0 (today it raises "exceeds refundable balance"); `RefundItem`s 0; one overpaid exception |
| E11 (75¢) | §5.5 order; admin refund $13.60, later $12.00 | `:item_record`: fee refunds 1.60 then 0.00; `:cumulative_pro_rata`: 0.85 then 0.75 | payable 0 | Both reach (2400, 160) at full return |
| E12 | Late win: E5 loss Feb 20, reversed Mar 15, repayment succeeds Mar 15 | Feb unchanged (byte-identical). Mar: `dispute_loss_reversal` −13.60 (owed back to 12.00 ticket share), then paid 12.00, closing 0 | payable 0 | Reopened exception linked to the first; one POST of 1360 with key `late-capture:payment:<id>` (no earlier attempt) |
| E13 | Distinct second capture: order fulfilled by payment A; payment B succeeds | A's sale unchanged; B: buyer owed 13.60 (principal slot), not proceeds | payable from A only + one $0 line for B | `scope: payment` row; order marker unset; B's refund never reduces organizer proceeds |
| E14 (R2-2) | Clover-only event; $10.00 payout paid and audited Jan 20; Feb 5 a never-fulfilled Stripe capture on the same event; variant Feb 5 a *fulfilled* Stripe sale | January BPT CSV regenerated in Feb: **no payout row**, byte-identical to the January original in both variants. Control: Stripe sale Jan 5 + payout Jan 20 → payout row in January | — | — |
| E15 | Mixed event: one fulfilled sale + one never-fulfilled capture | Custody shows only the fulfilled sale; buyer columns only the other | Calc, Stmt, summary, finance CSV, `PlatformRevenue` and payout balance agree to the cent | — |
| E16 | Event cancelled with a partly returned classified order | Cancellation refunds: classified order **absent** from preview count and total | — | Zero cancellation POSTs for it |

### 9.2 Test inventory

Countable outcomes are stated per test. "2-conn" means two independent PostgreSQL connections with latches (`spec/support/lock_race_helpers.rb`), a short `lock_timeout`, contention established with `pg_blocking_pids`, and no sleeps as assertions (LOCKING.md).

**Prevention (PR B)**

- P-01…P-06: one per online row of §3.1. Assert the decision kind, the number of local releases (0 or 1), and that `payments.status = cancelled` only with `release_evidence`.
- P-07…P-12: one per door row; P-11 is the unpublished door-success path, which yields a classification with `reason = event_not_published` and no expiry audit.
- P-13: 50 due orders and a stub with 5 s latency on 10 of them. **Every order gets its first attempt** before any order's second; the run's queue age is recorded.
- P-14: unknown at the cap → `released_unknown`, one exception, payment still `pending`; later `canceled` → exception resolved.
- P-15: door paid wait → extended once; API-event replay fulfils.
- P-16…P-20: each capacity path in §3.2 counts the hold through grace and stops after release.
- P-21…P-27: each P4 step, including a sibling-night pass staying pending and a refreshed refund preview.
- Stripe test mode (B1 and B2 acceptance): 3DS-required test card versus cancel, both winners; cancel accepted but its response timed out; `processing`; a complete Session with no signed webhook; delayed and duplicate signed events; setup in flight with no saved ID.

**Classification**

- C-01: the composite FK rejects another order's payment.
- C-02: `update_columns`, `update_all` and raw SQL can't clear or change the marker, delete or modify a capture row, or change `succeeded_at`. Each fails with SQLSTATE 23514 or 23503.
- C-03: a completed order with a marker is rejected by the CHECK.
- C-04: ticket insert via `issue_tickets!`, `Passes::Issuance` and raw SQL on a classified order → rejected (three cases).
- C-05: a duplicate success notice → one row.
- C-06: a second distinct capture on a classified order → two rows, first marker unchanged.
- C-07: second capture on a fulfilled order (E13).
- C-08: `schema:load` restores every trigger (`pg_trigger` count = expected).
- C-09: schema round trip shows zero diff.
- C-10…C-14: backfill. Positive provenance classifies; each missing proof → quarantine; a repeated run → no new rows; recheck under locks after a concurrent change; a restatement listed and refused without confirmation.

**Ledger and allocation**

- L-01: `BoundedAllocator` property test: 10,000 random vectors; never exceeds remaining; equals `MoneyAllocator` when in bounds.
- L-02: exhaustive check of every applied total 0…1360 for the base fixture, and 0…2560 for §5.5, under both policies: monotone, full return clears, sums exact. (The design review checked 1,361 applied balances.)
- L-03…L-08: E2, E3, E4, E10, E11, E12.
- L-09: both delivery orders of a pre-capture return.
- L-10: a late posting after month-end lands in the posting month; the earlier month's CSV is byte-identical.
- L-11: fee and tax endpoints (fee 0; tax > 0).
- L-12: closed-month byte comparison of the CPA and BPT CSVs after every later movement in L-03…L-11.
- L-13: a legacy refund whose items exceed remaining → bounded allocation used, noted.
- L-14: late win on a fulfilled order → `dispute_late_win`, CPA loss month unchanged.
- L-15: §5.3 recognition on fulfilled returns before custody (backfilled legacy capture).
- L-16: component mismatch at classification → quarantine.

**Repayment**

- R-01…R-12: every §6.2 entry point on a classified payment, plus:
  - a pending $13.60 refund → available 0;
  - unknown, then retry → the same key and a provider lookup (`find_refund`) before any POST;
  - a verified failure → attempt 2 key;
  - `refund_disputed_payment` → wait and dispute ingestion via the API;
  - an organizer refund refused.

  Countable: **Stripe refund POST count and amount** per test.
- X-05 (2-conn): job versus admin "Refund buyer" → exactly one POST.
- X-06 (2-conn): job submission gate versus `charge.dispute.created` → either the dispute commits first (zero POSTs) or the POST happens and Stripe's refusal is a wait (one failed attempt, zero money moved, no second attempt before the outcome).

**Evaluator**

- E-01…E-10: each trigger in §7.1, the reopen path, refund failure after full loss, replay after binding, and `ingest!` cases (before capture, competing reservation, excess). Audit metadata lists posting IDs.
- X-07 (2-conn): refund success versus dispute loss commit → one resolution, excess computed once, no deadlock (organization → event → order in both).

**Finance readers**

- F-01…F-11: each §8.2 row against E15 and E16 (summary, statement, finance CSV, `PlatformRevenue`, payout balance, finalizer, archive blocker, cancellation recovery, `TaxReports#organizers`/`#months`, register CI).
- F-12, F-13: E14 and its control.
- F-14: linked `BalanceAdjustment` and its reversal excluded.
- F-15: both processing bearers.
- F-16: stale digest refused; the prior finalized version's totals and items are preserved.
- F-17: held payout on an affected event listed by the rollout check.
- F-18: classified pending refund not deducted from the organization's available balance.

**Concurrency (prevention)**

- X-01 (2-conn): expiry release versus a competing purchase at the exact grace boundary → no oversell, one of {fulfilled, never-fulfilled}.
- X-02 (2-conn): probe decision versus a Session created mid-probe → decision discarded.
- X-03 (2-conn): night cancel versus pass completion → both complete without deadlock under the new `FOR NO KEY UPDATE`.
- X-04 (2-conn): gate commit versus new checkout → checkout refused after the gate commits.

**Mixed version** (§10.3)

- M-01…M-04.

---

## 10. Delivery and rollout

### 10.1 PR shape

| Deploy | PR | Contents | Safe against the previous version's workers because |
| --- | --- | --- | --- |
| **A1** | rework #248 | Migrations (tables, columns, unique index, CHECK `NOT VALID` then validate), `FinancialIntegrity` triggers, `classify!` at every boundary, postings writers, late-win recording, `BuyerRepayment` gate, attempt keys, evaluator, `ProviderEvidenceReplay`, `ExternalRefundRecovery` changes, `EventCancellationRefunds` exclusion, admin owed/resolution rules, `never_fulfilled:reconcile` (task + temporary recurring job). **Finance readers unchanged** (main's). The #248 interim reader code from `57de7f15` is reverted in A1 so there is one reader generation at a time | 7bcd97c2 code never writes the new columns or tables; the triggers only reject things 7bcd97c2 never does legitimately (completing a classified order, issuing tickets on one). Rows an old worker writes during the overlap are picked up by `reconcile` |
| **A2** | follow-up PR | All §8 readers in one switch, the reader register CI, CPA/BPT columns and guide, R2-2, `PAYOUT_HOLD`, admin breakdown | A1 workers already classify and post. A2 refuses to boot its readers until `never_fulfilled:verify` reports zero unclassified candidates and zero unposted movements (release check, §10.5) |
| **A3** | follow-up PR | Remove the exception-window predicate and `EVIDENCE_WINDOW_SECONDS`, the temporary reconcile schedule and dead v1 code; monitoring (§8.9) | A2 never reads the removed code |
| **B1** | new PR | §3.1, §3.2, §3.4, eligibility recheck | Independent of A's schema; it needs A1's `classify!` for ineligible completions |
| **B2** | new PR | §3.3 staged transitions, `EventLifecycle` lock mode | Needs B1's release decision |

**Order and dates.** A1 and A2 must both be in production before Jan 4, 2027, with A2 at least one recurring `reconcile` cycle after A1. A3 may follow in January. B1 should land before Jan 4. If it slips, A still keeps the books right and only the frequency is higher. B2 follows B1. Door-card payments stay off (`events.online_door_card_enabled` defaults to `false`) until A2 and B1 are live and the `checkout.session.expired` subscription is confirmed (PRODUCTION_CUTOVER.md step 1).

### 10.2 Why writers first

If readers switched in the same deploy as writers, an old instance in Render's zero-downtime overlap could record a late capture with no classification, and the new readers would book it as organizer custody. With A1 first, old and new readers agree during A1's overlap (both are main's), `reconcile` classifies the overlap's rows, and A2's overlap partner is an A1 instance that classifies itself.

### 10.3 Mixed-version tests (CI job `mixed-version`, A1 and A2)

- **M-01:** check out the previous release's `app/` and its late-capture specs, load the **new** `schema.rb`, and run them. Expect 0 failures and triggers present.
- **M-02:** previous-release code records a late capture on the new schema, then new code runs `reconcile` → one classification, provenance evidence recorded, and postings for any refund it already made.
- **M-03:** previous-release `LateCaptureRefundJob` refund in flight (key `late-capture:payment:<id>`) when the new workflow starts → the new workflow treats it as attempt 1 and makes no second POST.
- **M-04:** A2 readers on A1 data produced by M-02 → CPA, BPT and calculator numbers equal the E-table expectations.

### 10.4 Local and test-mode rehearsal (before each production deploy)

On task-owned databases (`hafapass_ncap_rehearsal_*`, asserted `localhost:5432`, dropped afterwards):

1. Load 7bcd97c2's schema and run a scenario seed script that drives the real services for E1–E16 under 7bcd97c2 (Stripe stubbed; webhooks via `StripeWebhookProcessor`).
2. Generate the CPA and BPT CSVs for every month with activity and record their sha256.
3. Migrate to A1. Run `reconcile DRY_RUN=1` (expected counts printed), then for real. Regenerate the CSVs: **identical hashes** (A1 doesn't change readers).
4. Run 7bcd97c2 and A1 processes against the same database at once while replaying a late-capture webhook through the old process (the deploy overlap), then `reconcile`.
5. Deploy A2 locally, regenerate, and diff. Every changed row must map to an E-table expectation. The diff report is attached to the A2 PR.
6. **Rush measurement for P7 (B1):** a local k6 run with the repository's `load_tests/` scaled to Copa (abandoned carts plus 10% slow Stripe stub at 5 s). Record expiry queue age, first-attempt coverage before grace end, withheld inventory over time, and `released_unknown` count, covering ticket types, tiers, seats, catalog and door allotments. Acceptance: first-attempt coverage ≥ 99% within the grace on stub latency p95 ≤ 1 s, and zero oversells. Leon accepts or changes the 2/3-minute values from this report.
7. **Stripe test mode (B1/B2):** the scenarios listed under "Prevention" in §9.2, with real test-mode objects and signed test webhooks. No live mode.

### 10.5 Production release and rollback evidence

Agents do not read or change production data. The lead or Leon runs these **read-only** checks (SQL scripts committed in the PR under `script/never_fulfilled/`) and records the outputs in the PR:

| When | Evidence | Gate |
| --- | --- | --- |
| Before A1 | Counts: orders with a `LateCaptureRefund::CODES` exception; finalized settlements on their events; held, pending or processing payouts on those events; CPA/BPT CSV sha256 for every month with live activity | Recorded baseline |
| After A1 | `pg_trigger` rows for every `FinancialIntegrity` trigger; constraints `convalidated = true`; `reconcile DRY_RUN=1` output: classified N, quarantined Q, restatements R | Q and R reviewed by finance; R = 0 or explicitly confirmed |
| Before A2 | `never_fulfilled:verify` → 0 unclassified candidates, 0 unposted movements; CPA/BPT closed-month hashes equal the baseline | Both required |
| After A2 | Closed-month CSV hashes: unchanged except rows listed in the rehearsal diff; list of events needing re-finalization; held and in-flight payouts on them reviewed | Finance signs off before any payout on a listed event |
| After B1 | Monitoring: `released_unknown` = 0 in the first live week, or each one explained | — |

**Rollback.** Never run down migrations in production. A2 → A1: redeploy A1; readers revert, and postings and classifications keep accumulating. A1 → 7bcd97c2: redeploy; the schema is additive and inert to the old code. Repayment safety reverts to today's (no gate); after rollback, finance watches the late-capture queue manually. B1/B2 → previous: redeploy; holds written with grace simply count a little longer. Order `provider_release_state` columns are ignored by old code.

---

## 11. Residuals and open decisions

- **CPA approvals outstanding:** P1, P2 (both halves), P3, P5, P9 (with the 75¢ example), P11, P12. Until approved, the CSV header note says "working positions pending CPA review".
- **Leon decisions outstanding:** P4 recovery and write-off policy; P10 confirmation; P7 values after the rush report; postponed events treated as ineligible (§3.3).
- **BPT payout month:** BPT uses `paid_at` and CPA uses the paid recording time. A backdated `paid_at` can put a payout in different months in the two exports (pre-existing; CPA decides).
- **Late wins on fulfilled orders:** recorded and flagged (`dispute_late_win`); the organizer-side credit is a follow-up.
- **Dispute fees:** HåfaPass records no actual Stripe dispute fees today, for any dispute. P5 guarantees no organizer is charged; recording the actual fee and any credit as an attributable platform cost (a new `FeeComponent` kind) is a follow-up. CPA uses Stripe's statement meanwhile.
- **Refund failure after success:** stays a finance exception; posting a reversal needs an audited finance action.
- **Estimates:** A1 2–3 agent days, A2 2 days, A3 0.5 day, B1 2 days, B2 1.5 days. Each needs two review rounds plus the Stripe test-mode and rush rehearsal time in §10.4, which earlier estimates did not budget.
- **Ancillary docs:** `docs/CPA_MONTHLY_EXPORT_GUIDE.md` and `docs/SETTLEMENT_AND_PAYOUT_OPERATIONS.md` describe the interim `57de7f15` behaviour and already point here as the planned replacement. They make no promise this design breaks, so they are unchanged in this docs-only revision; A1/A2 update them with the code.
