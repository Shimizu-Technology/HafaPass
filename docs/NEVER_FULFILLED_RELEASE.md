# Never-fulfilled captures: A1 release runbook

This runbook covers the two A1 releases of [the never-fulfilled design](./design/never-fulfilled-captures.md) (§10). Home base runs the production release and every production command below. Agents never read or change production data. Every command here is read-only, except the deploys themselves. Nothing here changes an environment variable, a `SiteSetting` or Render configuration. Nothing makes a real charge or repairs a production row by hand.

## What each release does

| Release | Change | Money it can send for a fenced payment |
| --- | --- | --- |
| **A1-R1** (merge of #248) | Migrations `20261126100000`…`20261126120200`: classification, postings, repayment operations, and the database **repayment fence** on `refunds` and `payouts`. `Commerce::BuyerRepayment::SUBMITTER_ACTIVE = false`. | None. R1 reserves no repayment operation and never passes the operation gate. It can look up an older release's refund by its key and record the result (`Commerce::RepaymentAdjudication`). |
| **A1-R2** (small follow-up PR) | Changes `SUBMITTER_ACTIVE` to `true` and the specs that assert R1 behaviour. Nothing else. | One repayment operation at a time per payment, sized under the order lock and rechecked at the gate. |

A *fenced payment* has a `never_fulfilled_captures` row or an exception with one of these codes: `late_payment_success_after_inventory_release`, `late_payment_success_after_hold_expiry`, `pass_all_included_nights_cancelled`, `unfulfilled_second_capture`, `never_fulfilled_ownership_ambiguous` or `never_fulfilled_classification_quarantined`. The open or resolved status of the exception does not matter. The database function `hafapass_fenced_payment(payment_id)` is the single definition, and the application uses the same function.

## The fence (installed by R1's pre-deploy migration)

`bin/release-migrate` runs before any R1 process starts, so the fence exists before the overlap begins.

- **`refunds_repayment_fence`** rejects two things for a fenced payment. The first is a new outbound reservation: a row with no provider refund ID, no repayment operation and a key that is not `provider:stripe:refund:*`. The second is the last local gate: moving such a row's `failure_code` to `provider_result_unknown`, which 7bcd97c2 persists immediately before its Stripe POST. A row that belongs to a repayment operation passes the gate only while that operation is `submitting`, and only `Commerce::BuyerRepayment.gate!` sets that. The fence never rejects provider evidence: inbound rows keyed `provider:stripe:refund:<id>`, rows that carry a provider refund ID, and outcomes of a row already past the gate.
- **`payouts_repayment_fence`** rejects creating a payout as `pending` or `processing`, releasing a held payout, and submitting a pending one, on an event with an open blocking never-fulfilled item. `never_fulfilled_buyer_overpaid` never blocks (P4). The application checks the same rule first (`Commerce::NeverFulfilledPayoutHold`) and also guards paid recording. A transfer that left before a cancellation can still be recorded with the existing confirmation.

An old worker that hits the fence fails before any network call. Its job retries and fails again. Its exception stays open, which keeps the event's payouts and finalization blocked.

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

Also record the sha256 of the CPA and BPT CSVs for every month with live activity, using the existing admin exports. A1 changes no reader, so these hashes must not change.

## After A1-R1 is live

Use the read-only rake task. It runs the same SQL in one `READ ONLY` transaction and rolls it back:

```sh
bin/rails never_fulfilled:release_evidence R1_SHA=<40-hex R1 commit> R1_LIVE_AT=<ISO-8601 UTC time R1 went live>
bin/rails never_fulfilled:verify                        # read-only reconcile counts
bin/rails never_fulfilled:reconcile                     # DRY_RUN=1 is the default: counts only
```

`psql` gives the same output: `psql "$READ_ONLY_DATABASE_URL" -v r1_sha=... -v r1_live_at=... -v bound_seconds=770 -f hafapass_api/script/never_fulfilled/release_evidence.sql`. The bound is `Commerce::BuyerRepayment.in_flight_bound`, which is 770 seconds with the current `config/initializers/stripe.rb` values. Read it from the code if those values change.

Check:

- `triggers` lists all 16 triggers, including `refunds_repayment_fence`, `payouts_repayment_fence` and `repayment_operations_check`.
- `unvalidated_constraints` is empty, and `cutovers` contains `a1_capture_recording`, `a1_return_recording` and `a1_repayment_fence`.
- `payouts_on_blocked_events.changed_since_r1` is 0 for every row.

Disposition the reconcile dry run's quarantined and restatement counts as §4.5 requires. No restatement is ever written.

## Release boundary for A1-R2

Deploy R2 only when items 1, 2, 4 and 5 hold, and either 3a or the fence alternative.

1. **Writers and fence present.** The evidence run shows every trigger, validated constraints and the three cutovers. CI passed on the R1 head, including `spec/models/repayment_fence_spec.rb` and `spec/services/commerce/buyer_repayment_concurrency_spec.rb` (M-05…M-08), plus the previous-release rehearsal below.
2. **No new submitter during the overlap.** This is a property of the R1 code: `SUBMITTER_ACTIVE = false`, and the specs that run as R1 assert zero POSTs. It is not a runtime setting.
3. **Old processes gone.**
   - (a) Render, read-only, through home base: the R1 deploy is `live`, every earlier deploy is `deactivated`, no instance runs an earlier commit, and more than Render's shutdown grace has passed since R1 went live.
   - (b) `live_processes` shows only `other_revision = f`, and `claimed_by_other_revision` is 0. `runtime_ticks` shows recent R1 ticks for every required task.
4. **Durable work audited.**
   - `refund_jobs_before_r1` is empty: no unfinished `LateCaptureRefundJob`, `EventCancellationRefundJob` or `RefundReconciliationJob` was enqueued before R1 went live.
   - `legacy_refunds_on_fenced_payments` is empty. Each such refund has been adjudicated by a lookup at Stripe that ran after its `adjudicable_after` time. R1 enqueues `RepaymentAdjudicationJob` for each one when a repayment waits on it, or when an administrator uses **Refund buyer**. The job retries itself until the bound passes. A row with `adjudicable = f` may still land at Stripe and is never treated as absent.
   - `never_fulfilled:verify` reports `unclassified_or_unposted=0` and `unposted_movement_payments=0`.
5. **Payouts fail closed.** Events with open blocking items still show them. No payout on them moved since R1 (`changed_since_r1 = 0`).

**If 3a is unavailable** (Render listings cannot be read), R2 may still be deployed when 1, 2, 3b, 4 and 5 hold. The fence was installed before any R1 process started, and it rejects every old reservation and every old last-gate transition. The only old requests that can exist were already past the gate before the migration committed, and item 4 adjudicates them. Record in the PR that 3a was unavailable and that the fence argument was used instead.

### The R2 change, exactly

- `hafapass_api/app/services/commerce/buyer_repayment.rb`: `SUBMITTER_ACTIVE = false` becomes `SUBMITTER_ACTIVE = true`.
- Specs: examples that assert R1 behaviour (`"A1-R1"` describe blocks and `sends nothing in A1-R1` examples) either move under `repayment_submitter: :active` or are deleted. The `repayment_submitter: :active` tag becomes the default.
- No migration, setting, environment variable or other code change. If R2 needs more than this, it is a different release and needs its own review.

## Two-version rehearsal (before each production deploy)

On a task-owned localhost database:

```sh
REHEARSAL_DIR=<scratch dir> REHEARSAL_DB=hafapass_ncap_rehearsal_<name> \
  hafapass_api/script/never_fulfilled/rehearse_previous_release.sh
```

This is M-01. The script exports 7bcd97c2 with `git archive` (no checkout), loads this branch's `db/schema.rb` with the old app, and runs the old refund, late-capture, payout and webhook specs. The only acceptable failures are fence refusals. On `06bba3b4`: 219 examples, 9 failures, all `Repayment fence` refusals of an old late-capture refund, and no other failures. The script drops its database unless `KEEP_DB=1`.

The new suite covers M-05…M-08 by running the verbatim 7bcd97c2 `RefundCreator` and `LateCaptureRefund` (`spec/support/legacy_7bcd97c2/`) against the new schema. Those specs cover reservation, a pre-fence reservation's gate, a request past the gate, inbound refunds, and two-connection races between an old and a new worker.

## Rollback

Never run down migrations in production. Each rollback below keeps the fence and triggers in the database.

- **A1-R2 → A1-R1.** The submitter is inactive again, and the fence holds. An operation left `submitting` or `unknown` is adjudicated by lookup and is never resent by R1.
- **A1-R1 → 7bcd97c2.** This is permitted only because the fence and triggers stay in place. Old code then cannot submit for fenced payments or move payouts on affected events, so both fail closed. Classification stops, and finance handles repayment through the reconciliation queue until R1 is redeployed.

Locally, the three tranche 4 migrations roll back cleanly (`db:migrate:down` removes the triggers, functions, table and columns) and reapply. That proves the schema round trip only. It is not a production procedure.
