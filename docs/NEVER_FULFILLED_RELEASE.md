# Never-fulfilled captures: A1 release runbook

This runbook covers the two A1 releases of [the never-fulfilled design](./design/never-fulfilled-captures.md) (§10). Home base runs the production release and every production command below. Agents never read or change production data. Every command here is read-only, except the deploys themselves. Nothing here changes an environment variable, a `SiteSetting` or Render configuration. Nothing makes a real charge or repairs a production row by hand.

## What each release does

| Release | Change | Money it can send for a fenced payment |
| --- | --- | --- |
| **A1-R1** (merge of #248) | Migrations `20261126100000`…`20261126130200`: classification, postings, repayment operations, the database **repayment fence** on `refunds` and `payouts`, and the **evidence guards** of the A1-R1 review (below). `Commerce::BuyerRepayment::SUBMITTER_ACTIVE = false`. | None. R1 reserves no repayment operation and never passes the operation gate. It can look up an older release's refund by its key and record the result (`Commerce::RepaymentAdjudication`). |
| **A1-R2** (small follow-up PR) | Changes `SUBMITTER_ACTIVE` to `true` and the specs that assert R1 behaviour. Nothing else. | One repayment operation at a time per payment, sized under the order lock and rechecked at the gate. |

A *fenced payment* has a `never_fulfilled_captures` row or an exception with one of these codes: `late_payment_success_after_inventory_release`, `late_payment_success_after_hold_expiry`, `pass_all_included_nights_cancelled`, `unfulfilled_second_capture`, `never_fulfilled_ownership_ambiguous` or `never_fulfilled_classification_quarantined`. The open or resolved status of the exception does not matter. The database function `hafapass_fenced_payment(payment_id)` is the single definition, and the application uses the same function.

## The fence (installed by R1's pre-deploy migration)

`bin/release-migrate` runs before any R1 process starts, so the fence exists before the overlap begins.

- **`refunds_repayment_fence`** rejects two things for a fenced payment. The first is a new outbound reservation: a row with no provider refund ID, no repayment operation and a key that is not `provider:stripe:refund:*`. The second is the last local gate: moving such a row's `failure_code` to `provider_result_unknown`, which 7bcd97c2 persists immediately before its Stripe POST. A row that belongs to a repayment operation passes the gate only while that operation is `submitting`, and only `Commerce::BuyerRepayment.gate!` sets that. The fence never rejects provider evidence: inbound rows keyed `provider:stripe:refund:<id>`, rows that carry a provider refund ID, and outcomes of a row already past the gate.
- **`payouts_repayment_fence`** rejects creating a payout as `pending` or `processing`, releasing a held payout, and submitting a pending one, on an event with an open blocking never-fulfilled item. `never_fulfilled_buyer_overpaid` never blocks (P4). The application checks the same rule first (`Commerce::NeverFulfilledPayoutHold`) and also guards paid recording. A transfer that left before a cancellation can still be recorded with the existing confirmation.

An old worker that hits the fence fails before any network call. Its job retries and fails again. Its exception stays open, which keeps the event's payouts and finalization blocked.

## The evidence guards (installed by `20261126130000`, before any R1 process starts)

Each guard sits on the write that causes the effect, so a 7bcd97c2 writer, a rollback build or raw SQL fails in the same transaction. A refused webhook rolls back whole; its signed receipt stays `failed`, Stripe redelivers it, and R1 applies it. The provider fact is never lost.

| Guard | Refuses | Allows |
| --- | --- | --- |
| `refund_items_sale_ownership`, `promoter_commission_entries_sale_ownership`, `ticket_inventory_retentions_sale_ownership`, `tickets_dispute_sale_ownership` | Refund items, commission reversals, retained inventory and dispute ticket cancellation from a payment that does not own the sale (`hafapass_sale_owner_payment`: the order's recorded fulfilling payment; an order-scope never-fulfilled capture; else the order's only captured payment of its mode, and for a fenced payment only when the order never fulfilled) | Everything on the owning payment. R1 records the non-owner's refund or loss itself and holds the sale effects (`never_fulfilled_sale_effects_held`) |
| `payouts_repayment_fence` (replaced) | On an event with an open blocking item (`hafapass_payout_block_start`): creating a payout, releasing a held one, and moving one to `processing` or `paid` | The outcome of a submission authorized **before** the earliest open item (its `payout.submission_requested` audit is earlier): money already sent is recorded, never a new payment. Holding, failing and reversing |
| `audit_logs_payout_submission_fence` | The actual submission authorization of both releases (the `payout.submission_requested` audit, written under the payout lock before the gateway call) on such an event | — |
| `settlements_finalization_fence` | Finalizing a statement on such an event; and on an event with a never-fulfilled order in a sale status, any finalizer except R1's reader (`hafapass.settlement_reader`) | R1's `Settlements::Finalizer` |
| `payouts_repayment_fence` (insert) | Creating a payout on an event with a never-fulfilled order in a sale status, except by R1's `PayoutCreator` | — |
| `reconciliation_exceptions_evidence_hold` | Closing an evidence hold (`FinancialIntegrity::EVIDENCE_HOLD_CODES`) unless the same transaction's evidence path named it: a note, the 7bcd97c2 admin action or raw SQL cannot | The evaluator, reconcile, `SaleEffectHold` |
| `refunds_identity_fence` | Binding a provider refund ID to an outbound row of a fenced payment unless the application matched it exactly (its POST response, a lookup by its own key, its provider ID); never by amount and date | Inbound rows keyed `provider:stripe:refund:<id>` |

The settlement reader rule exists because 7bcd97c2's calculator disagrees on a never-fulfilled order: for the review's $13.60 order ($5 refund, $8.60 loss) in an event with a $99.00 sale, it reports $97.29 payable, and R1 reports $99.00. Without the rule, a rollback could finalize and pay the old figure.

**What the fence cannot stop.** An old worker retrying a request that was already past its gate before the migration committed resends **the same idempotency key** (`late-capture:payment:<id>`). Stripe returns the first result for that key. 7bcd97c2 refuses to resend after 23 hours. That request is exactly what boundary item 4 below adjudicates. New operations never use that key (operation *n* uses `late-capture:payment:<id>:op:<n>`), so an old worker can never find or co-send a new operation.

## Before A1-R1: record the baseline

```sh
psql "$READ_ONLY_DATABASE_URL" -v ON_ERROR_STOP=1 -f hafapass_api/script/never_fulfilled/baseline_before_r1.sql
```

This records:

- late-capture exceptions by code and status;
- finalized settlements on their events;
- pending, processing and held payouts on those events;
- refunds in `provider_result_unknown`;
- late-capture-key refunds by status.

Also save the CPA and BPT CSVs and their sha256 for every month with live activity, using the existing admin exports. R1 **does** change two readers relative to 7bcd97c2, so compare like-format monetary rows, not only hashes:

- `Settlements::Calculator` leaves an order-scope never-fulfilled order's proceeds, refunds, refund items, losses and platform fees out (its processing keeps the never-fulfilled bearer rule), and counts only the recorded fulfilling payment's refunds and disputes on the sale.
- `CpaMonthlyReport` books never-fulfilled captures as buyer refund captures, not organizer custody or chargebacks (earlier A1 commits).

Expected after R1: identical rows and hashes for every month and event with no never-fulfilled activity. For an event with a classified order, only that event's row and the month's total row differ, and the R1 values agree with the R1 calculator. The two-process rehearsal shows the pattern: `chargebacks 8.60→0.00`, `closing_custodial_liability 50.60→59.20`, `buyer_refunds_paid 4.42→12.00`, `closing_buyer_refunds_owed 7.58→0.00`, flag `no→yes`; BPT identical. Any other difference is a defect. Also save the baseline's `payout_transitions_on_late_capture_events` (all payout transitions ever audited on those events), so the post-R1 check compares history and not only what is blocked now.

## After A1-R1 is live

Use the read-only rake task. It runs the same SQL in one `READ ONLY` transaction and rolls it back:

```sh
bin/rails never_fulfilled:release_evidence R1_SHA=<40-hex R1 commit> R1_LIVE_AT=<ISO-8601 UTC time R1 went live>
bin/rails never_fulfilled:verify                        # read-only reconcile counts
bin/rails never_fulfilled:reconcile                     # DRY_RUN=1 is the default: counts only
```

`psql` gives the same output: `psql "$READ_ONLY_DATABASE_URL" -v r1_sha=... -v r1_live_at=... -v bound_seconds=770 -f hafapass_api/script/never_fulfilled/release_evidence.sql`. The bound is `Commerce::BuyerRepayment.in_flight_bound`, which is 770 seconds with the current `config/initializers/stripe.rb` values. Read it from the code if those values change.

Check:

- `triggers` lists all 24 triggers, including `refunds_repayment_fence`, `payouts_repayment_fence`, `repayment_operations_check` and the eight evidence guards above.
- `unvalidated_constraints` is empty, and `cutovers` contains `a1_capture_recording`, `a1_return_recording`, `a1_repayment_fence` and `a1_evidence_guards`.
- `payouts_on_blocked_events.changed_since_r1` is 0 for every row, and `payout_transitions_since_r1` shows no `payout.submission_requested`, `payout.processing` or `payout.paid` on an affected event except the recorded outcome of a submission authorized before its hold.
- `evidence_hold_resolutions` shows only evaluator, reconcile or `sale_effects_released` resolutions, never a manual one.

Disposition the reconcile dry run's quarantined and restatement counts as §4.5 requires. No restatement is ever written.

## Release boundary for A1-R2

Deploy R2 only when items 1 through 6 hold, including 3a.

0. **R1 itself holds.** R1 never sends a repayment and never needs drain evidence. If anything below cannot be shown, stay on R1; it is the safe state.
1. **Writers and fence present.** The evidence run shows every trigger, validated constraints and the four cutovers. CI passed on the R1 head, including `spec/models/repayment_fence_spec.rb` and `spec/services/commerce/buyer_repayment_concurrency_spec.rb` (M-05…M-08), plus the previous-release rehearsal below.
2. **No new submitter during the overlap.** This is a property of the R1 code: `SUBMITTER_ACTIVE = false`, and the specs that run as R1 assert zero POSTs. It is not a runtime setting.
3. **Old processes gone.**
   - (a) Render, read-only, through home base: the R1 deploy is `live`, every earlier deploy is `deactivated`, no instance runs an earlier commit, and more than Render's shutdown grace plus 23 hours and the in-flight bound has passed since R1 went live (the last time a 7bcd97c2 process could still resend a request it had in hand).
   - (b) `live_processes` shows only `other_revision = f`, and `claimed_by_other_revision` is 0. `runtime_ticks` shows recent R1 ticks for every required task.
4. **Durable work audited.**
   - `refund_jobs_before_r1` is empty: no unfinished `LateCaptureRefundJob`, `EventCancellationRefundJob` or `RefundReconciliationJob` was enqueued before R1 went live.
   - `legacy_refunds_on_fenced_payments` is empty. Each such refund has been adjudicated by a lookup at Stripe that **started after** its `adjudicable_after` time, its last possible send: `created_at` + 23 hours (7bcd97c2's own replay window, checked just before its gate) + the in-flight bound, never earlier than its recorded submission + the bound. The submission audit alone is not that boundary: 7bcd97c2 can pass its gate again for a row already marked unknown without writing anything. R1 enqueues `RepaymentAdjudicationJob` for each one when a repayment waits on it, or when an administrator uses **Refund buyer**, and the job waits until that time. A row with `adjudicable = f` may still land at Stripe and is never treated as absent. A Stripe refund found by the row's own key is recorded at any time.
   - Every pending refund on a fenced payment was checked by its own key only. **Check Stripe status** and the scheduled refund resync never match a fenced row by amount and date, and a Dashboard refund without the key is recorded as its own movement (**Verify**).
   - `never_fulfilled:verify` reports `unclassified_or_unposted=0` and `unposted_movement_payments=0`.
5. **Payouts fail closed.** Events with open blocking items still show them. No payout on them moved since R1 (`changed_since_r1 = 0`), except the recorded outcome of a submission authorized before its hold (`payout_transitions_since_r1`), each `paid` one with its `sent_before_hold_confirmed` evidence.

**What each item proves, and what it does not.** 3b is evidence from the queue tables: a heartbeat and an empty pending-row query cannot prove that an old web process or an in-flight HTTP request is gone. Neither 3a nor 3b is used by the code. R1's safety during the overlap does not depend on drain: every old effect path above is refused by the database, and adjudication waits for each row's own last possible send, which comes from 7bcd97c2's code, not from a drain observation. R2 needs drain (3a) because R2's own operation gate resends an `unknown` operation after the in-flight bound, which is safe only once no old sender can hold the same key. If 3a is unavailable, do not deploy R2; there is no fence-only alternative.

6. **Backlog listed.** `bin/rails never_fulfilled:repayment_backlog` (read-only `DRY_RUN=1`, the default) lists each classified capture R1 left waiting, with what is owed and its wait reason.

### The R2 change, exactly

- `hafapass_api/app/services/commerce/buyer_repayment.rb`: `SUBMITTER_ACTIVE = false` becomes `SUBMITTER_ACTIVE = true`.
- Specs: examples that assert R1 behaviour (`"A1-R1"` describe blocks and `sends nothing in A1-R1` examples) either move under `repayment_submitter: :active` or are deleted. The `repayment_submitter: :active` tag becomes the default.
- No migration, setting, environment variable or other code change. If R2 needs more than this, it is a different release and needs its own review.
- After R2 is live and the boundary items still hold, home base runs `bin/rails never_fulfilled:repayment_backlog DRY_RUN=0` once. It enqueues `LateCaptureRefundJob` for each owed capture; R1 code refuses that mode. Each job reserves under the order lock and the gate rechecks everything, so a second run is harmless.

## Two-version rehearsals (before each production deploy)

On task-owned localhost databases:

```sh
REHEARSAL_DIR=<scratch dir> REHEARSAL_DB=hafapass_ncap_rehearsal_<name> \
  hafapass_api/script/never_fulfilled/rehearse_two_process.sh
REHEARSAL_DIR=<scratch dir> REHEARSAL_DB=hafapass_ncap_rehearsal_<name> \
  hafapass_api/script/never_fulfilled/rehearse_previous_release.sh
```

**Two processes on one database** (`rehearse_two_process.sh`). The pinned 7bcd97c2 app (exported with `git archive`, no checkout) and this release run as separate `bin/rails runner` processes against one database with this branch's schema. Stripe and the payout gateway are stubbed (`two_process/stubs.rb`); a JSON ledger shared by both processes stands in for Stripe, so what one process POSTs the other finds by its key. The old process is paused inside its stubbed calls: after its last refund gate (in the POST), at its lookup before the gate, and at the payout gateway after its submission authorization. It writes every provider call, every action and its result, CPA/BPT rows and the release evidence to the scratch directory, and drops the database unless `KEEP_DB=1`. On the R1 head it showed (scenario outputs in the PR's verification notes):

| Scenario | Old process (7bcd97c2) | This release |
| --- | --- | --- |
| New reservation on a fenced payment | Refused at the insert (`refunds_repayment_fence`), 0 POSTs | — |
| Reservation made before the fence, at its last gate | Refused at the gate, 0 POSTs | — |
| Row already past its gate, retried; old process paused inside its POST | 1 POST ($13.60, `late-capture:payment:<id>`, the same key); recording it refused (`refunds_identity_fence`) | Adjudication during the POST: `in_flight`. R1 repayment: waits. After: found by key, recorded once; owed $0 |
| Unsent reservation; old process paused at its lookup, before its gate | Resumes and finds the row cancelled; 0 POSTs | Adjudicates it `fenced_reservation_unsent` |
| Inbound refund on a classified second payment B | Refused (`refund_items_sale_ownership`); receipt `failed` | Same notice: recorded on B only; sale unchanged |
| Lost dispute on B before B's capture is recorded | Ticket cancellation refused; receipt `failed` | Recorded, held; B's capture classifies it; hold closes as `isolated`; tickets issued |
| Inbound refund on a legacy order's payment with ambiguous ownership | Refused; receipt `failed` | Recorded, sale effects held |
| Payout submitted before the hold, paused at the gateway while the hold opens | Gateway called once; outcome `processing` recorded; later recorded `paid` | — |
| Pending payout reserved before the hold, submitted after it | Submission audit refused (`audit_logs_payout_submission_fence`); `paid` refused | Refused (application check) |
| Reserve or finalize after the hold | Finalize refused | Both refused |
| Fully returned never-fulfilled order in a $99.00 event | Calculator $97.29; finalize refused (`settlement_reader`) | Calculator $99.00; finalized; payout $99.00 |
| CPA / BPT (live-mode month) | — | CPA differs only on the never-fulfilled event row and the total row (above); BPT identical |

Not rehearsed there: the 7bcd97c2 payout *reservation* (its connected-account readiness check differs for the fixture account, so it stops before the fence); `spec/services/never_fulfilled_payout_evidence_spec.rb` runs it verbatim in-process instead. The rehearsal needs no Stripe test mode and makes no network call.

**The previous release's own specs on this schema** (`rehearse_previous_release.sh`, M-01). It loads this branch's `db/schema.rb` with the old app and runs the old refund, late-capture, payout and webhook specs. The acceptable failures are fence and evidence-guard refusals (`Repayment fence`, `Sale ownership`, `Evidence hold`). The script drops its database unless `KEEP_DB=1`.

The new suite also runs the verbatim 7bcd97c2 `RefundCreator`, `LateCaptureRefund`, `PayoutCreator`, `PayoutReconciler`, `Settlements::Finalizer`, `Settlements::Calculator` and `OrganizationPayoutBalance` (`spec/support/legacy_7bcd97c2/`) against the new schema, including two-connection races.

## Rollback

Never run down migrations in production. Each rollback below keeps every trigger in the database, and the code being rolled back to never removes them.

- **A1-R2 → A1-R1.** Same schema. The submitter is inactive again, and the fence holds. An operation left `submitting` or `unknown` is adjudicated by lookup and is never resent by R1.
- **A1-R1 → 7bcd97c2.** Same schema; permitted only because the guards stay. Old code then cannot submit for fenced payments, cannot change a sale from a payment that does not own it, cannot submit, record as paid or finalize on a held event, cannot finalize or create payouts on an event with a never-fulfilled order in a sale status (its calculator disagrees), cannot close an evidence hold by note, and cannot bind a fenced payment's refund. Each of those fails closed; refused webhooks stay `failed` with their signed receipts. Classification, holds and adjudication stop, and finance handles repayment through the reconciliation queue until R1 is redeployed. Old readers still show 7bcd97c2's CPA figures and admission rule (an open or lost dispute on any payment blocks admission) during that time; neither moves money.

Locally, the A1 migrations roll back cleanly (`db:migrate:down` removes the triggers, functions, table and columns) and reapply. That proves the schema round trip only. It is not a production procedure.
