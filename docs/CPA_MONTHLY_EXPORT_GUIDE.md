# How to Read the Monthly CPA Custodial & BPT CSV Export

**Audience:** CPA and platform finance admin.
**Status:** Preparation aid only — not a filed Guam BPT (Form GRT-1) or income tax return. Fee-only BPT treatment and organizer-vs-platform tax allocations are working positions for CPA and Guam counsel confirmation, not settled tax rulings.

## Where to download it

1. Open **Admin → Tax reports** (`/admin/tax-reports`).
2. Select the **Calendar year** and **Guam calendar month** (`Pacific/Guam`, ChST, UTC+10 year-round, no daylight saving time).
3. Review the on-screen summary separating **Custodial liability (organizer proceeds)** from **HåfaPass fee revenue & Guam BPT estimate**, then click **Export monthly CPA CSV**.
4. The file downloads as `hafapass-cpa-monthly-YYYY-MM.csv` (`Cache-Control: no-store`). Every download is audit-logged (`tax_report.exported` with `export: "monthly_cpa_custodial_bpt"`).

## Recording-time period-stability rule, scope, and privacy

- **Recording-time immutability (closed months stay byte-identical):** A closed Guam calendar month is defined strictly by **recording time** — the month each immutable ledger row or append-only audit row was created — **never** by a back-dated confirmation/effective date supplied later, **never** by a current mutable status (such as `stripe_fee_evidences.status` or `disputes.status`), and **never** by a mutable column like `updated_at`:
  - **Paid payouts (`organizer_payouts_made`):** Recorded in the Guam month the payout's append-only paid audit (`payout.reconciled` → `paid` or `payout.paid`) was recorded (falling back to `payouts.paid_at` only for direct/legacy payouts without a paid audit row). Covers **every** live (non-simulated) USD payout on every recognized event/organization, independent of whether a Stripe order exists.
  - **Payout reversals (`payout_reversals`):** Recorded strictly in the Guam month the earliest append-only reversal audit row (`payout.reconciled` → `reversed` or `payout.reversed`) was recorded (`COALESCE(rev_audit.occurred_at, rev_audit.created_at)`). User-supplied bank `confirmed_at` dates never rewrite an earlier closed month, and the report **never** falls back to mutable `payouts.updated_at`. If a reversed payout has no reversal audit row, it is **not** booked into an arbitrary month; instead it triggers `reconciliation_exception_flag = yes` with `reconciliation_exception_note` explaining `"Reversed payout missing audit evidence ($X.XX)"`.
  - **Actual Stripe processing fees (`organizer_processing_deducted`, `stripe_processing_costs_informational`):** Dated strictly by the immutable append-only `FeeComponent` recording timestamp (`fee_components.created_at`), completely independent of current mutable `stripe_fee_evidences.status` (e.g., if evidence later moves to `review_required`, no prior closed month changes).
  - **Balance adjustments & reserves (`other_adjustments`, `reserve_held`, `reserve_released`):** Dated by `GREATEST(balance_adjustments.created_at, balance_adjustments.effective_at)` (never back-dated into a closed month via a past `effective_at`), and scoped by immutable payment custody (`order_id` in live Stripe orders or `NULL`; `dispute_id` in live Stripe disputes or `NULL`, completely independent of whether the dispute is currently `open`, `won`, or `lost`).
  - **Lost disputes (`chargebacks`):** Dated by `COALESCE(dispute_lost_audit.occurred_at, dispute_lost_audit.created_at, disputes.closed_at, disputes.created_at)` — never mutable `disputes.updated_at`.
  - **Prior-period relation labels (`prior_period_note`):** When a movement recorded in Month M relates to an earlier closed month (for example, a November payout reversal whose bank evidence or original payout was in October, a processing fee recorded in November for an October order, or a November adjustment back-dated to October), Month M includes the movement and labels it in `prior_period_note` (e.g., `"Payout reversal relates to Oct 2026"`), while October stays **byte-identical**.
