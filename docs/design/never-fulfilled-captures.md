# Never-fulfilled captures: release decisions, classification, buyer-owed ledger and repayment

**Status:** design v2.1 (PR #248). v2 plus the amendments the v2 delta review requires before A1 (§0.1). v2.1 is the controlling input for A1. A1 is built in tranches (§10.1). Tranche 1 (the non-activating schema foundation), tranche 2 (lifecycle writers and payment-only boundaries, §4.6) and tranche 3 (return postings and reconcile, §5.7) are in this branch.
**Base:** `origin/main` `7bcd97c2` (#247, live in production) plus the #248 branch. v1 of this document is commit `846f808a`; the interim code it reviewed is `57de7f15`; v2 is `7098c31a`. All stay in the branch history.
**Reviews this version answers:** the design review of `846f808a` (required changes 1–8 and its test-matrix additions), the code review of `57de7f15` (findings 1–5), #247 rounds R1–R3, including the still-open **R2-2**, and the v2 delta review of `7098c31a` (four A1 amendments, two A2 amendments, B/P4 corrections). Sections 0 and 0.1 map each point to the section, code boundary and tests that close it.
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
| v2 | `7098c31a` | Verified-state release decision and hard cap; per-payment classification table with DB triggers; append-only return postings; allocation policy with proof and the 75¢ counterexample; one repayment workflow; one evaluator; exhaustive reader register; R2-2 fix; A1/A2/A3 rollout with mixed-version and rollback evidence. v1's "≤1¢ difference" claim is withdrawn (section 5.5). |
| v2.1 | this branch | Delta-review amendments (§0.1): proven release boundary with an inactive submitter and a database compatibility fence; durable recording times; fulfilling payment and payment-only boundaries for second captures; order-row serialization for issuance; `max(return, capture)` recognition with separately approved closed-period corrections; frozen allocation order and reversal by recomputation; operation IDs; executable replay; frozen payout custody for R2-2; strict holds except proven platform-only over-return. |

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

### 0.1 v2.1 amendments (delta review of `7098c31a`)

The delta review accepted the A1 writers → A2 readers order and required the changes below. The lead accepted all of them, with two settings: strict payout holds stay the default except for proven platform-only over-return, and ordinary recognition stays `max(return, capture)`. No mutation of historical production data is authorized.

| Delta point | v2.1 change | Section | Tests |
| --- | --- | --- | --- |
| **A1-1** Old submitters, release proof, operation lifecycle | A1 ships as two releases. R1 adds writers and a database compatibility fence, and leaves the new submitter inactive. R2 activates the submitter only after the release-boundary evidence, or after the fence plus adjudication. Each refund operation gets a persisted ID, an exact reservation, a self-excluding in-flight check at submission, one sender, and new-operation semantics after success or a verified terminal failure. `refund_disputed_payment` clears only when the matching dispute is reconciled | §6.3, §10.1, §10.5 | R-13…R-17, M-05…M-08 |
| **A1-2** Classified payment isolation, fulfilling payment, issuance serialization | `orders.fulfilled_by_payment_id` (same-order FK, set once at completion). Legacy ownership comes only from positive completion evidence; ambiguous ownership is quarantined. A second capture (payment scope) gets a payment-only path with no sale, commission, ticket, inventory or admission effects and is excluded from the fulfilled payment's refund limits and dispute checks. Ticket issuance and order-scope classification serialize on the order row and each recheck the other after locking. The ticket trigger covers insert, reactivation and reassignment, including pass children, without a ticket → order wait. `ticket_fulfilled?` reads the marker. The legacy exception guard on expired door reopening stays | §4.1–§4.3 | C-01…C-20, X-08…X-10 |
| **A1-3** Recognition versus corrections; reversal allocation | `recognized_at = GREATEST(return_recorded_at, capture_recorded_at)`, without the v2 posting-month floor. Discoveries that touch an explicitly closed period become a separately approved, audited current-period correction that keeps both original times. Recording times are database-stamped, set-once columns, never `payments.succeeded_at`. Allocation follows a frozen processing order with a stable tie-break. A reversal recomputes the surviving facts in that order and appends the signed delta | §2, §5.3, §5.4, §5.6 | L-17…L-24 |
| **A1-4** Executable replay and backfill | A receipt-locked replay entry point that reuses the stored payload, verifies the bound payment, and is idempotent per provider movement. Unreplayed evidence is checked at the submission gate. Replay triggers on binding or on capture recording. Positively matched legacy movements are accepted; ambiguous ownership, amounts or timing are quarantined; restating rows are not written. The release plan uses read-only counts and an authorized disposition, never `CONFIRM_RESTATEMENT` or a recurring job | §4.5, §7.2 | E-11…E-15, C-10…C-14 |
| **A2-1** R2-2 durable payout custody | A frozen, append-only custody determination per payout, written at paid recording time or derived once from the payout's finalized settlement and verified qualifying payment evidence. Ambiguous history keeps its published result until an explicit finance correction | §8.6 | F-19…F-24 |
| **A2-2** All money readers together; payout-entry enforcement | All readers switch in one release. Payout release, submission and confirmation are guarded under their existing locks. Old payout actions are fenced during the A2 overlap, and preflight evidence covers drain, reconciliation and active guards | §8.2, §8.7, §10.1, §10.5 | F-25, M-09 |
| **B/P4** | Setup mark and lease recheck under the setup locks; all expiry and cancellation sources go through one shared decision; configurable cutoff no shorter than the Session lifetime; staged and revalidated P4 intent; documented conservative choices for postponement, the paid-door extension and "proceed anyway" | §3.1–§3.4 | P-28…P-33 |

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
| P9 | Allocation of returned money between ticket proceeds, fees and tax | `Commerce::BuyerOwedLedger::ALLOCATION_POLICY`, snapshotted as `never_fulfilled_captures.allocation_policy` with `policy_version` | `:item_record` (§5.4), applied in the frozen processing order of §5.4; alternative `:cumulative_pro_rata`. They differ by **$0.75** on the §5.5 counterexample. **Gross owed, applied, excess and every repayment amount are independent of P9**; P9 only splits applied money into fee, tax and proceeds | **Working default chosen** so implementation is not blocked. **CPA sign-off is still required** and is recorded against `policy_version` before the January 2027 close. A change after sign-off is prospective (new `policy_version`) |
| P10 | Organizer payout and finalization holds for classified captures | `Commerce::NeverFulfilledCapture::PAYOUT_HOLD` | `:strict` (§8.7): the existing controls stay. Any open never-fulfilled, quarantine, unknown-outcome or second-capture exception blocks the organization's payouts and the event's finalization, including quarantined rows. **The one exception is P4:** a proven platform-only over-return opens `never_fulfilled_buyer_overpaid` without holding organizer payouts. `:unknowns_only` (v2's recommendation) is **not shipped** | **Lead decision** (v2.1). Leon may later approve `:unknowns_only`; that is a separate change |
| P11 | Return recognition time | Documented rule (§5.3) | `GREATEST(return_recorded_at, capture_recorded_at)` for every ordinary never-fulfilled posting, and `GREATEST(return recorded, order custody booked)` for every other CPA/BPT return bucket. A fact discovered after its period was **explicitly closed** is posted only through an approved, audited current-period correction that keeps both original times (§5.3). Calendar rollover alone never closes a period | **Lead decision; CPA** review |
| P12 | BPT payout eligibility (R2-2) | Documented rule (§8.6) | Frozen per-payout custody determination, written at paid recording time (new payouts) or derived once from the payout's finalized settlement and verified qualifying payment evidence (history). Never a live anti-join | **Default; CPA** review |
| P13 | Postponement while a payment is in flight (B2) | Documented rule (§3.3) | Postponed is **eligible**. A payment that completes during a postponement fulfils, and its tickets carry the same event-change refund rights as every other holder. Nothing is refunded automatically | **Engineering conservative default** (v2.1; reverses v2's recommendation); **Leon** may change it |
| P14 | Paid-door wait and "proceed anyway" (B1/B2) | Documented rule (§3.2, §3.3) | The single 10-minute paid-door hold extension stays (the buyer has paid; extending is less harmful than refunding). B2 ships **without** "Proceed anyway": a transition waits until every affected payment is verified closed, fulfilled or classified, or reaches the recorded hard-cap release | **Engineering conservative default**; **Leon** may approve an explicit override later |

---

## 2. Terms

- **Capture recorded time** (*t₀*): `payments.capture_recorded_at`. A database trigger stamps it with `clock_timestamp()` in the statement that first moves a payment into a captured status (`succeeded`, `partially_refunded`, `refunded`), whether it is inserted that way or updated. It is set once and cannot be cleared or changed, and it cannot be written on a non-captured payment. The trigger also stamps it for 7bcd97c2 code, which never names the column. `payments.succeeded_at` stays the legacy business field and is **never recording evidence**: `StripeWebhookProcessor#backfill_legacy_payment` writes `order.completed_at` into it, and existing operational specs rewrite it. Captures recorded before A1 have a NULL `capture_recorded_at`. Their time is derived once from positive evidence, bounded by the A1 cutover (`financial_cutovers` key `a1_capture_recording`, written by the A1 migration), and frozen on the classification row with `provenance = backfill` (§4.5). It is never recomputed from a lookup that a later audit could change.
- **Fulfilling payment**: `orders.fulfilled_by_payment_id`. The completion transaction sets it once to the verified payment passed to `OrderLifecycle.complete!` (the one that passed `provider_matches?`). Free orders leave it NULL. For a legacy completed order (NULL), it is derived only from positive completion evidence, namely the `order.completed` audit's `metadata.payment_id` naming a captured payment on the same order. It is **never** inferred from the earliest capture. Where there is no such evidence, ownership is ambiguous and the second capture is quarantined.
- **Classified payment**: a payment with a `never_fulfilled_captures` row. **Order scope**: no capture on the order fulfilled it; the row sets the order marker. **Payment scope**: a distinct second capture on an order fulfilled by another payment; the order stays fulfilled and unmarked. **Classified order**: an order whose `never_fulfilled_at` is set, which the database derives from its first order-scope row.
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
| No `provider_payment_id` and **no** `setup_attempted_at` | The committed setup mark (`OrderCreator#create_provider_payment!` writes it before any POST), **re-read under the same locks setup takes** (order → payment), together with the setup lease | `closed_verified` only if, under those locks, there is still no ID, no mark and no live lease. The ID can stay NULL while a POST begins, so a mark or lease seen under the lock means `unknown` | No Stripe request was ever sent, so nothing can charge |
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
| No Session ID, no setup mark | Re-read under order → payment. Today door `claim_setup!` locks only the payment; B1 changes it to take order → payment so the recheck and the claim serialize | `closed_verified` only if, under those locks, there is still no mark and no live lease | — |

**One shared decision for every release source (B1).** Checkout setup and recovery expiry (`OrderCreator`, `PaymentRecovery`), buyer cancellation (`OrderLifecycle.cancel!`), seat expiry (`ExpireSeatHoldsJob`), and both door expiry sources (the expiry job and the signed `checkout.session.expired` webhook) go through `ProviderRelease.decide` and `release_verified!`. Free, cash and simulated completions keep their existing in-transaction lock reuse (`event_context_locked: true`). They never call Stripe and need no decision.

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
5. **Door paid wait (P14).** On `paid_awaiting_signed_event`, the job extends the order's holds once, under locks, by `DOOR_PAID_WEBHOOK_WAIT = 10.minutes` and audits the extension; the buyer has paid. If no signed event is processed by then, `ProviderEvidenceReplay` lists the intent's `payment_intent.succeeded` events through the API and processes the match through the same `process_door_success!` path. If that also fails, it alerts staff ("Paid at Stripe, not yet confirmed here").
6. **Implicit lapse.** If the job itself stalls, `InventoryHold.current` stops counting at `expires_at`. That is safe from overselling, because every late completion rechecks capacity under locks (`late_capacity_available?`), but it is unrecorded. Monitoring alerts when an `active` hold is more than 2 minutes past `expires_at` (job stalled).
7. **Rehearsal with the real queue shape.** The 2- and 3-minute grace, the implicit lapse and the paid-door webhook delay are rehearsed with the deployed queue shape (one embedded Solid Queue job thread, `config/queue.yml`), not with a parallel test queue (§10.4 step 6).

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
2. **Stage the intent, then drain (outside locks).** The gate row also stores the staged intent: action, the staff-confirmed refund preview digest, and the eligible-night set the change would leave for each affected pass. Nothing irreversible happens while staff can still abort or reject a changed preview. In particular, **no refund is submitted and no capture is classified because of the gate**. List the affected pending orders: orders on the event, and pass orders whose included nights would *all* be ineligible after the change. A sibling night is **eligible** if it is `published`, not gated, and not itself being cancelled by this transition. **Pass orders that still have an eligible sibling night are not drained.** Their completion issues children only for eligible nights (`Passes::Issuance#resolve_included_events`). Run `ProviderRelease.decide` on each. `closed_verified` orders release. `paid_verified` and `paid_awaiting_signed_event` orders **stay held** (holds counted, order pending) while the decision is reversible. They are neither fulfilled nor classified during the drain. `unknown` orders keep the transition waiting, and staff see "2 payments are still confirming with Stripe". There is no "Proceed anyway" (P14). An unknown order leaves the wait only through the recorded hard-cap release (`release_unknown!`, §3.2).
3. **Final transition under the documented locks.** `EventLifecycle` takes organization → event (and linked pass orders → child tickets as today). It rechecks the gate token and the staged intent, and rechecks that every affected order is released (verified or `released_unknown`) or held as paid. It recomputes `EventCancellationRefunds.preview` against the staged digest (existing count and total check) and commits. **After the commit**, the held paid orders complete through the ordinary path from outside any transaction. The eligibility recheck then classifies them as never-fulfilled (`event_not_eligible`) or fulfils them for an eligible night. Paid-awaiting-signed-event orders do the same when their signed event arrives (or through `ProviderEvidenceReplay`). Abandoning clears the gate and the staged intent with an audit entry, and the held paid orders complete normally.
4. **Postponement (P13).** A postponed event stays eligible. Payments in flight complete and fulfil, and their tickets carry the existing event-change refund rights. A postponement drains nothing. B2 also changes `EventLifecycle`'s organization lock from `with_lock` (`FOR UPDATE`) to `FOR NO KEY UPDATE`, removing the EVENT → audit-FK `KEY SHARE` cycle listed in STATUS.md's lock-order follow-up (LOCKING rank 1 already prescribes this mode for other money writers).

**Ordinary completion and eligibility (B1).** Every success path calls `OrderLifecycle.complete!` from outside any transaction, so it acquires the full event context itself, including the claimed-offer organization prefix (`lock_event_context!`). The one exception, `process_door_success!`, already owns the context and passes `event_context_locked: true`. Under those locks `complete_with_audit!` separates:

- **still-owned holds** (`active`, `expires_at > now`): fulfil if the event is eligible;
- **lapsed holds**: today's `late_capacity_available?` check;
- **event eligibility**, checked in both cases: the order's event is `published`, has no transition gate, and for passes still has an eligible night; door orders also need admission to be open. **Ineligible → release and classify as never-fulfilled in the same transaction.** No tickets, no confirmation email and no fulfil-then-refund. Today a still-owned hold on a cancelled or postponed event fulfils (`order_lifecycle.rb:126` checks only `lapsed`).

v2 recommended treating `postponed` as ineligible. v2.1 withdraws that in favour of P13: refunding is irreversible and treats an in-flight buyer differently from every existing holder of the same event.

### 3.4 Door link cutoff (P6)

`OnlineDoorSale.call` refuses to open a door-card link when `admission end − now < LINK_CUTOFF_BEFORE_ADMISSION_END` (35 min), with the message "Take card-present or cash for the last 35 minutes of admission." This mirrors the existing guard in `claim_setup!` (`expires_at < 31.minutes.from_now`). The cutoff is a code constant, not an environment setting. A boot-time assertion and a spec require it to be **no shorter than** the actual Session lifetime (`OrderCreator::ONLINE_DOOR_HOLD_DURATION`, which also sets the Session's `expires_at`), so no link can outlive admission.

### 3.5 Not in scope

Manual capture (authorize, then capture under HåfaPass locks) strengthens the invariant, but it needs a durable authorization → capture-pending → completion flow, handling for authorization expiry and unknown capture results, and its own webhook reconciliation. **Not for Copa.** Revisit after launch if the monitored frequency (§8.9) justifies it ([Place a hold](https://docs.stripe.com/payments/place-a-hold-on-a-payment-method)).

---

## 4. Durable classification (PR A1)

### 4.1 Schema (A1 tranche 1, implemented)

**`never_fulfilled_captures`** (model `UnfulfilledCapture`; `Commerce::NeverFulfilledCapture` remains the reader module until A3, so the model takes a different name). One row per unfulfilled captured payment. Append-only, no PII, financial 7-year retention in `config/data_retention.yml`.

| Column | Type | Rule |
| --- | --- | --- |
| `order_id`, `payment_id` | bigint, NOT NULL | Composite FK `(payment_id, order_id)` → `payments(id, order_id)`, backed by a unique index on `payments(id, order_id)` built concurrently. The database rejects a payment from another order. Plain FK `order_id` → `orders` |
| `payment_id` | | UNIQUE: one classification per payment, never overwritten |
| `capture_scope` | string | `order` (no capture on the order fulfilled it) or `payment` (a distinct second capture on an order fulfilled by another payment). Named `capture_scope` because `scope` collides with Active Record's vocabulary |
| `code` | string | CHECK: one of `LateCaptureRefund::CODES`, `unfulfilled_second_capture`, `event_not_eligible` |
| `captured_cents`, `currency` | | Equal to the payment's `amount_cents` and currency (insert trigger); `captured_cents > 0` |
| `proceeds_cents`, `fee_cents`, `organizer_fee_cents`, `tax_cents` | integer | Component snapshot K, each ≥ 0, CHECK sum = `captured_cents`. Payment scope: CHECK fee = organizer fee = tax = 0, so the whole amount is buyer principal in the first slot. The writer (tranche 2) derives order-scope K from the order items and quarantines a mismatch rather than inserting it |
| `capture_recorded_at` | timestamptz, NOT NULL | *t₀*. The insert trigger copies it from `payments.capture_recorded_at` and rejects any other value. If the payment predates A1 (NULL), the row needs `provenance = backfill`, an explicit value no later than the A1 cutover, and non-empty evidence |
| `processing_bearer`, `dispute_fee_bearer` | string | `platform` or `organizer`; snapshots of P1 and P5 |
| `allocation_policy`, `policy_version` | string | `item_record` or `cumulative_pro_rata`, plus the policy version that CPA sign-off refers to (P9) |
| `provenance` | string | `lifecycle` or `backfill` |
| `provenance_evidence` | jsonb | Exception, webhook receipt and audit IDs; CHECK non-empty for `backfill` |
| `created_at` | timestamptz | Default `clock_timestamp()`; no `updated_at` (append-only) |

**`orders`**: `never_fulfilled_at` (derived by the database from the first order-scope row's `created_at`) and `fulfilled_by_payment_id`. A composite FK `(fulfilled_by_payment_id, id)` → `payments(id, order_id)` keeps the fulfilling payment on the same order. It is added `NOT VALID` and validated in a separate migration, like both CHECKs below.

**`payments.capture_recorded_at`**: database-stamped recording time (§2).

**`financial_cutovers`**: append-only `(key, recorded_at)`. The A1 migration writes `a1_capture_recording` in the same transaction that installs the payment trigger. `CREATE TRIGGER` holds `SHARE ROW EXCLUSIVE` on `payments` until that transaction commits, so every capture with a NULL `capture_recorded_at` was recorded before this time. A2 bounds every legacy timing fallback by it, so a later audit cannot move a pre-A1 capture between periods. Databases built with `schema:load` have no row; specs that need one insert it.

### 4.2 Database enforcement (A1 tranche 1, implemented)

`schema.rb` carries the triggers. `config/initializers/audit_log_schema_dump.rb` prepends `AuditLogIntegrity::SchemaDump` and `FinancialIntegrity::SchemaDump` (`lib/financial_integrity.rb`). Each module appends its executable DDL to the dump, but only when its sentinel trigger exists in the dumped database, so `db:schema:load` and `test:prepare` reinstall every trigger. #235's schema round-trip CI step fails on drift.

| Guard | Mechanism | Rejects |
| --- | --- | --- |
| Capture recording time | `payments_capture_recorded_at` BEFORE INSERT OR UPDATE OF `status`, `capture_recorded_at` | Changing or clearing a set value; writing it on a non-captured payment; writing it later on a payment that was already captured before A1. It stamps `clock_timestamp()` when a payment first enters a captured status |
| Classification ownership | `never_fulfilled_captures_check` BEFORE INSERT | Another order's payment (also the composite FK); a non-captured payment; an amount or currency different from the payment's; a `capture_recorded_at` that differs from the payment's; order scope on an order that is pending, completed, has `completed_at`, has a fulfilling payment, has an `order.completed` audit, or has any non-cancelled ticket; payment scope without a fulfilling payment, or on the fulfilling payment itself |
| Append-only classification | `never_fulfilled_captures_append_only` BEFORE UPDATE OR DELETE, and a TRUNCATE trigger that yields only to the synthetic-purge opt-in (`hafapass.audit_truncate`) | Clearing, editing or deleting a classification |
| Derived order marker | `never_fulfilled_captures_mark_order` AFTER INSERT sets `orders.never_fulfilled_at` for order scope; `orders_fulfillment_guard` BEFORE INSERT OR UPDATE OF `never_fulfilled_at`, `fulfilled_by_payment_id` | Changing or clearing the marker; setting it to anything other than an order-scope row's `created_at`; either column on INSERT. The marker and its rows always agree |
| Fulfilling payment | `orders_fulfillment_guard`, composite FK | Changing a set value; another order's payment; a non-captured or classified payment; an order that is not completed, refunded or partially refunded; an order with an order-scope classification |
| Never completed | CHECK `orders_never_fulfilled_not_completed`: `never_fulfilled_at IS NULL OR (completed_at IS NULL AND status NOT IN (pending, completed))`; CHECK `orders_fulfilled_xor_never_fulfilled` | Completing or reopening a classified order; an order both fulfilled and never-fulfilled |
| Ticket issuance | `tickets_issuance_guard` BEFORE INSERT OR UPDATE OF `order_id`, `status` | Any non-cancelled ticket on an order with an order-scope classification, whether by insert (`OrderLifecycle#issue_tickets!`, `Passes::Issuance` children, raw SQL), reactivation (`cancelled` → active) or reassignment (`order_id` change) |
| Append-only cutover | `financial_cutovers_append_only` | Editing or deleting the cutover time |

Model callbacks give fast feedback (`UnfulfilledCapture#readonly?`, `Payment` `attr_readonly :capture_recorded_at`). **The triggers are the guarantee**: `update_columns`, `update_all` and raw SQL all fail with SQLSTATE 23514, 23503 or 55P03 (C-02).

**Order-row serialization (A1-2).** Issuance and order-scope classification meet on the order row, and each rechecks the other after it holds its lock. Each trigger takes its lock in one statement and reads in the next. In READ COMMITTED, a PL/pgSQL statement takes a fresh snapshot, so the read after a lock wait sees the other transaction's commit.

- *Classification* takes the order `FOR UPDATE`, then the payment `FOR SHARE`, then checks for non-cancelled tickets. Lifecycle callers already hold event context → order (`FOR UPDATE`) → payment, so this re-acquires owned locks. A raw insert takes them in the same order (rank 3).
- *Ticket insert* takes the order `FOR KEY SHARE`, then checks the marker and the order-scope rows. `KEY SHARE` is the lock the ticket's own `order_id` foreign key already takes, taken earlier. It conflicts only with `FOR UPDATE`, so it adds no new conflict with existing lock modes. Every existing issuer already holds the order, so it re-acquires. A new row is invisible to other transactions, so nobody can be waiting on it, and waiting for the order here cannot create a ticket → order cycle.
- *Reactivation or reassignment* (an existing ticket row, already locked by the UPDATE) takes the order `FOR KEY SHARE NOWAIT`. A caller following the ticket entry prefix (`Ticket#with_entry_lock`: organization → event → order → ticket) already holds the order, and its own locks never conflict, so NOWAIT never fires for it. A caller that skipped the prefix fails at once with 55P03 instead of waiting while it holds the ticket. **No path waits for an order while holding a ticket.**
- Both orders of the race are covered: if the ticket commits first, classification's lock waits and then sees the ticket; if classification commits first, the ticket's lock waits and then sees the row (X-08, X-09).

A pass child ticket is created on its parent's order (`order.tickets.create!` in `Passes::Issuance`). The guard on that `order_id` therefore covers children issued at completion, by `sync_pass_holders`, or raw. An active parent ticket also blocks order-scope classification of its order.

The documented lock prefix is unchanged (LOCKING.md ranks 1–3a). Existing legitimate flows (completion, pass sync, cancellation, check-in, transfer, retention anonymization) either hold the order first or never activate a ticket, and retention's `update_all` on orders and payments never names a guarded column.

### 4.3 Writers and issuance boundaries

`Commerce::NeverFulfilledCapture.classify!(order:, payment:, code:, provenance:)` (tranche 2) runs only inside a transaction that already holds the lifecycle locks (event context → order → payment). It inserts the capture row, and the database sets `orders.never_fulfilled_at` for order scope. It then posts every movement already recorded on the payment (§5.2) and calls the evaluator (§7). Callers:

| Boundary | Code today | v2.1 |
| --- | --- | --- |
| Capture after the order left `pending` | `order_lifecycle.rb:70–86` | `classify!(code: late_payment_success_after_inventory_release)` replaces the bare exception; the exception is still written (admin queue) |
| All pass nights cancelled | `order_lifecycle.rb:106–120` | `classify!(code: pass_all_included_nights_cancelled)` |
| Unusable, lapsed without capacity, admission ended | `order_lifecycle.rb:126–141` | `classify!(code: late_payment_success_after_hold_expiry)` |
| Event not eligible with owned holds (§3.3) | new | `classify!(code: event_not_eligible)` |
| **Completion** | `order_lifecycle.rb:167` | Sets `fulfilled_by_payment_id` to the verified payment in the same `update!` that completes the order (**implemented in tranche 1**) |
| **Distinct second capture** on a completed, partially refunded or refunded order | `order_lifecycle.rb:63–66` silently calls `mark_payment_succeeded!` | If `order.fulfilled_by_payment_id` is set and differs from the payment: `classify!(capture_scope: payment, code: unfulfilled_second_capture)`. If it is NULL (legacy), derive it **only** from positive completion evidence (`order.completed` audit `metadata.payment_id`, a captured payment on the same order), set it, then classify. Otherwise open `never_fulfilled_ownership_ambiguous` (blocks payouts under P10) and classify nothing. The earliest capture is never assumed. The order marker stays unset |
| Distinct second capture on an already-classified order | the same branch | A second order-scope row for the new payment; `never_fulfilled_at` keeps the first time. Readers exclude per payment, so the second capture is never hidden by the first marker |
| Duplicate notice for the same payment | — | The unique `payment_id` makes it a no-op; `classify!` returns the existing row |
| Rebooking | — | A buyer who still wants tickets buys a **new order**. A classified order is never converted (CHECK) |

**Payment-only boundaries for a payment-scope capture (tranche 2).** Payment B on an order fulfilled by payment A must never act on A's sale. Today it can: B's refund counts toward the order-wide refunded total, can mark the order refunded, reverse commissions and release A's tickets (`refund_creator.rb:563` finalization); a lost dispute on B cancels A's tickets (`stripe_webhook_processor.rb:528`); an open or lost dispute on B blocks admission (`Order#ticket_access_blocked?`, `order.rb:102`). Tranche 2 adds:

- **Payment-only refund finalization.** A refund on a payment-scope capture finalizes the refund and its posting only. It changes no order status, `RefundItem`, ticket, inventory, promo, waitlist or commission row, and sends no ticket-cancellation email. It never enters the order-wide refund code: the existing `RefundCreator` item and ticket paths refuse a payment-scope payment.
- **Limits and disputes per payment.** A's refundable balance, `full_refund_pending?`, `refunded_cents` and dispute checks exclude B's refunds and disputes. B's limits come from B's ledger (§6). `ticket_access_blocked?` and the dispute ticket cancellation consider only disputes on the fulfilling payment (or on any payment for a legacy order with no fulfilling payment, which is today's behaviour).
- **Processing.** `StripeProcessingFees` today rejects a second actual component on the same order even though its metadata records the payment. The writer is amended to key actual processing by payment, so B's processing is recorded against B and attributed by verified payment evidence. A cost that cannot be mapped to a payment is quarantined (`processing_fee_unattributed`), never charged to A's organizer.

**Marker in fulfilment predicates (tranche 1, implemented).** `Order#ticket_fulfilled?` returns false whenever `never_fulfilled_at` is set, so a classified order that is `partially_refunded` cannot satisfy it.

**Expired door reopening.** `reopen_expired` (`order_lifecycle.rb:68`) keeps its legacy check ("no late-capture exception exists") until old writers are gone and their rows are reconciled (A3). Tranche 2 adds "the payment is not classified" to that check. The CHECK constraint already rejects completing a classified order.

**Capture-side posting and evaluation reuse held locks.** Ordinary completion starts at the event (no organization lock without a claimed offer). So `classify!`, posting and evaluation on the capture side run on the locks the lifecycle already holds and never call an organization-first writer. Where posting needs the organization prefix (the refund and dispute writers), it is taken **before** the event, by the caller that starts the transaction: `RefundCreator` and dispute finalization already do this. A capture-side path that would need it defers the work to an after-commit job that starts at the organization.

### 4.4 Readers

`Commerce::NeverFulfilledCapture` becomes a thin reader. `order_sql` becomes `orders.never_fulfilled_at IS NOT NULL`, and `payment_sql` becomes `EXISTS (… never_fulfilled_captures WHERE payment_id = payments.id)`. A3 removes `EVIDENCE_WINDOW_SECONDS` and the exception join. Provider qualification stays per reader through one shared scope, `Payment.live_agent_capture`, which replaces CPA's `LIVE_AGENT_CAPTURE_SQL` and `TaxReports#bpt_event_rows`'s inline filter (the minor finding). This also closes deferred Clover residual 5.

### 4.5 Existing rows: positive provenance, recheck, quarantine

`Commerce::NeverFulfilledReconcile` (tranche 3) is idempotent and runs in two places. R1 code calls it for one payment after commit whenever that payment's capture, exception, refund or dispute is recorded. This picks up rows an old worker wrote during the overlap. The `never_fulfilled:reconcile` rake task runs it over all candidates, `DRY_RUN=1` by default. **A recurring job is not part of the release plan.** The release gate uses read-only counts (§10.5).

A candidate is classified **only** with positive lifecycle provenance. It needs **all** of:

1. A captured Stripe payment whose `amount_cents == orders.total_cents` and whose currency matches.
2. A `LateCaptureRefund::CODES` exception linked to that payment and order, created at or after the payment's recording evidence and within 5 seconds of it. A matching exception within a time window is **not enough on its own**; points 3–5 are also required.
3. An `order.expired` or `order.cancelled` audit (or, for `pass_all_included_nights_cancelled`, the release audit with that reason) whose `created_at` is not after the exception.
4. No tickets other than `cancelled`, no `order.completed` audit, no consumed inventory, catalog or seat holds, no `promo_redemptions` in `finalized`, and no `promoter_commission_entries` of kind `earned`.
5. Either a refund with key `late-capture:payment:<id>` (the lifecycle enqueued the job), or the exception's `webhook_event_id` pointing at a `payment_intent.succeeded` receipt for this payment.

For a pre-A1 capture, `capture_recorded_at` on the new row is the earliest of the immutable evidence times in points 2, 3 and 5 that exist **at or before** the A1 cutover. It is written once with that evidence and never recomputed.

**Movements already recorded (v2's §4.5 contradiction resolved).** A legacy refund or lost dispute does not by itself cause quarantine. A movement is **accepted and posted** when it is positively matched: same payment (refund `payment_id`, or a dispute whose charge maps to the payment's intent), an amount within the captured amount, a provider ID, and a recording time after the capture evidence. Ownership, amounts or timing that cannot be matched that way are **quarantined**.

The task re-reads each candidate under the lifecycle locks before writing (C-13).

**Dispositions.**

| Case | Disposition (authorized now) | Effect |
| --- | --- | --- |
| Positive provenance, matched movements, no closed period or finalized settlement affected | Classify with `provenance: backfill` and the evidence IDs; post the matched movements | Normal |
| Any proof missing, ambiguous ownership (including a second capture with no fulfilling-payment evidence), unmatched movement, or linked adjustment | Open `never_fulfilled_backfill_ambiguous`, write no classification | Blocks the organization's payouts and the event's finalization (P10 strict). Excluded from organizer custody **and** from automatic repayment until verified. Finance resolves each one with an audited action: classify with a note, or "fulfilled, not a never-fulfilled capture" |
| Classification would restate a finalized settlement, a paid payout, or an explicitly closed CPA period | **Write nothing.** Open `never_fulfilled_backfill_restatement` listing the affected settlement, payout and period | The published results stand. Payouts on the event stay blocked. Correcting history needs its own approved, audited correction (§5.3), which is not part of A1 |

There is no `CONFIRM_RESTATEMENT` switch. No historical production data is changed. Reconcile only inserts new append-only classification, posting and exception rows, through the application's own guarded writers. Any restatement or write-off needs its own disposition.

### 4.6 Tranche 2 as built, scope boundaries and amendments

This records what tranche 2 implements, where it narrows or amends §4.3, and what tranches 3 and 4 must pick up. Nothing here changes a migration, a trigger, a permission or a finance reader other than item 9.

1. **Writer and evidence.** `Commerce::NeverFulfilledClassification.classify!` (also reachable as `Commerce::NeverFulfilledCapture.classify!`) runs inside the lifecycle transaction on the locks `OrderLifecycle` already holds. It inserts a row only for a real Stripe `test`/`live` payment (no `sim_` ID, not simulated) whose exact amount and currency came from one of two sources: a stored `payment_intent.succeeded` receipt whose object is that PaymentIntent (`source: signed_webhook`), or the authenticated retrieve that `OrderLifecycle.expire!` and `PaymentRecovery` already make (`source: provider_lookup`, intent ID and `livemode` checked). That evidence, the late-capture exception ID and the release audit ID go into `provenance_evidence`. The row copies `payments.capture_recorded_at`. A repeat notice returns the existing row. **Amendment:** `complete!` gains `provider_lookup:` so the lookup path can prove identity. `complete!` called without a receipt or lookup proves nothing and classifies nothing.
2. **Quarantine, not guess.** When any proof is missing (no provider amount, wrong mode, a different object, components that do not add up, a capture recorded before A1, an order with completion evidence or active tickets), the writer inserts nothing. It opens one `never_fulfilled_classification_quarantined` exception per payment, with `details.reason`. That code is deliberately **not** in `RefundSafety::FINANCIAL_CODES`, so the existing automatic late-capture refund is unchanged. Like every open exception, it holds payouts and finalization (P10). Captures recorded before A1 (`capture_recorded_before_a1`) are left for tranche 3's backfill. Non-Stripe providers (Clover is not live) and simulated payments keep only their existing late-capture records.
3. **Components (closes the §11 obligation).** `OrderCreator#create_ledger!` writes each ticket line as `organizer_proceeds = max(subtotal − discount − organizer_fee, 0)`, `fee = buyer_fee`, `organizer_fee`, `tax = 0`, and catalog lines as `proceeds = subtotal` with zero fees. It writes the order as `total = max(subtotal + buyer_fees − discount, 0)`. So Σ components = `total_cents` exactly when no ticket line clamps. The bridging term is Σ over clamped lines of `discount + organizer_fee − subtotal`. That happens only when a line's discount plus organizer fee exceeds its subtotal. The writer compares Σ components to the captured amount and quarantines `components_mismatch` rather than inserting.
4. **Boundaries.** Capture after release, all pass nights cancelled, and lapsed, unusable or admission-ended holds: order scope with the exception's code, plus the unchanged exception and `LateCaptureRefundJob`. Expired door reopening now also requires "the payment is not classified". **Amendment:** a distinct capture on an already classified order (status `refunded`/`partially_refunded`, which previously took the silent fulfilled-order branch) gets the ordinary late-capture exception and a second order-scope row, but **no refund job**. The order-wide path would cap it by the first payment's balance, so its repayment waits for tranche 4's per-payment operations. On a classified order that is still `cancelled`/`expired`, a distinct capture keeps today's behaviour (exception, row and job).
5. **Second capture on a fulfilled order.** Payment scope is keyed by `orders.fulfilled_by_payment_id`. On a legacy order (column NULL), the writer sets it **only** when the `order.completed` audit (`order:<id>:completed`) names a captured, unclassified payment on the same order, and records `order.fulfilling_payment_recovered`. If the audit names the notified payment itself, that payment is recorded as the fulfilling one and nothing is classified. A repeat notice of a legacy order's only, already captured payment is not a second capture. Any other case opens `never_fulfilled_ownership_ambiguous` and classifies nothing. A classified second capture also opens `unfulfilled_second_capture` (admin queue; holds payouts under P10). No refund is enqueued, because §4.3 already made it so.
6. **Payment-only refunds.** `RefundCreator` refuses every **outbound** refund for a payment-scope payment (`ISOLATED_PAYMENT_MESSAGE`), including ticket selections. It always records an **inbound** provider refund for it (webhook or `ExternalRefundRecovery`), whatever the sale's status, limited by that payment's own balance. Finalization changes only the refund and the payment's refund status, audits it, and asks for the payment's fee-adjustment review. There is no order status or refund total, `RefundItem`, ticket, inventory, promo, waitlist or commission change, and no buyer email. The sale's limits, its default payment choice, `Order#refunded_cents`/`refundable_cents`/`full_refund_pending?`, and the admin, organizer, event-cancellation and manual-return balances all exclude the isolated payment's capture, refunds and disputes. **Temporary restriction until R2:** HåfaPass never repays a payment-scope capture. A refund made in the Stripe Dashboard is recorded. `unfulfilled_second_capture` stays open, so payouts on the organization stay held.
7. **Disputes and admission.** A lost dispute on an isolated payment never cancels the sale's tickets. `Order#ticket_access_blocked?` ignores disputes on payment-scope payments. **Amendment (conservative):** v2.1 says "consider only disputes on the fulfilling payment". Tranche 2 excludes only *classified* payment-scope payments, so a dispute on a quarantined, unclassified second capture still blocks admission until finance resolves it. Legacy orders with no fulfilling payment keep the order-wide rule.
8. **Processing (amendment).** §4.3 says the writer keys actual processing by payment, so B's cost is recorded against B. But main's readers (`Settlements::Calculator`, `CpaMonthlyReport`, `TaxReports`, `PlatformRevenue`) attribute every order-level processing `FeeComponent` to the fulfilled sale. So tranche 2 verifies B's facts as usual and stores them on B's own `stripe_fee_evidences` row as `review_required` with `last_error_code = payment_scope_processing_deferred`. It writes **no** `FeeComponent` and opens the review exception. `missing_count` keeps counting it, so settlement and payout stay held until A2 attributes the cost per payment. The existing strict check (an unmapped order-level component blocks a new one) is unchanged for every unclassified payment.
9. **One narrow reader change.** `Settlements::Calculator` (statement, payout balance) excludes refunds and lost disputes on payment-scope payments. Otherwise a refund of B would show as a refund of the sale, and B's lost dispute would debit the organizer. It keys on rows only this tranche writes, so no existing digest changes. CPA and BPT exports are unchanged. Their treatment of a payment-scope capture, its refunds and its lost disputes (today a lost dispute on B would appear in `chargebacks`) is an A2 obligation.
10. **Not in this tranche.** `classify!` does not yet post movements or call the evaluator; postings and recording-time triggers are tranche 3. Excluding order-scope classified orders from `EventCancellationRefunds` is tranche 4, so a partly returned never-fulfilled order can still be refunded a second time by an event cancellation (§6.2). The admin refund queue's cancellation row still shows a remaining balance that includes an isolated payment (display only). The admin UI has no labels yet for `never_fulfilled_classification_quarantined`, `never_fulfilled_ownership_ambiguous` and `unfulfilled_second_capture` (frontend follow-up).
11. **Interfaces for tranches 3–4 and A2.** `NeverFulfilledClassification::Result` (`capture`, `quarantine`); constants `QUARANTINE_CODE`, `OWNERSHIP_AMBIGUOUS_CODE`, `SECOND_CAPTURE_CODE`, `POLICY_VERSION = "nfc-v2.1"`; `NeverFulfilledCapture::DISPUTE_FEE_BEARER`/`ALLOCATION_POLICY` (P5/P9 snapshots); `UnfulfilledCapture.payment_scope`, `.isolated_payment?(id)`, `.excluding_isolated(relation, column)`; `Payment.excluding_isolated_captures`, `Refund`/`Dispute.excluding_isolated_payments`; `Order#isolated_payment_ids`, `#sale_refunds(statuses)`; `RefundCreator::ISOLATED_PAYMENT_MESSAGE`; `StripeProcessingFees::PAYMENT_SCOPE_DEFERRED_CODE`. Tranche 3's reconcile picks up quarantined and pre-A1 payments. Tranche 4's `BuyerRepayment` replaces the outbound refusal for isolated payments with per-payment operations.

Tests: `spec/requests/never_fulfilled_classification_spec.rb`, `spec/requests/payment_scope_isolation_spec.rb`, two door examples in `spec/requests/api/v1/organizer/box_office_card_sales_spec.rb`, and the two-connection races in `spec/services/commerce/never_fulfilled_classification_concurrency_spec.rb` (two verified payments on one pending order; duplicate deliveries of one released payment).

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
| `recorded_at` | The movement's own durable recording time, **database-stamped and set once** by the same trigger pattern as `payments.capture_recorded_at` (tranche 2 adds `refunds.success_recorded_at`, `disputes.loss_recorded_at` and `disputes.loss_reversal_recorded_at`). App-written `refunds.succeeded_at`, `disputes.closed_at` and audit times are evidence only for pre-A1 movements, bounded by the A1 cutover and frozen on the posting |
| `posted_at` | DB `clock_timestamp()` |
| `recognized_at` | §5.3 |
| `note` | For example "Lost dispute recorded 28 Feb 2027, before its capture was recorded; recognized 1 Mar 2027" |

**Writers** (all under organization → event → order, the existing refund and dispute prefix): `RefundCreator#finalize_observed_refund!` on `succeeded` (`refund_creator.rb:563`); `StripeWebhookProcessor#process_dispute!` on `lost`; the new late-win branch (§5.6); `classify!` for movements recorded before classification; and `never_fulfilled:reconcile` for movements recorded by an older worker during a deploy overlap.

**Processing order (frozen).** Allocation depends on order (§5.4), so the order is fixed and stored. Each posting gets `sequence` (per capture, 1, 2, …), assigned under the order lock. Facts are sequenced by `(recorded_at, kind rank, source id)` with kind rank `refund` < `dispute_loss` < reversals. That tie-break is stable for facts first posted together, for example several movements `classify!` posts at once. Readers and recomputation always use `sequence`, never `posted_at` or `id`.

### 5.3 Recognition time, everywhere

For an ordinary never-fulfilled posting (P11):

```
recognized_at = GREATEST(return_recorded_at, capture_recorded_at)
```

Both inputs are database-stamped, set-once recording times (§2, §5.2), never `payments.succeeded_at`.

- `capture_recorded_at` stops a return being recognized before its capture (code-review finding 3; "pre-capture returns under both delivery orders").
- v2 also floored recognition at the start of the Guam month the row was *posted*. **v2.1 removes that term.** At Guam midnight, a return and capture both recorded on 28 February but posted on 1 March belong to February under the requested rule; the floor silently moved them to March.

**Closed periods and corrections.** A period is closed only by an explicit, audited finance close record (`accounting_period_closes`, added in A2 with the readers). The record holds the Guam month, who closed it, when, and the export hashes. Calendar rollover alone never closes a period, and before A2 no period is closed for these postings. If a posting's `recognized_at` falls in a period that is already closed when it is posted (a backfill, a replay after binding, a provider correction), it is not recognized in the closed period. It is written with `recognition_state = pending_correction`, kept out of every bucket, and surfaced as an integrity alert. It moves into the books only through a **separately approved, audited current-period correction**: a finance action that writes `recognized_at` in the current open period and records `correction_reason`, `corrected_period` (the closed month it relates to) and both original times (`return_recorded_at`, `capture_recorded_at`). The CPA CSV labels it in `prior_period_note`, the existing pattern. The closed month stays byte-identical.

**Before every CPA and BPT bucket.** The same rule, with the reader's own custody booking time, applies to every return-like bucket, fulfilled and bridge activity included. A month therefore never shows a return before the capture it reverses:

| Reader | Bucket | Recognition |
| --- | --- | --- |
| `CpaMonthlyReport` | `buyer_refunds_paid`, gross buyer columns, `fee_refunds` (classified) | `buyer_return_postings.recognized_at` (recognized postings only) |
| | `proceeds_refunded`, `fee_refunds` (fulfilled) | `GREATEST(refund recording time, order custody booked)` |
| | `chargebacks` | `GREATEST(dispute loss recording time, order custody booked)` |
| | `organizer_processing_deducted`, `stripe_processing_costs_informational` | `GREATEST(fee_components.created_at, order custody booked or capture_recorded_at)` |
| | `non_custodial_settlement_bridge` refunds, processing, disputes | `GREATEST(movement recording time, the bridge order's booking time)` |
| `TaxReports#bpt_event_rows` | `returned_fees` | as CPA `fee_refunds` (shared SQL helper `Commerce::RecognitionTime`) |
| `TaxReports#months`, `#organizers` | `fees_refunded_cents`, refunds | same helper |

"Order custody booked" and every "recording time" are durable inputs. Post-A1 facts use the database-stamped columns. Pre-A1 facts use today's expressions (`ORDER_CUSTODIAL_AT_SQL`, `DISPUTE_LOST_AT_SQL`), with every audit-based fallback restricted to audit rows created **before the A1 cutover**. A later audit row therefore cannot replace a fallback and move a pre-A1 fact between periods. A2's rollout evidence (§10.5) lists any closed-month row the rule would move; such a row is handled as a correction, never rewritten.

### 5.4 Allocation policy and proof

**Inputs.** The capture's component vector **K** = (proceeds, fee, organizer_fee, tax) from the capture row. Validate `ΣK = C` at classification; a mismatch quarantines. For `payment`-scope captures (a second payment on a fulfilled order), **K** = (C, 0, 0, 0): no fee or tax was earned on that payment, so the whole amount is buyer principal, carried in the first slot. Readers never treat it as organizer proceeds (§8).

**Applied amount for movement k** (positive *gross*): `aₖ = min(grossₖ, C − Aₖ₋₁)`, with excess `xₖ = grossₖ − aₖ`, where `Aₖ₋₁` = Σ previous `applied_cents`. Excess is decided on **gross** against C alone (code-review findings 2a and 2b).

**Component allocation of `aₖ`** under `:item_record` (default, P9):

1. **Refund, fully applied (`aₖ = grossₖ`), with `RefundItem` rows that fit the remaining components:** use the refund's own `RefundItem` split. In A1, `RefundCreator#allocate_items!` for a classified payment allocates against the **ledger's remaining components** (**K** − Σ previous postings) instead of refund-only remainders (`refund_creator.rb:630`, which ignores lost disputes). This keeps `RefundItem` rows and postings identical.
2. **Lost dispute, partly applied refund, or an older refund whose items don't fit:** `Commerce::BoundedAllocator.call(aₖ, remaining)`. It computes `MoneyAllocator`'s floors and hands out remainder cents in the same index order, **skipping any component already at its remaining balance**. It equals `MoneyAllocator` whenever `MoneyAllocator` stays within bounds. Plain `MoneyAllocator` can give a remainder cent to a zero-weight component (weights `[0, 1, 1]`, total 1 puts 1¢ on index 0), so it cannot be used against remaining balances.

**Order dependence (delta review).** The allocation of a fixed sequence is exact and bounded, but it depends on the sequence. For a 10¢ capture with **K** = (6¢ proceeds, 4¢ fee): a 6¢ item refund (6,0) recorded first leaves (0,4) for a 6¢ capped loss. A loss recorded first takes (4,2) and leaves 4¢ for the refund, which takes (2,2). Both clear gross, but different facts carry the fee reversal. v2.1 therefore applies the allocation **only in the frozen processing order** (`sequence`, §5.2) and never re-sorts it.

**Reversal (negative `grossₖ`): recompute the survivors and append the signed delta.** v2 allocated a reversal over the net cumulative returned components. That can reverse the wrong share. With a 4¢ refund (4,0) and a 6¢ loss (2,4), reversing the loss over the pool (6,4) removes (4,2) and leaves (2,2), although only the (4,0) refund survives. In v2.1, a reversal (late win, finance-confirmed refund failure after success) does this under the order lock:

1. Mark the reversed fact as not surviving. The reversal posting keeps the source movement's identity (`reverses_posting_id`, `source_type`, `source_id`) plus its own source (the late-win dispute update or the finance action).
2. Recompute applied, excess and component allocations for **all surviving facts**, in their original `sequence` order, from **K**, using the same rules as at posting time (the snapshotted P9 policy and `RefundItem` fit).
3. Append one reversal posting whose `gross_cents`, `applied_cents`, `excess_cents` and components are the **signed difference** between the recomputed survivors and the cumulative posted totals. This includes promotion of money previously booked as excess. Example: loss 10¢ (applied (6,4)), then refund 4¢ (excess 4); the loss is reversed; the refund is promoted to applied (4,0), giving the signed delta applied (−2,−4) and excess −4.
4. `recognized_at` of the reversal posting is its own recording time (it is a current-period movement). Earlier postings are never rewritten.

In the example above the delta is (−2,−4), which leaves exactly the surviving refund's (4,0).

**Proof (between reversals).** Let **Rₖ** = **K** − Σᵢ₌₁ᵏ allocᵢ.

1. *Feasibility:* `aₖ ≤ C − Aₖ₋₁ = ΣRₖ₋₁`. `BoundedAllocator` returns 0 ≤ allocₖ ≤ **Rₖ₋₁** componentwise with Σ allocₖ = aₖ. The floors satisfy ⌊aR_j/ΣR⌋ ≤ R_j, and spare capacity Σ(R_j − floor_j) ≥ aₖ − Σfloor_j, so the remainder always fits. A refund's own items are used only if they fit. So **Rₖ** ≥ 0.
2. *Monotone:* allocₖ ≥ 0, so every component's cumulative return is non-decreasing, and no share moves backwards between months.
3. *Full return clears every share:* if A = C then Σ**R** = 0 with **R** ≥ 0, so **R** = 0. Proceeds returned = T exactly, fees returned = the fee share exactly.
4. *Gross identities:* `A + O = C·[t₀ < t]`, `A + X = R` (cumulative gross returned), `0 ≤ O ≤ C`.
5. *Month projection:* for Guam month [s, e), a column's value is a sum of postings with `s ≤ recognized_at < e`. Opening(M) = Σ before s, closing(M) = Σ before e, so **opening + captures − paid = closing** and **closing(M) = opening(M+1)** hold by construction. No input changes after posting.
6. *Closed periods stay closed:* a posting whose `recognized_at` would fall in an explicitly closed period is held as `pending_correction` and enters the books only through an approved current-period correction (§5.3). Its allocation depends only on earlier postings in `sequence`, which are immutable.

Across a reversal, monotonicity (2) does not hold, by design. The reversal is a current-period movement. (1) and (3)–(6) still hold, because after the reversal the cumulative totals equal a recomputation over the surviving facts, which is itself a valid fixed sequence.

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
- Classified payment: post `dispute_loss_reversal` as the recomputed signed delta (§5.4) in the current period, then run the evaluator, which may reopen repayment (§7). Tests: a late win received before the loss receipt (the loss is recorded first, then the win is applied), duplicate and stale receipts (one reversal, no double negation), and an overpaid loss later reversed (excess promoted or released exactly).
- Fulfilled order: open `dispute_late_win` for finance. The organizer-side treatment (a current-period credit) is a residual (§11); nothing is lost, because the reversal is recorded.
- A provider refund that turns `failed` after `succeeded` stays `refund_terminal_status_conflict` (existing). Only a finance-confirmed audited action posts `refund_reversal`.

### 5.7 Tranche 3 as built, compatibility choices and tranche 4 interfaces

This records what tranche 3 implements, where it narrows §4.5 and §5.2–§5.6, and what tranche 4 and A2 must pick up. No finance reader changes. Nothing is scheduled, and no historical row is updated or deleted.

1. **Schema (migration `20261126110000`).** `refunds.success_recorded_at`, `disputes.loss_recorded_at` and `disputes.loss_reversed_at` are stamped by triggers with the database clock in the statement that first records the fact. An application value is refused, and a set value cannot change. A reversal can be recorded only on a dispute that is `lost`, and the dispute then stays `lost`. The triggers also stamp facts written by 7bcd97c2 code, which never names these columns, so rows that old workers write during the overlap carry database times. The migration installs the triggers and writes `financial_cutovers` `a1_return_recording` in one transaction. Any movement left with a NULL time therefore predates that cutover. `buyer_return_postings` follows §5.2. Its source is `(source_type, source_id)`, unique per kind. It keeps `reverses_posting_id`, `recorded_at` and its `recording_source` (`database` or `backfill`), the copied `capture_recorded_at`, and `recognized_at`, which a CHECK pins to `GREATEST(recorded_at, capture_recorded_at)`. It also keeps `recognition_state`, the P9 snapshot (`allocation_policy`, `policy_version`), `allocation_method`, `evidence` and `note`. The insert trigger locks the order (rank 3) and enforces the rest. The movement must belong to the classified payment, have the same currency and be in the right state with the same gross amount. A reversal must name the reversed loss posting. `sequence` must be contiguous. A forward movement's applied amount must be `LEAST(gross, C − Σ applied)`. Every cumulative share must stay within **K**. A pre-A1 movement needs a `backfill` time no later than the cutover, with evidence. The table is append-only and truncation-guarded like §4.2, and the schema dump reinstalls all five triggers.
2. **Writer.** `Commerce::BuyerReturnPostings` is the only writer. It adds no lock: every caller already holds the order, and it makes no network call. Callers are `RefundCreator#finalize_observed_refund!` on success, on the sale path after `allocate_items!` and on the payment-only path, and `StripeWebhookProcessor#process_dispute!` on a loss, on a redelivered loss and on a late win. `classify!` posts every movement already recorded on the payment, on its own locks. A repeated notice for an already classified payment posts any movement still unposted, so a capture-side notice also repairs an overlap gap. Facts posted together are ordered by `(recorded_at, kind rank, source id)`, and later facts are appended. Forward allocation uses `Commerce::BuyerReturnLedger.step`. A reversal recomputes the surviving facts in their frozen sequence (`BuyerReturnLedger.recompute`) and appends the signed delta. A movement that cannot be posted from positive evidence opens one `never_fulfilled_return_quarantined` exception per source (no recording time, a currency mismatch, or a reversal whose loss cannot post). That code is in `RefundSafety::FINANCIAL_CODES`, so outbound repayment also waits.
3. **Gross evidence is never refused.** A provider refund on a classified payment (webhook or `ExternalRefundRecovery`, with no ticket selection) is recorded whatever the sale status, and even when the outbound balance or the payment's own balance is exhausted. Its posting splits applied from excess. `allocate_items!` writes `RefundItem`s only for what still fits on a classified payment's items. `orders.refund_amount_cents` is capped at the order total (an `Order` validation), and the gross amount lives in the postings.
4. **Late wins.** A signed `charge.dispute.closed` or `.updated` notice with status `won`/`warning_closed` on a dispute already `lost` records `loss_reversed_at` and the audit `dispute.loss_reversed`. It does not rewrite `status` or `closed_at`. A classified payment then posts the recomputed `dispute_loss_reversal`. A fulfilled sale opens `dispute_late_win`. Duplicate and stale notices are no-ops. A loss and its reversal recorded before classification post in order at classification.
5. **Reconcile (`Commerce::NeverFulfilledReconcile`, rake `never_fulfilled:reconcile` with `DRY_RUN=1` as the default, and the read-only `never_fulfilled:verify`).** A candidate needs a late-capture exception, so an ordinary payment is never a candidate. Classification follows §4.5 points 1–5. A pre-A1 capture's time comes from the signed receipt, or from the exception when the late-capture refund key proves the lifecycle, inside the 5-second window and before the cutover. **Narrowing:** point 3's release audit predates the capture, so it is required but never used as the capture time. Movements are accepted only if each one names the payment and has a provider ID, an amount within the capture and the same currency. Its recording time must be database-stamped, or come from its earliest `refund.succeeded`/`dispute.lost` audit before the cutover and no earlier than the capture evidence. The backdated `succeeded_at`/`closed_at` business fields stay in `evidence` only. The following are `ambiguous` and open `never_fulfilled_backfill_ambiguous`: any other captured payment on the order, an exception with neither lifecycle artifact (hand-entered), a receipt or refund key that names another payment, a movement with no payment, a missing proof, active tickets, consumed inventory, finalized promotions, earned commissions and linked adjustments. A finalized settlement or a pending, processing, paid or held payout on the event makes the case `restatement`, which opens `never_fulfilled_backfill_restatement` and writes nothing else. Either item makes later runs `held`. Writes re-assess under organization → event → order → payment. A positive classification resolves the lifecycle's superseded `capture_recorded_before_a1` quarantine and any `recording_time_unknown` posting quarantine it posted, with an audit.
6. **Temporary compatibility choices (versus §5.4 and §10).**
   - (a) `allocate_items!` is not yet ledger-aware (§5.4 rule 1). After a lost dispute, a classified refund's `RefundItem`s can claim shares the posting does not, and the posting then uses `BoundedAllocator`. A2 readers must read postings, never `RefundItem`s, for classified payments.
   - (b) `never_fulfilled_buyer_overpaid` (§6.5) is not opened yet. Every open exception blocks finalization, which would contradict P4. The excess is durable on the posting and its audit, and tranche 4 opens the exception together with the P4 payout exemption.
   - (c) `recognition_state` is always `recognized` until A2 adds `accounting_period_closes` (§5.3).
   - (d) `refund_reversal` is reserved, and the trigger refuses it until a finance correction action exists (§5.6).
   - (e) A loss notice that arrives after the dispute was recorded `won` is kept as evidence (the receipt and `dispute.loss_receipt_after_win`) and posts nothing (net zero). The status is not rewritten, so main's status-based CPA reader stays unchanged.
   - (f) Reconcile is not called automatically after commit. Under §4.5 that is the R1 per-payment hook, and wiring it is left to tranche 4 or the lead.
7. **Interfaces for tranche 4 and A2.** These are `BuyerReturnPostings.record_refund!`, `.record_dispute_loss!`, `.record_loss_reversal!`, `.record_recorded_movements!(capture, backfills:)`, `.recorded_movements(payment_id)` and `QUARANTINE_CODE`. `BuyerReturnLedger.for(capture)` gives owed, applied, excess, gross, returned and remaining components, `pending_refund_cents` and `open_dispute_cents`. "Available", operations and unreplayed evidence are tranche 4. Also `BuyerReturnLedger.step`/`.recompute`, `BoundedAllocator`, `NeverFulfilledReconcile.call(dry_run:, payment_ids:)`, `.call_for_payment`, `.candidate_payment_ids`, `.unposted_movement_payment_ids`, `AMBIGUOUS_CODE` and `RESTATEMENT_CODE`. Tranche 4's `replay!` must record the `Refund` or `Dispute` row through the normal writers (posting follows automatically), or call `record_recorded_movements!` under the order lock after binding. It must include the posting quarantine in its unreplayed-evidence gate. Tranche 4's evaluator runs after these calls in the same transaction.

Tests: `spec/models/buyer_return_posting_integrity_spec.rb`, `spec/services/commerce/buyer_return_ledger_spec.rb` (L-01, L-02, L-17, L-18, L-24, 75¢), `spec/services/commerce/buyer_return_postings_spec.rb` (E2, E3, E4, E10, E11, L-09, L-10, duplicates, late wins, promotion, reordering, quarantine, payment-scope isolation), `spec/services/commerce/buyer_return_postings_concurrency_spec.rb` (two-connection) and `spec/services/commerce/never_fulfilled_reconcile_spec.rb` (C-10…C-14).

---

## 6. One repayment workflow (PR A1)

### 6.1 Ledger quantities

`Commerce::BuyerOwedLedger.for(capture)`, read under the order lock:

| Quantity | Definition |
| --- | --- |
| **Owed** O | `C − Σ applied_cents` over postings |
| **In flight** | Σ amounts of `pending` refunds on the payment (including `provider_result_unknown` and `submission_requested`) + Σ amounts of `open` disputes on the payment + any unreplayed provider evidence for the payment (§7.2) |
| **Available to submit** | `max(O − in_flight, 0)`, and **0** if any other operation on the payment is reserved, submitting or unknown, any dispute is open, a `refund_disputed_payment` failure has no reconciled matching dispute yet, or evidence is unreplayed (§7.2). At an operation's own submission gate, its own reservation is excluded from *in flight* (§6.3) |
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

### 6.3 Repayment operations (replaces v2's attempt counter)

The v2 key `late-capture:payment:<id>:attempt:<n>` counted verified failures, so a successful $5.00 HåfaPass refund followed by a legitimate $8.60 top-up still selected attempt 1. v2.1 makes each refund operation explicit (tranche 4, built under R1 but submitting only from R2, §10.1):

- **`repayment_operations`** (append-only identity, guarded state): `id`, `unfulfilled_capture_id`, `sequence` (1, 2, …), `amount_cents`, `idempotency_key`, `state` (`reserved`, `submitting`, `succeeded`, `failed_terminal`, `unknown`), `refund_id`, `created_at` (DB-stamped). Operation 1's key is `late-capture:payment:<payment_id>`, today's exact key, so a refund already sent by an old worker is adopted as operation 1 (M-03). Operation *n* > 1 uses `late-capture:payment:<payment_id>:op:<n>`.
- **Reservation under lock.** Under organization → event → order → payment, the workflow persists the operation with its exact amount = *available* (§6.1) at that moment, plus a `refunds` row carrying `repayment_operation_id`.
- **Submission recheck excludes the operation itself.** At the last local gate, *available* is recomputed with this operation's own reserved amount removed from *in flight*. Otherwise the first pending refund would block itself. The operation's amount must still be ≤ that recomputed amount. The gate then moves the operation to `submitting` and persists `submission_requested` before the HTTP call (existing pattern).
- **One sender per operation.** The transition `reserved → submitting` is a compare-and-set under the order lock. Only the transaction that performs it sends. A retry of the same operation reuses its key inside `RefundCreator::PROVIDER_REPLAY_WINDOW` and first runs `recover_provider_refund` (`StripeService.find_refund` by key). An operation in `unknown` is reconciled before anything else happens on the payment.
- **New operations.** A new operation (sequence + 1) may be reserved only after every earlier operation is `succeeded` or `failed_terminal` (a verified provider failure or cancellation). `unknown` is never terminal. A retry is never a new operation, and a new operation is never a retry.
- **`refund_disputed_payment`.** The operation becomes `failed_terminal` (no money moved). The wait it causes clears only when **the matching dispute** (same charge) is recorded and reconciled (§6.4), never on a timer and never because some other dispute closed.

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

### 7.2 Evidence that arrives before binding or capture (executable replay)

A door PaymentIntent is bound to its payment only in `process_door_success!`. A `refund.*`, `charge.refunded` or `charge.dispute.*` event that arrives first finds no payment (`find_payment` uses `payment_intent`). It records `refund_operation_not_found`, `refunded_payment_not_found` or `disputed_payment_not_found` with no payment. Calling `StripeWebhookProcessor.call` again does nothing, because the receipt is already processed and returns early (`stripe_webhook_processor.rb:17`). v2.1 specifies an executable path (tranche 4):

- **Entry point.** `StripeWebhookProcessor.replay!(receipt, payment:)` locks the `webhook_events` row (`FOR UPDATE`) first, then takes the normal refund and dispute prefix (organization → event → order → payment) through the same code the original event would have used. It runs only for a receipt that is processed with an open orphan exception of those three codes. It reads the **stored payload**; it never refetches. It verifies that the stored object's `payment_intent` equals `payment.provider_payment_id`, and that `livemode` and account match the payment's `provider_environment` and `provider_account_id`. A mismatch leaves the orphan open with `payment_context_mismatch`. Idempotency is per provider movement: a refund by `provider_refund_id` (unique), a dispute by provider dispute ID, and a posting by `(kind, source)`. A second replay changes nothing. On success it resolves the orphan exception with an audit entry naming the receipt and the movement, and it stamps `replayed_at` on the receipt.
- **Triggers.** Replay is enqueued after commit when **either** the payment is bound (gains `provider_payment_id`) **or** its capture is recorded (`capture_recorded_at` set). Either can happen first.
- **Fulfilment path.** If the order then fulfils normally, replayed evidence finalizes through the normal refund and dispute paths for a fulfilled order. Otherwise it goes through the classified path (§5.2).
- **Aggregate gaps.** `charge.refunded` carries `amount_refunded`. If that total exceeds the local succeeded refunds on the payment (an aggregate gap, the existing `recorded_refund_snapshot?` check), it is unreplayed evidence until `ProviderEvidenceReplay` lists the charge's refunds through the API and records each one.
- **Gate check before any enqueue.** "Unreplayed evidence" is a durable query evaluated **inside the submission gate under the locks**, not a flag set by an after-commit callback. It covers open orphan exceptions whose stored payload names this payment's intent or charge, and aggregate gaps. After-commit callbacks such as `LateCaptureRefundJob` therefore cannot slip a refund in before replay: the gate refuses with `evidence_unreplayed`.

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
| `OrganizationPayoutBalance` | Blocks org-wide on any open exception; deducts pending refunds and open disputes org-wide; reads cancellation recovery | `PAYOUT_HOLD = :strict` (P10): every open exception still blocks, as today, including quarantine, ambiguous ownership, restatement, unknown outcome and unreplayed evidence. The one exception is `never_fulfilled_buyer_overpaid` on a capture proven platform-only (P4), which alerts without blocking. Pending refunds and open disputes on classified payments are platform money, **not organizer debits**: excluded from `unresolved_refunds`/`unresolved_disputes` and from cancellation `already_reserved`. They still block through their exceptions while open |
| `Settlements::Finalizer.open_money_blocker`, `EventLifecycle#archive_blocker` | Same queries | The same strict rule as payout balance, quarantined rows included; missing processing evidence on classified orders doesn't block when the snapshot bearer is `platform` (it does under `organizer`) |
| `PayoutCreator` | Refuses a stale digest (`payout_creator.rb:186`) | Unchanged |
| `PayoutHoldRelease`, payout submission and confirmation | Through calculator and balance; `PayoutHoldRelease` runs its own queue check and can run automatically | **Guarded under their existing locks** (organization `FOR NO KEY UPDATE` → event → payout): each refuses to release, submit or confirm a payout on an event with an unresolved never-fulfilled hold, a classified capture not yet reflected in the payout's finalized settlement version, or a missing custody determination. A stale-digest check on new reservations (`PayoutCreator`) does not cover existing payouts, so these guards do. Historical transfers and statement versions are preserved |
| `AdminPayoutDueList`, `PayoutSchedule`, `PayoutCalendar` | Through calculator and balance | No code change beyond the shared readers |
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

**Why v2's as-of anti-join is insufficient (delta review).** v2 compared capture recording with the payout's *paid recording time* and excluded classified captures by a live anti-join. If a January 5 capture qualifies for a January 20 payout and a February backfill classifies that capture, the live anti-join removes the January row. An unrelated fulfilled Stripe sale between settlement finalization and paid recording also does not show what the payout funded.

**Fix (P12): a frozen custody determination per payout (A2).** New append-only `payout_custody_determinations`: `payout_id` (unique), `determination` (`stripe_custody`, `non_custodial`, `ambiguous`), `settlement_id` (the payout's finalized settlement version), `funded_order_item_ids` (from `PayoutLineAllocator`), `qualifying_payment_ids`, `basis` (`recorded_at_paid`, `derived_history`), `evidence` and `determined_at` (DB-stamped).

- **New payouts.** Written in the paid-recording transaction under the payout locks. A funded line counts as Stripe custody only if its order item's order has a capture that is in `Payment.live_agent_capture`, not classified, and recorded (`capture_recorded_at`) at or before finalization of the funded settlement version. Funded order-item identities alone do not prove Stripe custody, so payment evidence is required for each.
- **History (paid before A2).** Derived **once** by the A2 release task from the payout's finalized settlement and verified qualifying payment evidence. Pre-A1 captures use timing bounded by the A1 cutover (§2). The result is frozen. If any funded line's custody cannot be established, `determination = ambiguous` and BPT **keeps the payout's published result** (the row as the January export produced it), pending an explicit finance correction.
- **Readers.** BPT detail includes a payout row if and only if its determination is `stripe_custody`. A later capture, classification or backfill cannot change it. CPA's broader payout coverage ("every live USD payout", `cpa_monthly_report.rb:475`) is a separate rule and is unchanged.
- Month membership keeps using `paid_at` in A2 (residual §11).

Tests (F-19…F-24): a backdated `paid_at`; a redacted or missing paid audit; a payout reversal and a later check adjustment; a March classification of a capture that funded a February payout (the February determination is unchanged); the original Clover-only January / Stripe-in-February fixture (E14); and an ambiguous historical payout keeping its published row.

### 8.7 Holds versus debits (P10 strict)

| Item on a classified capture | Organizer debit? | Blocks organizer finalization or payout? |
| --- | --- | --- |
| Owed balance, pending known refund, open dispute | No | **Yes** (strict; existing controls) |
| Excess (over-return) on a capture **proven platform-only** | No | **No** (P4, the one authorized exception) |
| Excess where platform-only is not proven | No | Yes |
| Unknown refund result, unreplayed evidence, quarantine, ambiguous ownership, restatement, unknown provider release | No | **Yes** |
| Processing (bearer `platform`) | No | No |
| Processing (bearer `organizer`) | Yes (statement item) | Missing evidence blocks |

**"Proven platform-only"** means all of these hold. The capture is classified with lifecycle provenance, or with backfill provenance and no open quarantine. Every return movement on it is posted and positively matched. No posting is `pending_correction`. No linked `BalanceAdjustment` exists. The capture appears in no payout custody determination as `stripe_custody`. Under those conditions the money returned twice came from HåfaPass's own Stripe balance and touches no organizer payable.

v2's `:unknowns_only` is not shipped. It would release organizer payouts while a buyer is still owed, which is a broader policy change than the lead authorized.

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
| E5 (CR F4) | Captured Feb 10 10:00; dispute opened 10:02 before the job; lost Feb 20 $13.60 | Feb: paid 12.00, closing 0, chargebacks 0 | payable 0; Finalizer blocked while the dispute is open (P10 strict), unblocked once the loss resolves the exception | Job waits (`dispute_open`), zero POSTs; resolved on loss; manual resolve allowed after loss |
| E6 (F4b) | E5 but won Feb 20 | Feb: paid 12.00 when the refund succeeds | payable 0 | Evaluator enqueues; one POST of 1360 (operation 1 key) |
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
- C-08: `schema:load` restores every trigger. The dumped schema contains every `FinancialIntegrity` function and trigger, and each trigger exists on its table after a load (`pg_trigger`).
- C-09: schema round trip shows zero diff (CI `Verify fresh database schema`).
- C-15: `payments.capture_recorded_at` is DB-stamped on insert-as-captured and on the first transition into a captured status. It is not stamped on pending, failed or cancelled payments. It is unchanged by later refund status changes, rejected when changed, cleared, pre-stamped or written onto a pre-A1 captured row. A legacy webhook backfill with a backdated `succeeded_at` still gets the real recording time.
- C-16: classification insert refusals: non-captured payment; amount or currency mismatch; `capture_recorded_at` different from the payment's; order scope on a pending, completed, `completed_at`-set, fulfilled-by-payment or `order.completed`-audited order, or on one with an active ticket; payment scope without a fulfilling payment, or on the fulfilling payment; components not summing, or non-zero fee/tax on payment scope; backfill without evidence or after the cutover.
- C-17: the order marker is derived. It is set from the first order-scope row, not set by payment scope, unchanged by a second order-scope row, and cannot be set, changed or cleared directly.
- C-18: `fulfilled_by_payment_id` is written by completion. It is set once, must be a captured payment on the same order, and is refused for a classified payment or a classified order or an order that is not fulfilled. Free orders leave it NULL.
- C-19: ticket guard on reactivation (`cancelled` → `issued`) and on reassignment to a classified order. A pass child insert on a classified order is refused. Ordinary updates to active tickets (check-in, credential rotation, cancellation) are unaffected, and tickets on a payment-scope order are unaffected.
- C-20: `Order#ticket_fulfilled?` is false for a marked `partially_refunded` order.
- C-10…C-14: backfill. Positive provenance classifies; each missing proof → quarantine; a repeated run → no new rows; recheck under locks after a concurrent change; a restatement listed and refused without confirmation.

**Ledger and allocation**

- L-01: `BoundedAllocator` property test: 10,000 random vectors; never exceeds remaining; equals `MoneyAllocator` when in bounds.
- L-02: exhaustive check of every applied total 0…1360 for the base fixture, and 0…2560 for §5.5, under both policies: monotone, full return clears, sums exact. (The design review checked 1,361 applied balances.)
- L-03…L-08: E2, E3, E4, E10, E11, E12.
- L-09: both delivery orders of a pre-capture return.
- L-10: return and capture both recorded 28 Feb 23:59:5x ChST, posting committed 1 Mar 00:00:0x → recognized in **February** (no posting-month floor). Variant: February explicitly closed → `pending_correction`, excluded from both months, and February's CSV is byte-identical; after the approved correction it appears in March with `prior_period_note` and both original times.
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
  - a verified failure → operation 2 with the `:op:2` key;
  - `refund_disputed_payment` → wait and dispute ingestion via the API;
  - an organizer refund refused.

  Countable: **Stripe refund POST count and amount** per test.
- X-05 (2-conn): job versus admin "Refund buyer" → exactly one POST.
- X-06 (2-conn): job submission gate versus `charge.dispute.created` → either the dispute commits first (zero POSTs) or the POST happens and Stripe's refusal is a wait (one failed attempt, zero money moved, no second attempt before the outcome).

**Evaluator**

- E-01…E-10: each trigger in §7.1, the reopen path, refund failure after full loss, replay after binding, and `ingest!` cases (before capture, competing reservation, excess). Audit metadata lists posting IDs.
- X-07 (2-conn): refund success versus dispute loss commit → one resolution, excess computed once, no deadlock (organization → event → order in both).
- E-11…E-15: replay before binding and before capture recording (both trigger orders); a replay with a mismatched context leaves the orphan open; a duplicate replay is a no-op; `refunded_payment_not_found` and an aggregate gap block the gate (`evidence_unreplayed`) until replayed; replayed evidence on an order that then fulfils finalizes through the fulfilled path.

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

**Classification concurrency (A1 tranche 1, implemented)**

- X-08 (2-conn): raw ticket insert holds the order first and commits → the competing classification waits, then is refused (active ticket).
- X-09 (2-conn): classification holds the order first and commits → the competing raw ticket insert waits, then is refused.
- X-10 (2-conn): a reactivation that skips the order prefix while another transaction holds the order fails at once with 55P03; it never waits while holding the ticket.

**Ledger additions (v2.1)**

- L-17…L-24: the 10¢ order-dependence pair from §5.4 under both posting orders (each matches its frozen sequence); the late-win counterexample (refund (4,0) survives exactly); a late win received before its loss receipt; duplicate and stale dispute receipts; an overpaid loss later reversed with excess promotion; a stable tie-break for facts posted together by `classify!`; P9 snapshot and `policy_version` on every posting; gross owed identical under both P9 values.

**Repayment additions (v2.1)**

- R-13…R-17: the first operation's own reservation does not block its submission; a $5.00 success followed by an $8.60 top-up creates operation 2 with a new key (not attempt 1); a retry of an `unknown` operation reuses its key and looks it up first; no operation 2 while operation 1 is `unknown`; `refund_disputed_payment` waits until the matching dispute is reconciled, and an unrelated dispute's closure does not clear it.

**Prevention additions (v2.1, B)**

- P-28…P-33: no-ID "never attempted" rechecked under the setup locks (mark and lease seen, so `unknown`); door `claim_setup!` versus expiry under order → payment; every release source routed through the shared decision; cutoff constant ≥ Session lifetime; P4 abort and changed-preview rejection cause no refund or classification; paid orders held through the drain and classified or fulfilled after the commit.

**Finance additions (v2.1, A2)**

- F-19…F-24: §8.6 custody cases.
- F-25: `PayoutHoldRelease`, submission and confirmation refuse an affected payout under their locks, including the automatic release during the reader switch.

**Mixed version** (§10.3)

- M-01…M-09.

---

## 10. Delivery and rollout

### 10.1 PR shape, releases and tranches

**A1 is one PR (#248) and two releases.** Activation is a separate code release, never an environment variable, `SiteSetting` or runtime constant flip.

| Release | Contents | Safe against the previous version's processes because |
| --- | --- | --- |
| **A1-R1** (merge of #248) | Tranches 1–4 below. Migrations, triggers and the **database compatibility fence**. Classification, payment-only boundaries, postings, replay, reconcile, the operation records and the evaluator. The new submitter is present but **inactive**: R1 sends no outbound refund for a *fenced payment* (below). R1 can still look up existing operations (`find_refund` by key, a read) to adjudicate them. Finance readers stay as main's; the `57de7f15` interim reader code is reverted so there is one reader generation at a time | Old code never writes the new columns or tables. The triggers reject only things old code never does legitimately. The payment trigger stamps recording times for old code too. The fence, installed by R1's pre-deploy migration before any R1 process starts, stops old code from reserving or submitting a refund for a fenced payment. R1 itself submits none, so the 7bcd97c2 ↔ R1 overlap has **no new submitter** |
| **A1-R2** (small follow-up PR) | Activates the operation-based submitter for fenced payments and nothing else | Deployed only after the release-boundary evidence in §10.5. During the R1 ↔ R2 overlap, R1 never submits for fenced payments, so only R2 can |
| **A2** (follow-up PR) | All §8 readers in one release, the reader register CI, CPA/BPT columns and guide, R2-2 custody, payout-entry guards and their compatibility fence, `accounting_period_closes` | §10.5 preflight. Old (A1) payout actions are fenced during the A2 overlap by A2's pre-deploy guard (below) |
| **A3** | Remove the exception-window predicate and `EVIDENCE_WINDOW_SECONDS`, the legacy reopen check, dead v1 code; monitoring (§8.9) | A2 never reads the removed code |
| **B1**, **B2** | §3 | Independent of A's schema; B1 needs A1's `classify!` for ineligible completions |

**Fenced payment.** A payment that has a `never_fulfilled_captures` row, or a `LateCaptureRefund::CODES` exception, or a second-capture or ambiguous-ownership exception. Old code writes the late-capture exception in the capture's own transaction, so its own captures are fenced from the moment they commit.

**The fence (R1 migration, `refunds` BEFORE INSERT OR UPDATE trigger).** For a fenced payment it rejects (1) inserting an outbound reservation: a `refunds` row with no provider refund ID, a key that is not `provider:stripe:refund:*`, and no `repayment_operation_id`; and (2) the last local gate: the transition of such a row's `failure_code` to `provider_result_unknown`, which `RefundCreator#provider_submission_allowed?(mark_unknown: true)` persists immediately before the HTTP call. It never rejects recording a provider fact: inbound refunds, status outcomes of a row already past the gate, and rows carrying a provider refund ID all pass. Old code that hits the fence fails before any network call. Its job retries and fails again, and its exception stays open, which blocks payouts. **Affected payouts and finalization stay blocked from R1 until repayment is resolved** (P10 strict), quarantined rows included.

**Trade-off.** Between R1 and R2 (planned as about one day), automatic refunds of late captures wait. Door-card payments stay off throughout (§10.1 order).

**A1 tranches (all inside R1, in this order; each is a separable, tested commit).**

| Tranche | Scope | State |
| --- | --- | --- |
| 1 | Schema foundation: `never_fulfilled_captures`, `orders.never_fulfilled_at`/`fulfilled_by_payment_id`, `payments.capture_recorded_at`, `financial_cutovers`, all §4.2 triggers and schema-dump reinstallation, completion writes the fulfilling payment, `ticket_fulfilled?` reads the marker | **Implemented in this branch** |
| 2 | Exact lifecycle writers (`classify!` at every §4.3 boundary, legacy fulfilling-payment derivation, ambiguity quarantine) and payment-only side-effect boundaries (refund finalization, admission, dispute ticket cancellation, commissions, processing fees) | **Implemented in this branch** (§4.6) |
| 3 | Postings: DB-stamped movement recording times, `sequence`, `BoundedAllocator`, recomputation reversals and late wins, reconcile and backfill dispositions | **Implemented in this branch** (§5.7) |
| 4 | `repayment_operations`, `BuyerRepayment` gate (inactive submitter), evaluator, `replay!`, `ExternalRefundRecovery`, `EventCancellationRefunds` exclusion, admin owed and resolution rules, the compatibility fence, read-only release scripts | After 3 |
| R2 | Activation | After R1 evidence |

**Order and dates.** A1-R1, A1-R2 and A2 must all be in production before Jan 4, 2027. A3 may follow in January. B1 should land before Jan 4. If it slips, A still keeps the books right and only the frequency is higher. B2 follows B1. **PR A has priority over B.** Door-card payments stay off (`events.online_door_card_enabled` defaults to `false`) until A2 and B1 are live and the `checkout.session.expired` subscription is confirmed (PRODUCTION_CUTOVER.md step 1).

### 10.2 Why writers first

If readers switched in the same deploy as writers, an old instance in Render's zero-downtime overlap could record a late capture with no classification, and the new readers would book it as organizer custody. With A1 first, old and new readers agree during A1's overlap (both are main's). R1's per-payment reconcile classifies the overlap's rows, and A2's overlap partner is an A1 instance that classifies itself.

### 10.3 Mixed-version tests (CI job `mixed-version`, A1 and A2)

- **M-01:** check out the previous release's `app/` and its late-capture specs, load the **new** `schema.rb`, and run them. Expect 0 failures and triggers present.
- **M-02:** previous-release code records a late capture on the new schema, then new code runs `reconcile` → one classification, provenance evidence recorded, and postings for any refund it already made.
- **M-03:** previous-release `LateCaptureRefundJob` refund already past its gate (key `late-capture:payment:<id>`, `provider_result_unknown`) when R2 starts → R2 adopts it as operation 1, looks it up by key and makes no second POST.
- **M-04:** A2 readers on A1 data produced by M-02 → CPA, BPT and calculator numbers equal the E-table expectations.
- **M-05:** previous-release reservation on a fenced payment (job, admin "Refund buyer", admin order refund, fraud refund) → rejected by the fence; zero provider POSTs.
- **M-06:** previous-release reservation created *before* the fence migration, then the old final gate after it → the gate transition is rejected; zero POSTs.
- **M-07:** a previous-release refund already past the gate is adjudicated by R1's lookup after the in-flight bound (§10.5) with no POST; its outcome is recorded and posted.
- **M-08:** R1 and R2 processes on one database: two-connection races at reservation, the last gate and POST → R1 never submits for a fenced payment, and R2 submits exactly once per operation.
- **M-09:** A1 `PayoutHoldRelease` (automatic) during the A2 overlap → refused by A2's payout guard.

### 10.4 Local and test-mode rehearsal (before each production deploy)

On task-owned databases (`hafapass_ncap_rehearsal_*`, asserted `localhost:5432`, dropped afterwards):

1. Load 7bcd97c2's schema and run a scenario seed script that drives the real services for E1–E16 under 7bcd97c2 (Stripe stubbed; webhooks via `StripeWebhookProcessor`).
2. Generate the CPA and BPT CSVs for every month with activity and record their sha256.
3. Migrate to A1. Run `reconcile DRY_RUN=1` (expected counts printed), then for real. Regenerate the CSVs: **identical hashes** (A1 doesn't change readers).
4. Run 7bcd97c2 and A1-R1 processes against the same database at once while replaying a late-capture webhook through the old process (the deploy overlap), then `reconcile`. Then run R1 and R2 together. Count stubbed provider requests at reservation, the last gate and POST (M-05…M-08).
5. Deploy A2 locally, regenerate, and diff. Every changed row must map to an E-table expectation. The diff report is attached to the A2 PR.
6. **Rush measurement for P7 (B1):** with the deployed one-thread embedded queue, a local k6 run with the repository's `load_tests/` scaled to Copa (abandoned carts plus 10% slow Stripe stub at 5 s). Record expiry queue age, first-attempt coverage before grace end, withheld inventory over time, and `released_unknown` count, covering ticket types, tiers, seats, catalog and door allotments. Acceptance: first-attempt coverage ≥ 99% within the grace on stub latency p95 ≤ 1 s, and zero oversells. Leon accepts or changes the 2/3-minute values from this report.
7. **Stripe test mode (B1/B2):** the scenarios listed under "Prevention" in §9.2, with real test-mode objects and signed test webhooks. No live mode.

### 10.5 Production release boundary and rollback evidence

Agents do not read or change production data. **Home base** runs the production release and the read-only evidence below. It uses committed read-only SQL scripts (`script/never_fulfilled/`, tranche 4) and read-only Render deploy and instance listings, and records the outputs in the PR. Nothing in this plan changes an environment variable, a `SiteSetting` or Render configuration, makes a real charge, or repairs production rows by hand. Classification, adjudication and reconcile are application code paths running in the app's own jobs.

**What `/up` and the health revision do not prove.** `/up` is a boot probe. Readiness and `RuntimeExecution` show that the *new* revision is running and ticking. They do not show that *old* executors have stopped, or that an old provider request has finished. An old embedded process can still be serving Puma request threads or finishing a job after the new revision reports healthy, and a process killed mid-POST leaves no heartbeat although Stripe may have received its request.

**Release boundary for A1-R2 (activation).** All of the following must hold before R2 is deployed:

1. **Additive writers and compatibility.** After R1: every `FinancialIntegrity` trigger and the fence are present (`pg_trigger`), constraints are validated (`convalidated = true`), and M-01…M-08 passed on the R1 head.
2. **No new submitter during overlap.** R1's code makes no outbound refund for fenced payments (M-08). This is a property of the R1 code, verified in CI, not a runtime setting.
3. **Old processes gone (drain evidence).**
   - (a) *Render, read-only via home base:* the R1 deploy is `live` and every earlier deploy is `deactivated`, the service's instance list shows no instance on an earlier commit, and more than Render's shutdown grace has passed since R1 went live ([zero-downtime deploys](https://render.com/docs/deploys#zero-downtime-deploys)).
   - (b) *Runtime revision, read-only SQL:* `solid_queue_processes` rows heartbeating within `EmbeddedReadiness::HEARTBEAT_WINDOW` all carry `metadata.application_revision` = the R1 SHA. No `solid_queue_claimed_executions` row belongs to a process on another revision. `RuntimeExecution` shows recent R1 ticks for every required task.
4. **Durable job and operation audit, read-only SQL.**
   - No ready, scheduled or claimed `LateCaptureRefundJob` or refund job enqueued by an earlier revision.
   - For fenced payments, every refund in `pending` with `failure_code = provider_result_unknown`, and every `submission_requested` audit without a terminal audit, has been **adjudicated**. R1 has looked it up by key at Stripe and recorded the outcome, and the lookup ran after the in-flight bound: the submission audit is older than the configured Stripe client timeout × retries, plus a 10-minute margin. A request that may still land is never adjudicated as absent.
   - `never_fulfilled:verify` reports zero unclassified candidates and zero unposted movements.
5. **Fail-closed payouts.** Events with fenced payments still show open blocking exceptions (P10 strict). No payout on such an event has moved since R1.

**If drain evidence (3a) is unavailable**, for example because Render listings cannot be read: R2 may still be deployed, provided (1), (2), (3b), (4) and (5) hold. The fence was installed before any R1 process started and rejects every old reservation and every old last-gate transition. The only old operations that can exist are those already past the gate before the fence migration committed, and (4) adjudicates them after the in-flight bound. The PR records that (3a) was unavailable and that the fence argument was used instead.

**A2 preflight.** The same (3) and (4) for A1-R2's processes, plus: reconcile complete (`never_fulfilled:verify` zero); A2's payout guards present (`pg_trigger`, from A2's pre-deploy migration, so old A1 `PayoutHoldRelease`, submission and confirmation fail closed during the overlap, M-09); held and in-flight payouts on affected events listed. A recurring tick, a manual sign-off after the reader switch, or flipping a constant is not evidence. Historical monetary rows and exported baselines are compared like for like (A2 appends columns, so compare the pre-existing columns byte for byte and review the new ones separately).

| When | Evidence | Gate |
| --- | --- | --- |
| Before A1-R1 | Counts: orders with a `LateCaptureRefund::CODES` exception; finalized settlements on their events; held, pending or processing payouts on those events; refunds in `provider_result_unknown`; CPA/BPT CSV sha256 for every month with live activity | Recorded baseline |
| After A1-R1 | Boundary items (1) and (5); reconcile dry-run counts: classified N, quarantined Q, restatement R | Q and R are dispositioned per §4.5 (no restatement is written) |
| Before A1-R2 | Boundary items (1)–(5), or the fence alternative | All required |
| Before A2 | A2 preflight; CPA/BPT closed-month hashes equal the baseline | All required |
| After A2 | Closed-month CSV hashes unchanged except rows listed in the rehearsal diff (each handled as a correction, §5.3); events needing re-finalization listed; held and in-flight payouts on them reviewed | Finance signs off before any payout on a listed event |
| After B1 | Monitoring: `released_unknown` = 0 in the first live week, or each one explained | — |

**Verification without production changes.** The boundary is rehearsed locally (§10.4 step 4) on task-owned databases with 7bcd97c2, R1 and R2 processes sharing one database and Stripe stubbed, counting provider requests at reservation, the last gate and POST. Optional Stripe **test-mode** lookups exercise adjudication. Production is read-only.

**Rollback.** Never run down migrations in production. Roll back only to a version that keeps these protections. A2 → A1-R2: readers revert, and A2's payout guards stay in the database and keep payouts on affected events fail-closed. A1-R2 → A1-R1: the submitter becomes inactive again and the fence holds. A1-R1 → 7bcd97c2 is permitted only because the fence and triggers stay in the database: old code then cannot submit for fenced payments (fail-closed), classification stops, and finance handles repayment through the reconciliation queue until R1 is redeployed. B1/B2 → previous: holds written with grace simply count a little longer, and old code ignores `provider_release_state`.

---

## 11. Residuals and open decisions

- **CPA approvals outstanding:** P1, P2 (both halves), P3, P5, P9 (with the 75¢ example, recorded against `policy_version`), P11 (including the correction procedure), P12. Until approved, the CSV header note says "working positions pending CPA review". The v1 BPT fee/tax working treatment stays pending CPA review.
- **Leon decisions outstanding:** P4 recovery and write-off policy; any move from P10 `:strict` to `:unknowns_only`; P7 values after the rush report; P13 postponement and P14 paid-door extension and override (conservative defaults shipped).
- **Exact obligations carried into tranches 2–4 (not yet provable from repo evidence):**
  - Component derivation (**closed by tranche 2**, §4.6 item 3). The bridging term is the per-line clamp in `OrderCreator#create_ledger!`; a clamped or otherwise mismatched order is quarantined, never inserted.
  - Fence exemptions. Tranche 4 must confirm from `ExternalRefundRecovery` and every webhook refund writer in 7bcd97c2 that inbound provider refunds are inserted with a provider refund ID (so the fence never drops an inbound fact). If any is not, the fence also exempts that writer's key shape, and M-05 covers it.
  - In-flight bound. Tranche 4 records the actual `StripeService` open and read timeouts and retry count used for the adjudication bound in §10.5.
  - `accounting_period_closes` does not exist yet. Until A2 adds it, no period counts as closed for these postings, so ordinary `max(return, capture)` recognition applies everywhere.
  - Legacy fulfilling-payment evidence (**closed by tranche 2**, §4.6 item 5). The `order.completed` audit is written fail-open (`AuditContext.set(fail_open: true)`), so its absence proves nothing. Legacy second captures with no audit naming a captured payment on the same order are quarantined.
- **BPT payout month:** BPT uses `paid_at` and CPA uses the paid recording time. A backdated `paid_at` can put a payout in different months in the two exports (pre-existing; CPA decides).
- **Late wins on fulfilled orders:** recorded and flagged (`dispute_late_win`); the organizer-side credit is a follow-up.
- **Dispute fees:** HåfaPass records no actual Stripe dispute fees today, for any dispute. P5 guarantees no organizer is charged; recording the actual fee and any credit as an attributable platform cost (a new `FeeComponent` kind) is a follow-up. CPA uses Stripe's statement meanwhile.
- **Refund failure after success:** stays a finance exception; posting a reversal needs an audited finance action.
- **Estimates:** A1 2–3 agent days, A2 2 days, A3 0.5 day, B1 2 days, B2 1.5 days. Each needs two review rounds plus the Stripe test-mode and rush rehearsal time in §10.4, which earlier estimates did not budget.
- **Ancillary docs:** `docs/CPA_MONTHLY_EXPORT_GUIDE.md` and `docs/SETTLEMENT_AND_PAYOUT_OPERATIONS.md` describe the interim `57de7f15` behaviour and already point here as the planned replacement. They make no promise this design breaks, so tranche 1 leaves them unchanged. The tranches that change behaviour update them. `docs/LOCKING.md` gains the §4.2 order-row serialization rule with tranche 1.
- **Estimates (v2.1):** A1 tranches 2–4 about 3 agent days plus two review rounds; R2 0.5 day; A2 2 days. These do not include the mixed-version rehearsal.
