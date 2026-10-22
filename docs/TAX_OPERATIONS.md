# HåfaPass tax operations

This is an engineering runbook for preparing CPA review. It does not decide whether Shimizu Technology must issue Form 1099-NEC, 1099-MISC, 1099-K, or no form for a particular organizer. It does not file returns or remit withheld tax.

## Current data and controls

Buyer checkout is unchanged. The payout gate checks the organizer's W-9 and backup withholding state. The site setting `backup_withholding_mode` defaults to `block`; `withhold` calculates 24% on the gross payout in integer cents and stores the withheld amount, gross reservation, and check/transfer amount separately. An admin can override a block only with a reason, which is audited. A withholding amount must be deposited and reported through a CPA-approved external process; HåfaPass does not move it automatically. Do not switch to `withhold` until that process and any required approval are ready.

TINs are encrypted in the W-9 and payout snapshot. Admin pages and PDFs show only the last four digits. The audited IRS matching export and CPA preparation CSV intentionally contain complete TINs and must be stored and transferred securely. They are `no-store` downloads. Do not paste them into tickets, email, chat, or application logs. The payer TIN in the CPA CSV comes from `TAX_PAYER_TIN`; if unset, the CSV contains `SET_TAX_PAYER_TIN`. The CSV is a preparation worksheet, not a direct IRIS or FIRE upload specification.

## TIN matching

1. Confirm eligibility and enroll an authorized payer/operator in IRS e-Services. HåfaPass does not call the IRS API. Download **TIN matching → Export verification file** from admin. It includes unverified payees in `TIN type;TIN;Name;account number` format, one line per payee. The account number is an opaque 20-character reference. Keep the file secure.
2. Submit the text file through IRS e-Services. Download its returned result file and import it in the same admin page. The import accepts five semicolon-delimited fields: the four echoed request fields plus result code. It validates account reference, current W-9 identity, and duplicate rows before saving anything. Changed W-9s need a fresh export.
3. Review the masked status. Codes 0, 6, 7, and 8 indicate matches; 1 means missing/invalid TIN, 2 not issued, 3 name/TIN mismatch, 4 invalid request, and 5 duplicate request. Correct input problems and obtain a new certified W-9 as needed. Every export and successful import is audited with counts and statuses, never complete TINs. Failed imports are rejected atomically.

[IRS Publication 2108, bulk format and returned indicator](https://www.irs.gov/pub/irs-pdf/p2108.pdf) describes the file format. [IRS e-Services TIN matching](https://www.irs.gov/government-entities/indian-tribal-governments/taxpayer-identification-number-tin-on-line-matching) describes enrollment and use.

## B-notices and withholding

1. A code 3 match result is an investigation lead. Ask the CPA whether an IRS CP2100/CP2100A notice or other trigger requires the formal B-notice procedure. Do not treat a voluntary TIN match result alone as an IRS B-notice.
2. When instructed, download the first or second template PDF from the payee's tax controls. Check the letter, payee address, delivery method, and IRS notice before sending. Record the date actually sent. The UI tracks 30 business days excluding weekends and observed US federal holidays; operations must verify the deadline measured from receipt of the IRS notice and any Guam-specific rules. A second notice follows the first only when the CPA confirms the IRS criteria are met.
3. A first notice asks for a signed W-9 or acceptable substitute. A second generally requires an SSA card or IRS Letter 147C; a W-9 alone may be insufficient. The current product clears its local B-notice flag when a new certified W-9 is submitted, so operations must keep an unresolved second-notice case externally until required verification is received.
4. After the response window, an unresolved mismatch activates backup withholding in the payout gate. An admin may also set an explicit withholding flag with a reason. Missing or uncertified W-9s trigger the gate immediately. Default `block` prevents payout; `withhold` reserves 24% of gross and shows the net check amount. The CPA must confirm when to start/stop withholding, deposit, file Form 945, and handle Guam-specific treatment.

[IRS B program](https://www.irs.gov/businesses/small-businesses-self-employed/backup-withholding-b-program), [Publication 1281](https://www.irs.gov/pub/irs-pdf/p1281.pdf), and [IRS backup withholding guidance](https://www.irs.gov/taxtopics/tc307) govern the actual notice and withholding procedure. The IRS currently lists 24%; the site rate is configurable in basis points.

## Year-end calendar

- **Each payout:** Reconcile the gross reservation, amount withheld, and amount paid by check. Record refund clawbacks separately; the report's post-payout refund adjustment is an amount of organizer proceeds refunded after a payout, not proof that it was recovered.
- **December/January:** Reconcile checks, bank statements, refunds, prior-year adjustments, and withholding deposits. Payout-time name/TIN snapshots define separate payee rows even if an organization later changes its W-9. Set the form type and IRS/Guam DRT jurisdiction for each payee and calendar year. `CPA review needed` is the default form type. `IRS` is the default jurisdiction, subject to CPA review for Guam taxpayers.
- **January 31, subject to weekend/holiday rules:** Furnish recipient statements when required. Form 1099-NEC is generally due to the IRS by January 31. Confirm the exact tax-year deadlines for Form 1099-MISC and 1099-K; their IRS filing dates can differ from the recipient date and by paper/electronic filing method.
- **After CPA approval:** Export the audited annual CPA CSV, verify payer and payee TINs securely, prepare IRIS/FIRE or Guam DRT submissions outside HåfaPass, retain acknowledgments, issue corrections, and reconcile Form 945 and deposits if withholding occurred. The organizer can download a masked annual account statement from Finances; it is not a filed Form 1099.

For payments in **2026**, the IRS increased the general 1099-NEC and many 1099-MISC reporting thresholds from $600 to **$2,000**. Some MISC categories retain different thresholds. The configured defaults are $2,000 for NEC and MISC from 2026 onward; earlier years use $600. The CPA can change the current thresholds. Form 1099-K has different rules: payment card transactions and third-party settlement organization payments differ, and the latter generally uses a $20,000 **and** 200-transaction threshold. The $20,000 site default is only an advisory amount check; the product does not decide 1099-K eligibility or count its qualifying transactions. Any backup withholding warrants CPA review regardless of the amount. See [IRS 2026 threshold bulletin](https://www.irs.gov/irb/2026-19_IRB), [2026 general information-return instructions](https://www.irs.gov/publications/p1099), and [IRS 1099-K third-party filer FAQ](https://www.irs.gov/newsroom/form-1099-k-faqs-third-party-filers-of-form-1099-k).

## CPA decisions to record

- Whether the operator is the required filer for organizer check payouts, and whether each payee/year needs NEC, MISC, K, or none, including corporate exceptions, duplicate-reporting rules, and the correct gross/net boxes.
- Whether a Guam payee's return is filed with Guam DRT, the IRS, or both, and the form/deadline for each jurisdiction.
- Thresholds for each form and category in each tax year, including special MISC categories and 1099-K transaction count.
- Whether these payments are subject to federal or Guam backup withholding, what triggers first/second B-notices, exact business-day/holiday deadlines, how a second notice is cleared, and deposit/Form 945 steps.
- Whether refunded ticket proceeds after payout should alter a tax year's reportable amount, be recovered as a later-year adjustment, or be shown separately.