- **Live USD Stripe agent captures + all recognized custodial/settlement activity:** Custodial columns include completed/partially-refunded/refunded orders backed by live (or legacy non-test, non-simulated) USD Stripe captures, all in-scope USD `BalanceAdjustment`s (including adjustment-only events and organization-level `event_id: nil` adjustments), and all live USD payouts (including payouts on adjustment-only or non-Stripe events). Test, simulated, organizer-retained door cash, organizer-direct Clover sales, and non-USD orders are excluded from custodial liability. Non-custodial non-cash sales (and any settlement adjustments or disputes linked to non-custodial orders/payments) are bridged in `non_custodial_settlement_bridge` across **all** events, including Clover-only events.
- **No PII:** Rows identify organizations and events strictly by numeric `organization_id` and `event_id`. No organizer names, event titles, buyer names, emails, addresses, or TINs appear in the file.
- **Spreadsheet-safe:** Formula-like text values are neutralized; signed numeric amounts remain plain decimal numbers (`-1.10`) so spreadsheet sums work directly.
- **Included rows:** Candidate events are built as the union of **every** activity source (custodial sales/refunds/chargebacks/processing, adjustments, payouts, reversals, missing-audit exceptions, and non-custodial settlement bridge). Every month ends with one `row_type = total` row (all `$0.00` on a zero-activity month).

## Column reference

### 1. Identification & Nonprofit Status (No PII)

| Column | Meaning |
|---|---|
| `row_type` | `event` for an individual event (or org-level adjustment row with blank `event_id`); `total` for the final summary row. |
| `month` | Guam calendar month (`YYYY-MM`). |
| `organization_id` | Internal organization ID (blank on `total`). |
| `event_id` | Internal event ID (blank on `total` or org-level unattributed adjustments). |
| `w9_nonprofit_classification` | `yes` if the organization's **current W-9 at export time** (`OrganizerTaxInformation`) has `tax_classification = "nonprofit"`; `no` otherwise (blank on `total`). **This is the current W-9 self-classification at export time — it is NOT a historical as-of-month snapshot and NOT a Guam DRT BPT exemption.** |
| `drt_exemption_verified` | Always `not_tracked` until verified DRT document tracking is implemented in HåfaPass. Never filter `w9_nonprofit_classification = yes` as DRT-verified exempt without external DRT certificate review. |
| `nonprofit_exemption_note` | Reminds the CPA `"W-9 nonprofit (current at export time); DRT exemption not tracked — verify externally"` on W-9 nonprofit rows (or total W-9 nonprofit count on `total`). |

### 2. Custodial Liability Roll-Forward (Balance Sheet — Organizer Funds Held in Custody)

Under our working position (pending CPA/counsel confirmation), these funds belong to the event organizers, **not** Shimizu Technology LLC revenue.

