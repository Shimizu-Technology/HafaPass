# How to Read the Monthly CPA Custodial & BPT CSV Export

**Audience:** CPA and platform finance admin.
**Status:** Preparation aid only — not a filed Guam BPT (Form GRT-1) or income tax return.

## Where to download it

1. Open **Admin → Tax reports** (`/admin/tax-reports`).
2. Select the **Calendar year** and **Guam calendar month** (`Pacific/Guam`, ChST, UTC+10 year-round, no daylight saving time).
3. Review the on-screen summary separating **Custodial liability (organizer proceeds)** from **HåfaPass fee revenue & Guam BPT estimate**, then click **Export monthly CPA CSV**.
4. The file downloads as `hafapass-cpa-monthly-YYYY-MM.csv` (`Cache-Control: no-store`). Every download is audit-logged (`tax_report.exported` with `export: "monthly_cpa_custodial_bpt"`).

## Scope and privacy

- **Live USD Stripe agent captures only:** Includes completed/partially-refunded/refunded orders backed by live (or legacy non-test, non-simulated) USD Stripe captures, because only those funds settle into Shimizu Technology LLC's account. Test, simulated, organizer-retained door cash, organizer-direct Clover sales, and non-USD orders are excluded.
- **No PII:** Rows identify organizations and events strictly by numeric `organization_id` and `event_id`. No organizer names, event titles, buyer names, emails, addresses, or TINs appear in the file.
- **Spreadsheet-safe:** Formula-like text values are neutralized; signed numeric amounts remain plain decimal numbers (`-1.10`) so spreadsheet sums work directly.
- **Included rows:** Every event with either a non-zero opening custodial liability, a non-zero ending reserve balance, or any financial activity during the month appears as a `row_type = event` row. A month always ends with one `row_type = total` row (showing all `$0.00` on a zero-activity month).

## Column reference

### 1. Identification & Nonprofit Flag

| Column | Meaning |
|---|---|
| `row_type` | `event` for an individual event (or org-level adjustment row with blank `event_id`); `total` for the final summary row. |
| `month` | Guam calendar month (`YYYY-MM`). |
| `organization_id` | Internal organization ID (blank on `total`). |
| `event_id` | Internal event ID (blank on `total` or org-level unattributed adjustments). |
| `nonprofit_exempt_flag` | `yes` if the organization's certified W-9 (`OrganizerTaxInformation`) has `tax_classification = "nonprofit"`; `no` otherwise. |
| `nonprofit_exemption_note` | Reminds the CPA `"W-9 nonprofit; verify DRT exemption"` on flagged rows (or total flagged count on the `total` row). Confirm the organizer's Guam DRT exemption certificate and any Specific Event Exemption Application outside HåfaPass. |

### 2. Custodial Liability Roll-Forward (Balance Sheet — Organizer Funds Held in Custody)

These funds belong to the event organizers, **not** Shimizu Technology LLC revenue.

