# How to Read the Monthly CPA Custodial & BPT CSV Export

**Audience:** CPA and platform finance admin.
**Status:** Preparation aid only — not a filed Guam BPT (Form GRT-1) or income tax return. Fee-only BPT treatment and organizer-vs-platform tax allocations are working positions for CPA and Guam counsel confirmation, not settled tax rulings.

## Where to download it

1. Open **Admin → Tax reports** (`/admin/tax-reports`).
2. Select the **Calendar year** and **Guam calendar month** (`Pacific/Guam`, ChST, UTC+10 year-round, no daylight saving time).
3. Review the on-screen summary separating **Custodial liability (organizer proceeds)** from **HåfaPass fee revenue & Guam BPT estimate**, then click **Export monthly CPA CSV**.
4. The file downloads as `hafapass-cpa-monthly-YYYY-MM.csv` (`Cache-Control: no-store`). Every download is audit-logged (`tax_report.exported` with `export: "monthly_cpa_custodial_bpt"`).

## Period-stability, scope, and privacy

- **Period-stable closed months:** Movements are dated by ledger/occurrence timestamps rather than current mutable record state, so regenerating a closed month produces identical numbers even after later events happen:
  - A payout paid in October (`paid_at` in Oct) stays in October's `organizer_payouts_made` even if reversed in November; the reversal appears in November's `payout_reversals` (dated by the reversal confirmation timestamp in `payout.reconciled` audit evidence, fallback `payouts.updated_at`).
  - Actual Stripe card-processing costs (`FeeComponent` `kind: "processing", estimated: false`) appear in the Guam month the provider fee evidence is verified/recorded (`COALESCE(stripe_fee_evidences.verified_at, fee_components.created_at)`), so late-arriving evidence never rewrites a prior closed month.
- **Live USD Stripe agent captures only (plus in-scope adjustments):** Custodial columns include completed/partially-refunded/refunded orders backed by live (or legacy non-test, non-simulated) USD Stripe captures, plus posted/reversed USD `BalanceAdjustment`s (including adjustment-only events and organization-level `event_id: nil` adjustments). Test, simulated, organizer-retained door cash, organizer-direct Clover sales, and non-USD orders are excluded from custodial liability (non-custodial non-cash sales that appear in `Settlements::Calculator` are bridged separately in `non_custodial_settlement_bridge`).
- **Disputes scoped by payment:** Lost disputes enter custodial `chargebacks` only when `disputes.payment_id` points to a live USD Stripe capture (or legacy `payment_id IS NULL` on a Stripe agent order with `provider = "stripe"`). Disputes on test, simulated, or non-Stripe payments never enter custodial chargebacks.
- **No PII:** Rows identify organizations and events strictly by numeric `organization_id` and `event_id`. No organizer names, event titles, buyer names, emails, addresses, or TINs appear in the file.
- **Spreadsheet-safe:** Formula-like text values are neutralized; signed numeric amounts remain plain decimal numbers (`-1.10`) so spreadsheet sums work directly.
- **Included rows:** Every event or org-level adjustment row with a non-zero opening custodial liability, ending reserve, unallocated refund exception, settlement bridge, or in-month activity appears as `row_type = event`. Every month ends with one `row_type = total` row (all `$0.00` on a zero-activity month).

## Column reference

### 1. Identification & Nonprofit Status (No PII)

| Column | Meaning |
|---|---|
| `row_type` | `event` for an individual event (or org-level adjustment row with blank `event_id`); `total` for the final summary row. |
| `month` | Guam calendar month (`YYYY-MM`). |
| `organization_id` | Internal organization ID (blank on `total`). |
| `event_id` | Internal event ID (blank on `total` or org-level unattributed adjustments). |
| `w9_nonprofit_classification` | `yes` if the organization's certified W-9 (`OrganizerTaxInformation`) has `tax_classification = "nonprofit"`; `no` otherwise (blank on `total`). **This is a W-9 self-classification only — it is NOT a Guam DRT BPT exemption.** |
| `drt_exemption_verified` | Always `not_tracked` until verified DRT document tracking is implemented in HåfaPass. Never filter `w9_nonprofit_classification = yes` as DRT-verified exempt without external DRT certificate review. |
| `nonprofit_exemption_note` | Reminds the CPA `"W-9 nonprofit; DRT exemption not tracked — verify externally"` on W-9 nonprofit rows (or total W-9 nonprofit count on `total`). |

### 2. Custodial Liability Roll-Forward (Balance Sheet — Organizer Funds Held in Custody)

Under our working position (pending CPA/counsel confirmation), these funds belong to the event organizers, **not** Shimizu Technology LLC revenue.