| Column | Timing (Guam time) | Meaning |
|---|---|---|
| `opening_custodial_liability` | Before 1st of month | Organizer proceeds held by HåfaPass at the start of the month (equals prior month's `closing_custodial_liability`). Includes adjustment-only events/orgs. |
| `proceeds_collected` | Order completion month | Organizer proceeds from tickets (and any add-ons/donations), net of discounts and organizer-absorbed service fees. |
| `proceeds_refunded` | Refund success month | Allocated organizer proceeds returned to buyers on succeeded refunds (`RefundItem.organizer_proceeds_cents`; subtracted from liability). |
| `chargebacks` | Dispute-lost recording month | Lost Stripe disputes (`disputes.payment_id` → live Stripe capture) debited against organizer proceeds (subtracted from liability). |
| `organizer_processing_deducted` | `FeeComponent.created_at` month | Actual Stripe card processing deducted from organizer proceeds, dated strictly by immutable `fee_components.created_at` (independent of current `stripe_fee_evidences.status`). Uses the exact `Settlements::Calculator` split. |
| `other_adjustments` | Adjustment recording month (`GREATEST(created_at, effective_at)`) | Net posted/reversed non-reserve balance adjustments scoped by immutable payment custody (independent of dispute status; signed; added to liability). |
| `organizer_payouts_made` | Payout recording month | Gross live USD payouts (`amount_cents`) recorded as paid in the month across all recognized events (including adjustment-only events; subtracted from liability). Pending, failed, held, and simulated payouts are excluded. |
| `payout_reversals` | Reversal audit recording month | Gross amount of previously paid payouts reversed in the month, dated strictly by the append-only reversal audit row's recording time (added back to custodial liability). Keeps the original paid month byte-identical. |
| `closing_custodial_liability` | End of month | Signed net custodial roll-forward balance at month-end (includes held reserves). |
| `closing_custodial_payables` | End of month (Balance Sheet Liability) | **Total owed BY HåfaPass to organizers.** On `total`, summed **per organization** (`SUM over orgs of MAX(org_net_closing, 0)`): positive and negative event balances offset **only within the same `organization_id`**, never netting unrelated organizers against one another. |
| `closing_organizer_deficits` | End of month (Balance Sheet Receivable) | **Total owed TO HåfaPass by organizers** (negative balances from post-payout refunds/chargebacks). On `total`, summed **per organization** (`SUM over orgs of MAX(-org_net_closing, 0)`). Exact check: `closing_custodial_payables - closing_organizer_deficits = closing_custodial_liability`. |

**Horizontal roll-forward identity (exact on every row and on `total`):**

```text
closing_custodial_liability
  = opening_custodial_liability
  + proceeds_collected
  - proceeds_refunded
  - chargebacks
  - organizer_processing_deducted
  + other_adjustments
  - organizer_payouts_made
  + payout_reversals
```

### 3. Reserve, Reconciliation Exceptions, Prior-Period Notes, Settlement Bridge & Withholding Memos

| Column | Meaning |
|---|---|
| `reserve_held` | New `reserve_hold` balance adjustments recorded in the month (e.g., ~10% post-event holdback). Shown as a positive amount. |
| `reserve_released` | `reserve_release` balance adjustments recorded in the month (e.g., 30-day release). Shown as a positive amount. |
| `ending_reserve_balance` | Cumulative net reserve still held at month-end. **Note:** Held reserves are *part of* `closing_custodial_liability`, restricting how much is currently payable. |
| `unallocated_refunds_exception` | In-month succeeded Stripe refunds whose `refunds.amount_cents` exceeds `SUM(refund_items.amount_cents)` (e.g., legacy refunds created without `RefundItem` allocations). |
| `cumulative_unallocated_refunds_exception` | Cumulative unallocated legacy refunds through month-end (the cumulative balance that triggers `reconciliation_exception_flag` even in later months where in-month unallocated refunds are `$0.00`). |
| `reconciliation_exception_flag` | `yes` if the row has any in-month or cumulative unallocated legacy refunds **or** a reversed payout missing append-only reversal audit evidence; `no` otherwise. |
| `reconciliation_exception_note` | Plain-language summary of every exception triggering `reconciliation_exception_flag` (cumulative and in-month unallocated legacy refunds, and/or reversed payout missing audit evidence). |
| `prior_period_note` | Labels any movement recorded in this month that relates to an earlier closed Guam month (e.g., `"Payout reversal relates to Oct 2026"`, `"Processing fee relates to Oct 2026"`, `"Adjustment relates to Oct 2026"`, `"Payout relates to Oct 2026"`). Blank when all in-month movements belong to the current month. |
| `non_custodial_settlement_bridge` | Cumulative net settlement-only activity on the event that appears in `Settlements::Calculator` but is **not** held in HåfaPass Stripe custody: organizer-direct `boh_clover` card-present sales minus their refunds/processing/disputes, non-agent disputes, and event-level settlement adjustments linked to non-custodial orders or non-agent disputes. Populated even on Clover-only events with zero Stripe sales. Always `$0.00` for pure online Stripe events. |
| `backup_withholding_memo` | Net backup withholding (`withheld_cents + carried_withholding_cents`) from payouts recorded as paid in the month minus payouts reversed in the month. Track separately as a tax-withholding remittance liability until deposited. |

**Exact reconciliation to organizer payout statements (`Settlements::Calculator`):**

For any event (pure Stripe, adjustment-only, Clover-only, or mixed-tender Stripe + Clover + door cash + linked adjustments) whose activity was recorded on or before month-end (and with zero reconciliation exceptions):
1. Compute `Settlements::Calculator`'s true signed unpaid balance **without double-counting shortfalls**:
   - If `negative_balance_cents > 0`: `unpaid_balance = -negative_balance_cents`
   - Otherwise: `unpaid_balance = payable_cents - paid_cents`
   *(Equivalently: `organizer_proceeds_cents - processing_fee_cents - reserve_cents + adjustment_cents - paid_cents`.)*
2. Then:
   ```text
   closing_custodial_liability - ending_reserve_balance + non_custodial_settlement_bridge
     == Settlements::Calculator unpaid_balance
   ```
3. And `ending_reserve_balance == Settlements::Calculator reserve_cents`.

### 4. HåfaPass Fee Revenue & Guam BPT Estimate (Income Statement — Shimizu Technology LLC)

| Column | Timing (Guam time) | Meaning |
|---|---|---|
| `fee_revenue_gross` | Order completion month | Gross HåfaPass ticketing service fees (both buyer-paid and organizer-absorbed). |
| `fee_refunds` | Refund success month | Allocated HåfaPass service fees returned on succeeded refunds (`fee_cents + organizer_fee_cents`). |
| `fee_revenue_net` | Monthly net | `fee_revenue_gross - fee_refunds`. Can be negative in a month where cross-month refunds exceed new fees. |
| `stripe_processing_costs_informational` | `FeeComponent.created_at` month | Total actual (non-estimated) Stripe processing costs recorded in the month (`fee_components.created_at`), independent of current `stripe_fee_evidences.status`. **Informational expense only** — does not reduce Guam BPT gross receipts. |
| `bpt_base_fee_revenue_estimate` | Monthly net | Working BPT base equal to `fee_revenue_net` under the fee-only working position (confirm with CPA). |
| `estimated_bpt_rate_pct` | Statutory rate schedule | Under [Public Law 38-136](https://guamlegislature.gov/38th_Guam_Legislature/Public_Laws_38th/Public%20Law%2038-136.pdf) amending 11 GCA § 26202(c), the statutory service-business BPT rate is **`4.50`%** from **October 1, 2025** and **`4.00`%** from **October 1, 2026**. Periods from **April 1, 2018 – September 30, 2025** show the historical **`5.00`%** rate (P.L. 34-87). Periods **before April 2018** emit **`not_supported`** (and blank estimated BPT) — confirm historical rates with the CPA. Estimate only; does not apply conditional § 26203.2 3% small-business relief. |
| `estimated_bpt_on_fee_revenue_estimate` | **Estimate only** | Estimated Guam BPT on `MAX(bpt_base_fee_revenue_estimate, 0)` at `estimated_bpt_rate_pct` (half-up cent rounding; `$0.00` when an event's net fee base is negative; blank for pre-April 2018 `not_supported` periods). |
| `currency` | Always `USD` | Reporting currency. |

## Important CPA reminders

- **Why event-level BPT estimates do not always sum to the `total` row BPT estimate:** Each `event` row floors `estimated_bpt_on_fee_revenue_estimate` at `$0.00` when `fee_revenue_net` is negative (for example, an event with cross-month refunds and no new sales). On the `total` row, Guam Form GRT-1 is computed at the **entity level** on `MAX(SUM(bpt_base_fee_revenue_estimate), 0)`, where negative net-fee events offset positive net-fee events in the same filing month (plus up to ±$0.01/row half-up rounding differences). Therefore, when any event has negative net fees, the sum of event-row estimates will be higher than the entity-level `total` estimate.
- **W-9 nonprofit classification (current at export time) vs. Guam DRT exemption & HåfaPass fees:** `w9_nonprofit_classification = yes` reflects the organizer's **current** W-9 federal tax classification at export time (not a historical snapshot as of the reporting month); `drt_exemption_verified` is always `not_tracked` until verified DRT tracking is added. Confirm DRT exemption certificates externally. Under our working position (confirm with CPA), HåfaPass's own service fees on nonprofit events remain in Shimizu Technology LLC's BPT base.
- **Legacy BPT event CSV:** The earlier compact CSV (`Export monthly BPT detail CSV` / `bpt_events_export` from PR #223) remains available for quick cross-checking, while `Export monthly CPA CSV` (`cpa_monthly_export`) is the complete recording-time period-stable monthly reconciliation workpaper.