| Column | Timing (Guam time) | Meaning |
|---|---|---|
| `opening_custodial_liability` | Before 1st of month | Organizer proceeds held by HåfaPass at the start of the month (equals prior month's `closing_custodial_liability`). |
| `proceeds_collected` | Order completion month | Organizer proceeds from tickets (and any add-ons/donations), net of discounts and organizer-absorbed service fees. |
| `proceeds_refunded` | Refund success month | Organizer proceeds returned to buyers on succeeded refunds (subtracted from liability). |
| `chargebacks` | Dispute lost/closed month | Lost Stripe disputes debited against organizer proceeds (subtracted from liability). |
| `organizer_processing_deducted` | Original sale month | Actual Stripe card processing deducted from organizer proceeds (usually `$0.00` under platform-absorbed ticket terms; nonzero on legacy/organizer-bearer orders or add-ons/donations). Uses the exact `Settlements::Calculator` split. |
| `other_adjustments` | Adjustment effective month | Net posted non-reserve balance adjustments (e.g., manual credits/debits, signed; added to liability). |
| `organizer_payouts_made` | Payout paid month | Gross confirmed payouts (`status = paid`, `amount_cents`) settled against organizer liability (subtracted from liability). Pending, failed, held, and reversed payouts are excluded. |
| `closing_custodial_liability` | End of month | **Balance sheet liability owed to organizers at month-end** (includes any held reserves). |

**Roll-forward identity (exact on every row and on `total`):**

```text
closing_custodial_liability
  = opening_custodial_liability
  + proceeds_collected
  - proceeds_refunded
  - chargebacks
  - organizer_processing_deducted
  + other_adjustments
  - organizer_payouts_made
```

### 3. Chargeback Reserve & Backup Withholding Memos

| Column | Meaning |
|---|---|
| `reserve_held` | New `reserve_hold` balance adjustments effective in the month (e.g., 10% post-event holdback). Shown as a positive amount. |
| `reserve_released` | `reserve_release` balance adjustments effective in the month (e.g., 30-day release). Shown as a positive amount. |
| `ending_reserve_balance` | Cumulative net reserve still held at month-end. **Note:** Held reserves are *part of* `closing_custodial_liability`, not deducted from it — they restrict how much of the liability is currently payable. |
| `backup_withholding_memo` | Portion of `organizer_payouts_made` withheld for IRS/Guam DRT backup withholding (`withheld_cents + carried_withholding_cents`). Reclassify this from organizer custodial liability to a separate tax-withholding payable until deposited. |

**Exact reconciliation to organizer payout statements (`Settlements::Calculator`):**

For any event whose activity occurred on or before month-end:
- `closing_custodial_liability - ending_reserve_balance` equals `Settlements::Calculator`'s unpaid unrestricted balance (`payable_cents - paid_cents - negative_balance_cents`).
- `ending_reserve_balance` equals `Settlements::Calculator`'s `reserve_cents`.

### 4. HåfaPass Fee Revenue & Guam BPT Estimate (Income Statement — Shimizu Technology LLC)

| Column | Timing (Guam time) | Meaning |
|---|---|---|
| `fee_revenue_gross` | Order completion month | Gross HåfaPass ticketing service fees (both buyer-paid and organizer-absorbed). |
| `fee_refunds` | Refund success month | HåfaPass service fees returned on succeeded refunds. |
| `fee_revenue_net` | Monthly net | `fee_revenue_gross - fee_refunds`. Can be negative in a month where cross-month refunds exceed new fees. |
| `stripe_processing_costs_informational` | Original sale month | Total actual (non-estimated) Stripe processing costs for orders collected in the month. **Informational expense only** — does not reduce Guam BPT gross receipts. |
| `bpt_base_fee_revenue_estimate` | Monthly net | Working BPT base equal to `fee_revenue_net` under the fee-only position (confirm with CPA). |
| `estimated_bpt_rate_pct` | Statutory general rate | `4.00` for `2026-10` onward (`4.50` for `2025-10`–`2026-09`, `5.00` prior) per 11 GCA § 26202. Does not apply conditional § 26203.2 3% small-business relief. |
| `estimated_bpt_on_fee_revenue_estimate` | **Estimate only** | Estimated Guam BPT on positive `bpt_base_fee_revenue_estimate` at `estimated_bpt_rate_pct` (rounded half-up to the cent; `$0.00` when net fee base is negative). On the `total` row, computed on the entity-level total `bpt_base_fee_revenue_estimate` (which may differ by ±$0.01 from summing individual event estimates due to rounding). |
| `currency` | Always `USD` | Reporting currency. |

## Important CPA reminders

- **Nonprofit organizers and HåfaPass fees:** Flagging an organizer row as `nonprofit_exempt_flag = yes` indicates that the *organizer* classified itself as a nonprofit on its W-9 (requiring DRT verification for the organizer's own event proceeds). Because Shimizu Technology LLC is a commercial service provider, HåfaPass's own ticketing service fees on nonprofit events remain in `bpt_base_fee_revenue_estimate` unless the CPA/DRT determines otherwise.
- **Cross-month refunds:** When a ticket is sold in Month 1 and refunded in Month 2, Month 1 shows the sale and full fee, and Month 2 shows the refund (potentially negative `fee_revenue_net`), with Month 1's `closing_custodial_liability` carrying forward into Month 2's `opening_custodial_liability`.
- **Legacy BPT event CSV:** The earlier compact CSV (`Export monthly BPT detail CSV` / `bpt_events_export` from PR #223) remains available for quick cross-checking, while `Export monthly CPA CSV` (`cpa_monthly_export`) is the complete monthly reconciliation workpaper filling #223's custodial-liability, refund, chargeback, reserve, BPT-estimate, nonprofit-flag, and totals-row gaps.