| Column | Timing (Guam time) | Meaning |
|---|---|---|
| `opening_custodial_liability` | Before 1st of month | Organizer proceeds held by HåfaPass at the start of the month (equals prior month's `closing_custodial_liability`). Includes adjustment-only events/orgs. |
| `proceeds_collected` | Order completion month | Organizer proceeds from tickets (and any add-ons/donations), net of discounts and organizer-absorbed service fees. |
| `proceeds_refunded` | Refund success month | Allocated organizer proceeds returned to buyers on succeeded refunds (`RefundItem.organizer_proceeds_cents`; subtracted from liability). |
| `chargebacks` | Dispute lost/closed month | Lost Stripe disputes (`disputes.payment_id` → live Stripe capture) debited against organizer proceeds (subtracted from liability). |
| `organizer_processing_deducted` | Processing evidence month | Actual Stripe card processing deducted from organizer proceeds, dated by `COALESCE(stripe_fee_evidences.verified_at, fee_components.created_at)` (usually `$0.00` under platform-absorbed ticket terms; nonzero on legacy/organizer-bearer orders or mixed-cart add-ons/donations). Uses the exact `Settlements::Calculator` split. |
| `other_adjustments` | Adjustment effective month | Net posted non-reserve balance adjustments (e.g., manual credits/debits, signed; added to liability). |
| `organizer_payouts_made` | Payout `paid_at` month | Gross payouts (`amount_cents`) paid in the month (`status IN (paid, reversed)` with `paid_at` in month; subtracted from liability). Pending, failed, and held payouts are excluded. |
| `payout_reversals` | Reversal confirmation month | Gross amount of previously paid payouts reversed in the month (added back to custodial liability). Keeps the original paid month immutable. |
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

### 3. Reserve, Reconciliation Exception, Settlement Bridge & Withholding Memos

| Column | Meaning |
|---|---|
| `reserve_held` | New `reserve_hold` balance adjustments effective in the month (e.g., ~10% post-event holdback). Shown as a positive amount. |
| `reserve_released` | `reserve_release` balance adjustments effective in the month (e.g., 30-day release). Shown as a positive amount. |
| `ending_reserve_balance` | Cumulative net reserve still held at month-end. **Note:** Held reserves are *part of* `closing_custodial_liability`, restricting how much is currently payable. |
| `unallocated_refunds_exception` | Succeeded Stripe refunds in the month whose `refunds.amount_cents` exceeds `SUM(refund_items.amount_cents)` (e.g., legacy refunds created without `RefundItem` allocations). Surfaced explicitly instead of silently computing `$0.00`; requires manual CPA split between organizer proceeds and fee refunds. |
| `reconciliation_exception_flag` | `yes` if the row has any in-month or cumulative unallocated refund exception; `no` otherwise. |
| `non_custodial_settlement_bridge` | Cumulative net settlement-only activity on the event that appears in `Settlements::Calculator` but is **not** held in HåfaPass Stripe custody (for example, organizer-direct `boh_clover` card-present sales minus their refunds/disputes, or non-agent disputes). Always `$0.00` for pure online Stripe events. |
| `backup_withholding_memo` | Net backup withholding (`withheld_cents + carried_withholding_cents`) from payouts paid in the month minus payouts reversed in the month. Track separately as a tax-withholding remittance liability until deposited. |

**Exact reconciliation to organizer payout statements (`Settlements::Calculator`):**

For any event whose activity occurred on or before month-end (and with zero unallocated refund exceptions):
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
| `stripe_processing_costs_informational` | Processing evidence month | Total actual (non-estimated) Stripe processing costs whose evidence was verified/recorded in the month (`COALESCE(verified_at, created_at)`). **Informational expense only** — does not reduce Guam BPT gross receipts. |
| `bpt_base_fee_revenue_estimate` | Monthly net | Working BPT base equal to `fee_revenue_net` under the fee-only working position (confirm with CPA). |
| `estimated_bpt_rate_pct` | Statutory rate schedule | Under [Public Law 38-136](https://guamlegislature.gov/38th_Guam_Legislature/Public_Laws_38th/Public%20Law%2038-136.pdf) amending 11 GCA § 26202(c), the statutory service-business BPT rate is **`4.50`%** from **October 1, 2025** and **`4.00`%** from **October 1, 2026** (periods before October 1, 2025 show the historical **`5.00`%** prior statutory rate). Estimate only; does not apply conditional § 26203.2 3% small-business relief. |
| `estimated_bpt_on_fee_revenue_estimate` | **Estimate only** | Estimated Guam BPT on `MAX(bpt_base_fee_revenue_estimate, 0)` at `estimated_bpt_rate_pct` (half-up cent rounding; `$0.00` when an event's net fee base is negative). |
| `currency` | Always `USD` | Reporting currency. |

## Important CPA reminders

- **Why event-level BPT estimates do not always sum to the `total` row BPT estimate:** Each `event` row floors `estimated_bpt_on_fee_revenue_estimate` at `$0.00` when `fee_revenue_net` is negative (for example, an event with cross-month refunds and no new sales). On the `total` row, Guam Form GRT-1 is computed at the **entity level** on `MAX(SUM(bpt_base_fee_revenue_estimate), 0)`, where negative net-fee events offset positive net-fee events in the same filing month (plus up to ±$0.01/row half-up rounding differences). Therefore, when any event has negative net fees, the sum of event-row estimates will be higher than the entity-level `total` estimate.
- **W-9 nonprofit classification vs. Guam DRT exemption & HåfaPass fees:** `w9_nonprofit_classification = yes` reflects only the organizer's W-9 federal tax classification; `drt_exemption_verified` is always `not_tracked` until verified DRT tracking is added. Confirm DRT exemption certificates externally. Under our working position (confirm with CPA), HåfaPass's own service fees on nonprofit events remain in Shimizu Technology LLC's BPT base.
- **Legacy BPT event CSV:** The earlier compact CSV (`Export monthly BPT detail CSV` / `bpt_events_export` from PR #223) remains available for quick cross-checking, while `Export monthly CPA CSV` (`cpa_monthly_export`) is the complete period-stable monthly reconciliation workpaper.
