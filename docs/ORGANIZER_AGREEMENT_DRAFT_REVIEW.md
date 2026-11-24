> **DRAFT for review — not legal or tax advice — not in effect**
>
> Prepared for Leon Shimizu and CPA review (November 24, 2026). This document builds on the staged review-only `2026-11-24-copa-draft` amendment in [policies.yml](../hafapass_api/config/policies.yml). The live October 24, 2026 Organizer Agreement (`version: "2026-10-24"`, `status: approved`), its material terms, and all live approval/acceptance digests remain unchanged until Leon and the CPA sign off and a coordinated release promotes the approved text. All tax positions noted below (including fee-only Guam BPT treatment and contractual tax allocation) are working positions for CPA and Guam counsel review, not settled legal or tax conclusions.

# HåfaPass Organizer Agreement — Copa Draft Review Packet

## Purpose and reconciliation with PR #223 and PR #239

PR #223 staged an initial review-only `2026-11-24-copa-draft` under the `draft:` block of [hafapass_api/config/policies.yml](../hafapass_api/config/policies.yml) (updating `Our role as your limited agent`, `Payouts`, `Tax information`, and Buyer Terms `Prices and the service fee`). PR #239 implemented the 10% / 30-day reserve hold and release mechanics. This revision reconciles and expands the staged draft without starting over or modifying any live policy text or digest:

1. **Banner added to staged draft (`review_banner`)**: Marks every rendering explicitly as `"DRAFT for review — not legal or tax advice — not in effect"`.
2. **Custodial language sharpened (`Our role as your limited agent`)**: Kept #223's custodial capacity and no-claim-of-right wording, and clarified that collected ticket proceeds (and any other event proceeds collected on the organizer's behalf) belong to the organizer, are **not Shimizu Technology LLC revenue**, Shimizu Technology LLC makes **no claim of right** to them, and HåfaPass's service fees are separate revenue for ticketing services.
3. **Reserve base & dispute mechanics aligned with policy and PR #239 (`Payouts` + `Chargebacks and negative balances`)**: Kept #223's 2–3 business day post-event bank transfer, ~10% 30-day reserve, and check-by-approved-exception terms (`payout_terms: bank_transfer_with_reserve`). Defined the reserve base explicitly as **~10% of net organizer proceeds held by HåfaPass after deducting any organizer-borne card processing costs, excluding door cash and other non-custodial organizer-direct proceeds such as organizer-direct card-present/Clover sales** (with worked mixed-tender examples: `$1,000` held − `$30` processing → `$97` reserve, excluding `$200` door cash and `$400` organizer-direct card sales; `$100` Stripe + `$40` Clover → `$10` reserve, not `$14`). *(Implementation alignment note: PR #239's initial calculator included organizer-direct Clover proceeds in the reserve base; W1 is aligning #239 to reserve only custodial proceeds held by HåfaPass so code matches this draft.)* Aligned dispute wording with PR #239: reserve release is **blocked while a refund or dispute is open**; **lost disputes** are posted against the organizer balance; and **Stripe dispute fees** pass through **only by a separate documented balance-adjustment debit**.
4. **Buyer list ownership added (`Buyer information`)**: Not previously changed in #223. Added a clear statement that **the buyer list belongs to the organizer**, HåfaPass processes buyer/attendee data on the organizer's behalf only to run the service and as law or explicit buyer consent allows, aligned with the #233 dual-consent email model ([EMAIL_COMPLIANCE.md](EMAIL_COMPLIANCE.md)), and described role-based organizer export mechanics.
5. **Nonprofit Guam DRT exemption & interim submission process (`Tax information`)**: Framed tax allocation as the contractual position between the parties subject to applicable law (rather than stating tax conclusions as fact), and specified **what** DRT documents nonprofit organizers send, **how** they send them during the interim before an in-app upload ships, **what happens if missing**, and **who bears BPT as between the parties**.
6. **Buyer Terms amendment kept (`Prices and the service fee`)**: Kept #223's staged clarification that Guam BPT is handled by the business that owes it and is not added as a separate line at checkout.

---

## Full Organizer Agreement Draft (for review)

> **DRAFT for review — not legal or tax advice — not in effect**
>
> **Staged version:** `2026-11-24-copa-draft` · **Status:** `draft` · **Effective date:** `null` (not in effect)
> **Proposed material terms:** `payout_schedule_text: "within 2–3 business days after your event"` (current live setting: `"within 3 to 5 business days after your event"`). Service fee remains unchanged at 5% of each paid ticket's price plus $1.00 per paid ticket; free tickets carry no service fee; card processing is paid by HåfaPass out of this fee.

### 1. Eligibility and authority — `[UNCHANGED from 2026-10-24 live agreement]`

This agreement is between you, the organizer, and Shimizu Technology LLC, which runs HåfaPass. You must be at least 18 and able to enter contracts. If you act for a business or group, you confirm that you have authority to bind it.

You confirm that you have the right to hold and sell tickets to each event you list, including any permission you need from the venue, performers, or rights holders.

Before your published events become public and can sell tickets, HåfaPass reviews your organization once. You must give accurate contact details for that review and keep them current. Until we verify you, published events are available only through a private preview link. We may decline or pause verification, which hides your events from public listings.

### 2. Accurate listings — `[UNCHANGED from 2026-10-24 live agreement]`

Event listings must be accurate and kept current, including the local date and time, venue, ticket types and quantities, all-in prices, age rules, accessibility information, and refund policy. If you don't state a refund policy, tickets are refundable for cancellation or postponement, for another material change where we or the law determine a refund is due, or where the law otherwise requires.

You are responsible for the content you publish, including images and descriptions.

### 3. Our role as your limited agent — `[CHANGED — reconciled & expanded from #223]`

You are the seller of the tickets to your event. You appoint Shimizu Technology LLC, operating HåfaPass, as your limited agent solely to accept buyer payments for your tickets. A buyer's payment to HåfaPass is payment to you and fully discharges the buyer's payment obligation to you. Your ticket contract is between you and the buyer; Shimizu Technology LLC is not a party to it.

Shimizu Technology LLC sells its ticketing service to buyers and to you, and charges a separate service fee for that service. Receipts and tickets will name you as the seller ("Sold by" followed by your organizer name, then "Tickets by HåfaPass").

Buyer card payments are processed through Shimizu Technology LLC's payment account and received into its business account. We hold collected ticket proceeds (and any other event proceeds collected on your behalf) for you in a custodial capacity and record them separately from our service fees. Those proceeds belong to you and are not Shimizu Technology LLC revenue; Shimizu Technology LLC makes no claim of right to them. Our service fees are separate revenue for our ticketing service. We remit your available balance under the Payouts section. We may withhold or offset amounts for refunds, chargebacks, cancelled or postponed events, and suspected fraud. You remain responsible for refunds beyond the funds we hold, including after a payout.

### 4. Service fees — `[UNCHANGED from 2026-10-24 live agreement]`

The current service fee is 5% of each paid ticket's price plus $1.00 per paid ticket; free tickets carry no service fee; card processing is paid by HåfaPass out of this fee.

For each event you choose how the fee is handled: buyers pay it on top of the ticket price, you absorb it so buyers pay only the ticket price, or you split it and buyers pay a set share. Advertised prices always show the buyer's full total.

We may change the fee schedule. You must accept the current agreement before publishing a new event. The fee shown to a buyer before payment applies to that order; a later fee change does not change a completed order. Check the current fee terms before selling more tickets, including for an event already published.

### 5. Payouts — `[CHANGED — aligned with #223 and #239; metadata payout_terms: bank_transfer_with_reserve]`

We pay your available balance within 2–3 business days after your event, after we reconcile the event's sales, refunds, and disputes and receive required tax information. Bank transfer to your approved bank account is the standard payout method. We pay by check only as an approved exception recorded for your organization.

Your available balance is your ticket proceeds held by Shimizu Technology LLC minus any service fees you absorb, organizer-borne card processing costs, refunds, lost chargebacks, documented adjustments, any reserve or other hold, and amounts already paid to you. Door cash you collect directly is already in your possession and is excluded from platform payouts.

We hold about 10% of net organizer proceeds held by Shimizu Technology LLC (after deducting any organizer-borne card processing costs, and excluding door cash or other non-custodial organizer-direct proceeds such as organizer-direct card-present sales) as a reserve for 30 days after your event to cover post-event refunds and chargebacks. For example, if Shimizu Technology LLC holds $1,000 in proceeds after $30 in organizer-borne card processing ($970 net) and you collected $200 in door cash and $400 through an organizer-direct card terminal, the 10% reserve is $97 (based only on the $970 held by Shimizu Technology LLC); the $200 door cash and $400 organizer-direct card proceeds are excluded. Similarly, for $100 in proceeds held by Shimizu Technology LLC (with $0 organizer-borne processing) plus $40 in organizer-direct card-present sales, the 10% reserve is $10, not $14. Reserve release is blocked while any refund or payment dispute is open, or during a documented compliance hold. Once the 30-day window passes and open refunds, disputes, and holds are resolved, we release the remaining reserve. Post-payout refunds, lost disputes posted against your balance, documented balance-adjustment debits (such as any documented dispute-fee debit), and any unpaid negative balance reduce what remains payable when the reserve is released.

We may delay or hold some or all of a payout while refunds or disputes are open, if an event is cancelled or changed, or during a documented risk or compliance review. We will give you a reason and review the hold when the underlying issue is resolved. A hold or reserve does not remove your responsibility for refunds, chargebacks, or negative balances.

### 6. Tax information — `[CHANGED — reconciled & expanded from #223]`

Before any paid payout, you must provide accurate tax information, a completed W-9 or other form we require for your status, and accurate payee details. You must update them when they change. We may request corrections or pause a payout while required tax details are missing. We will arrange any legally required withholding or information reporting through a separate reviewed process. The tax reports in HåfaPass are preparation tools; they are not filed returns.

As between you and Shimizu Technology LLC, you are responsible for determining, reporting, and paying taxes that apply to your ticket sales and event proceeds, including any Guam Business Privilege Tax (BPT), event-specific levy, or related penalties and interest, subject to applicable law and tax-authority rules. Shimizu Technology LLC is responsible for taxes that apply to its own ticketing service-fee revenue. The service fee is not a government tax, and you must not describe it as one.

If you are a nonprofit or tax-exempt organizer claiming a Guam BPT exemption on event receipts, send a copy of your Guam Department of Revenue and Taxation (DRT) tax-exemption recognition certificate and, where applicable for a specific fundraising or public event, your filed DRT Specific Event Exemption Application to us at the configured support email (without emailing SSNs or TINs; keep W-9 details in the encrypted in-app form) before publishing paid ticket sales and early enough to satisfy DRT's advance-filing requirement. Missing exemption documentation does not by itself block ticket sales when your W-9 and payout requirements are met, unless required by law or risk review, but Shimizu Technology LLC does not mark your organization or event as DRT-verified exempt on its CPA preparation reports and cannot claim or certify an exemption on your behalf. As between us, you bear responsibility for any BPT, penalties, or interest if an exemption is missing, denied, unfiled, or revoked.

### 7. Refunds, cancellations, and postponements — `[UNCHANGED from 2026-10-24 live agreement]`

Refunds are funded from your event proceeds. You agree to honor your stated refund policy and our Refund & Cancellation Policy.

If you cancel an event, tell us promptly and notify buyers through HåfaPass. Cancellation starts eligible Stripe card refunds, including service fees, without a buyer request. You must return cash purchases and record the returns; non-Stripe door-card payments also need manual returns through their provider. We hold your payout while buyer refunds remain unresolved. If you postpone an event, notify buyers and cooperate with refund requests for unused tickets. If you materially change an event in another way, promptly disclose the change and work with us on the remedy and any request window under applicable law.

You must honor every valid ticket sold for your event.

### 8. Events beyond anyone's control — `[UNCHANGED from 2026-10-24 live agreement]`

A typhoon, public-health order, government action, venue closure, or comparable event outside reasonable control may delay performance. Tell us and buyers promptly, take reasonable steps to limit harm, and propose a lawful remedy. This does not excuse required refunds, chargebacks, amounts already owed, or duties that can still be performed.

### 9. Chargebacks and negative balances — `[CHANGED — aligned with #239]`

If a buyer disputes a payment, reserve release and affected payouts are blocked while the dispute is open, and we respond to the dispute using records you and we provide. If the dispute is lost, the lost dispute amount is posted against your organizer balance (reducing what remains payable when the reserve is released). Any Stripe or payment-network dispute fee charged to Shimizu Technology LLC passes through to your organizer balance only by a separate documented balance-adjustment debit.

If refunds, lost disputes, documented dispute-fee debits, or organizer-absorbed fees exceed your remaining balance (including after a payout has already been sent), the shortfall is a negative balance you owe Shimizu Technology LLC. We may deduct or offset a negative balance from any remaining reserve or from future payouts across your events on HåfaPass, or invoice you for the balance. You agree to pay any invoice by the due date shown.

### 10. Your responsibility for the event — `[UNCHANGED from 2026-10-24 live agreement]`

You are responsible for your event: the venue, permits, business and event licenses, staffing, security, safety and emergency planning, insurance, accessibility, age restrictions, venue rules, and compliance with all laws. If you serve or sell alcohol, use regulated goods, or run a raffle or gaming activity, you must hold the required approvals and follow applicable rules. We may ask for proof before allowing sales. You must provide accessible seating information where your event uses assigned seating.

You may not list events or sell tickets that our Acceptable Use Policy prohibits.

### 11. Buyer information — `[CHANGED — new in this draft vs #223]`

The buyer list for your event belongs to you, the organizer. Shimizu Technology LLC processes buyer and attendee information on your behalf to run the ticketing service—including checkout, ticket delivery, transfers, refunds, door check-in, buyer support, fraud prevention, and accounting or tax recordkeeping—and otherwise only as applicable law or explicit buyer consent allows.

Platform marketing and event alerts from HåfaPass are separate from your buyer list and require the buyer's own explicit opt-in; we do not use your buyer list for unrelated platform marketing without that separate consent. Organizer marketing emails sent through HåfaPass are limited to buyers or followers who gave explicit consent for your organization and have not unsubscribed (including any global marketing opt-out), require your certified commercial postal address, and include a one-click unsubscribe link. Event waitlist alerts and offers are sent only for the specific event requested and honor event-specific and organizer opt-outs.

Authorized organization owners, managers, and assigned box-office staff can export buyer and attendee lists for your events from your organizer dashboard. Finance-only staff can export order and payment details, which include buyers' names and email addresses, without attendee lists. Organizers can also export consent-filtered email audiences from the email dashboard. Smaller exports download directly; large sales export files are stored privately for two days after preparation and then deleted.

You may use buyer and attendee information to run your event, provide customer service, and meet legal obligations. If you market outside HåfaPass using data you lawfully hold, you are responsible for any required consent, accurate sender details, an effective opt-out, and honoring opt-outs. Keep attendee data secure, do not sell it, and notify us promptly if it is lost, misused, or accessed without authority. You are independently responsible for your own use of buyer information; Shimizu Technology LLC remains responsible for its own platform processing.

### 12. Content license — `[UNCHANGED from 2026-10-24 live agreement]`

You keep ownership of the names, logos, images, and descriptions you upload. You grant Shimizu Technology LLC a non-exclusive, royalty-free license to use them to list, promote, and sell tickets to your events on HåfaPass and in related marketing. You confirm you have the rights needed to grant this license.

### 13. Indemnity and limitation of liability — `[UNCHANGED from 2026-10-24 live agreement]`

You will defend and indemnify Shimizu Technology LLC against third-party claims, reasonable losses, and reasonable costs arising from your events, your content, your use of buyer information, or your breach of this agreement or the law, except to the extent caused by our own misconduct.

To the extent the law allows, Shimizu Technology LLC is not liable for indirect or consequential losses, and its total liability to you under this agreement is limited to the service fees it earned from your events in the 12 months before the claim.

### 14. Suspension and termination — `[UNCHANGED from 2026-10-24 live agreement]`

We may pause ticket sales, hold payouts, remove a listing, or suspend your account if we reasonably believe you have broken this agreement or the law, or that buyers are at risk. Either party may end this agreement with notice. Obligations for tickets already sold, refunds, disputes, negative balances, and indemnity continue after it ends.

### 15. Governing law and changes — `[UNCHANGED from 2026-10-24 live agreement]`

This agreement is governed by the laws of Guam. Either party may bring a dispute in the Superior Court of Guam, or another court with jurisdiction in Guam, after giving the other a reasonable chance to resolve it informally, unless urgent relief is needed.

We may update this agreement. You must accept the current version before you publish a new event, and HåfaPass records which version you accepted and when. For questions, contact us at the configured support email.

### Related staged Buyer Terms amendment — `Prices and the service fee` `[CHANGED in #223, retained]`

> **DRAFT for review — not legal or tax advice — not in effect**

The price we advertise for a ticket is the total you will pay for it, including the mandatory service fee. The checkout total matches the advertised price. If you choose an optional add-on such as merchandise or a donation, we show that amount separately before you pay. Guam Business Privilege Tax is handled by the business that owes it and is not charged as a separate line at checkout.

The service fee pays for the ticketing service: online sales, payment handling, ticket delivery, transfers, entry scanning, and buyer support. It is not a tax. The current fee schedule is 5% of each paid ticket's price plus $1.00 per paid ticket; free tickets carry no service fee; card processing is paid by HåfaPass out of this fee. Each organizer decides whether buyers pay the fee, the organizer absorbs it, or the two share it. Either way, the total you see is the total you pay.

---

## Clause-by-clause "What changed and why"

| Section | Live (`2026-10-24`) | Staged Draft (`2026-11-24-copa-draft`) | Why changed |
|---|---|---|---|
| **Draft header & metadata** | Live approved version (`2026-10-24`) | Adds `review_banner: "DRAFT for review — not legal or tax advice — not in effect"`, `status: draft`, `effective_date: null`, proposed `payout_schedule_text: "within 2–3 business days after your event"` | Prevents review text from being mistaken for operative terms and leaves live digests untouched until sign-off. |
| **Our role as your limited agent** | Says proceeds are held and recorded separately; says we pay by check or another method on file. | Explicitly states proceeds are held in a **custodial capacity**, belong to the organizer, are **not Shimizu Technology LLC revenue**, Shimizu makes **no claim of right** to them, and HåfaPass fees are separate revenue. | Supports principal-agent accounting (ASC 606) and our working Guam BPT fee-only position (for CPA/counsel review) by documenting absence of claim of right to organizer ticket proceeds. |
| **Payouts** | Default check payout (`within 3 to 5 business days after your event`); no reserve clause. | **Bank transfer** within **2–3 business days after your event**; check only by approved exception; **~10% reserve for 30 days** calculated on **net organizer proceeds held by HåfaPass after organizer-borne card processing, excluding door cash** (with worked example: $1,000 − $30 → $97 reserve; $200 door cash excluded); release blocked while any refund or dispute is open; post-payout refunds, lost disputes, documented debits, and negative balances reduce what remains payable at release. | Aligns contract with Copa operating practice (#221, #223) and the exact reserve base / release-blocking code shipped in PR #239, while reducing FinCEN FIN-2014-R009 check-disbursement risk. |
| **Tax information** | General W-9 and organizer BPT responsibility; no nonprofit DRT language. | Frames BPT allocation as the contractual position between the parties subject to applicable law; details **nonprofit DRT exemption** documentation (DRT recognition certificate + Specific Event Exemption Application where applicable), interim email delivery (no SSNs/TINs in email), timing, and effect of missing docs (not marked DRT-verified exempt on CPA reports; organizer bears BPT as between the parties). | Gives nonprofit organizers clear interim submission instructions without claiming tax conclusions as settled law, and protects HåfaPass from certifying an organizer's tax exemption. |
| **Chargebacks and negative balances** | Mentions holding disputed amount and deducting dispute fees from proceeds; no reserve mention. | Aligns with PR #239: open disputes block reserve release and affected payouts; **lost disputes** post directly against the organizer balance; **Stripe dispute fees pass through only by a separate documented balance-adjustment debit**; shortfalls create a negative balance offset against remaining reserve or future payouts across events, or invoiced. | Ensures the contract accurately reflects how HåfaPass actually posts lost disputes (ledger-driven) vs dispute fees (manual documented debit only) and reconciles with the 10%/30-day reserve. |
| **Buyer information** | States export permissions and checkout marketing opt-in; does not explicitly state buyer-list ownership or #233 platform-vs-organizer consent separation. | Explicitly states **the buyer list belongs to the organizer**; HåfaPass processes buyer data on the organizer's behalf only to run the service and as law/consent allows; reflects #233 dual-consent rules (separate platform alerts opt-in, organizer checkout/follower opt-in, global opt-out, certified postal address, waitlist scope) and organizer export roles/expiry. | Gives organizers contractual clarity that HåfaPass does not hijack their attendee list, while matching the actual #233 consent code in production. |
| **Buyer Terms — Prices and the service fee** | Mentions showing government tax separately if ever charged. | Clarifies Guam BPT is handled by the business that owes it and is not shown as a separate line at checkout (carried from #223). | Matches working Guam BPT position (gross receipts tax on the business, not a buyer-facing retail sales tax line) and FTC all-in pricing. |
| **All other 10 Organizer Agreement sections** | Eligibility, Accurate listings, Service fees, Refunds/cancellations, Force majeure, Event responsibility, Content license, Indemnity/liability cap, Suspension/termination, Governing law. | **Unchanged.** | Preserves previously reviewed baseline terms; changes stay tightly scoped and easy to audit. |

---

## Primary-source research & verification status

| Topic | Source / status | Verification note |
|---|---|---|
| Guam BPT service-business rate: **4.5%** effective Oct 1, 2025; **4.0%** effective Oct 1, 2026 (prior statutory general rate was 5.0%); conditional 3% small-business relief under § 26203.2 | [Public Law 38-136](https://guamlegislature.gov/38th_Guam_Legislature/Public_Laws_38th/Public%20Law%2038-136.pdf) amending [11 GCA § 26202(c)](https://col.guamcourts.gov/sites/default/files/11gc026_Q.pdf) (see also § 26203.2) | **Verified statutory rate schedule.** CPA must confirm HåfaPass's exact statutory class, whether § 26203.2 small-business relief applies, and any pre-Oct-2025 historical periods. |
| Guam BPT monthly filing deadline: **20th day of the following month** (Form GRT-1) | 11 GCA Ch. 26 / Guam DRT BPT filing rules | **Verified** general monthly return due date; CPA confirms exact filing calendar and weekend/holiday shifts. |
| Guam BPT nonprofit exemptions | [11 GCA § 26203](https://col.guamcourts.gov/sites/default/files/11gc026_Q.pdf) (exempts qualifying religious, charitable, scientific, educational, civic, and community-benefit nonprofits where no net earnings benefit private individuals) | **Verified** statutory basis; exemptions apply only to qualifying organizational activities and typically do not extend to commercial for-profit contractors/service providers (CPA to confirm). |
| Guam DRT **Specific Event Exemption Application** & **20 working days pre-event lead rule** | [Guam DRT Specific Event Exemption Application PDF](https://www.govguamdocs.com/revtax/docs/SPECIFICEVENTAPPLICATION.pdf) (cited in [COPA_2027_READINESS.md](COPA_2027_READINESS.md), noting filing at least 20 working days before the event). | **Partially verified — CPA to confirm current form PDF.** Web search confirmed the official DRT Specific Event Exemption Application form and prior-approval requirement, and `COPA_2027_READINESS.md` cites the 20-working-day lead rule from the DRT PDF; CPA should verify the current DRT form instructions and deadline directly. |
| Marianas Open affiliated organization on Guam DRT exempt list | Noted in earlier project research. | **Unverified here** — Leon / CPA must verify the exact entity name, EIN, and active DRT exemption certificate directly with the organizer and DRT's current listing before treating Copa ticket proceeds as DRT-verified exempt. |
| Repeal of Guam general admissions tax vs facility-specific levies | [11 GCA Ch. 22 Art. 3 (repealed) & Art. 4 § 22401](https://col.guamcourts.gov/sites/default/files/11gc022.pdf) | **Verified** repeal of general admissions tax; facility-specific or activity-specific levies remain for CPA/counsel review per event. |

---

## DRT Exemption Documentation — Interim Process & Follow-up Upload Design Note

### Interim submission process (before activation / until in-app upload ships)
Until Leon and the CPA approve an in-app upload or decide to stay reference-only, nonprofit organizers claiming Guam BPT exemption follow this interim process:
1. **How organizers submit documents:** Before publishing paid tickets (and in time for DRT's advance-filing requirement), the organizer emails PDF or photo copies of:
   - its Guam DRT tax-exemption recognition certificate / letter (11 GCA § 26203), and
   - where applicable for a specific public/fundraising event, a copy of its filed/stamped DRT Specific Event Exemption Application
   to HåfaPass's configured support/finance mailbox (`SiteSetting#platform_email`, fallback `shimizutechnology@gmail.com`). Organizers must **not** email SSNs or TINs — W-9 tax details stay exclusively in the encrypted in-app W-9 form.
2. **What evidence admin records:** The platform admin saves the received files in Leon's restricted CPA/finance folder outside this repository (never committed to git or stored in public buckets) and logs the verification metadata in the monthly CPA workpaper binder: organization ID, event ID(s) covered, document type (`drt_exemption_certificate` / `specific_event_exemption`), DRT approval/filing date, any expiration date, reviewer name/date, and restricted-folder reference.
3. **How it appears in HåfaPass exports today:** In the Monthly CPA CSV export (`cpa_monthly_export`), `w9_nonprofit_classification` shows `yes`/`no` from the certified W-9, and `drt_exemption_verified` is always explicitly `not_tracked` so a spreadsheet filter cannot confuse a W-9 self-classification with a DRT-verified exemption.

### Follow-up design note (Option A — minimal, secure DRT exemption upload, if Leon + CPA approve in-app storage)
- **Why deferred from this PR:** `S3Service` (`hafapass_api/app/services/s3_service.rb`) currently handles only public event/org images (`jpg`/`png`/`webp`, max 5 MB) and temporary private sales CSV exports (`private/sales-exports/...`), and `docs/TAX_OPERATIONS.md` uses reference-only storage for IRS second-notice documents. Leon and the CPA should choose between in-app private S3 document storage vs. keeping documents in the restricted CPA folder with reference-only metadata in HåfaPass.
- **Schema (if Option A is chosen):** Additive `organizer_tax_exemptions` table: `organization_id` (FK, indexed), `event_id` (optional FK for event-specific DRT exemptions), `document_kind` (`drt_exemption_certificate` | `drt_specific_event_exemption`), `storage_key` (private S3 key only — **never** a `public_url`), `content_type`, `byte_size`, `sha256_digest`, `status` (`pending_review` | `approved` | `rejected` | `expired`), `effective_on`, `expires_on`, `reviewed_by_user_id`, `reviewed_at`, `review_note`, `uploaded_by_user_id`, timestamps.
- **Access control:** Organizer upload & status view restricted to **Owner and Finance roles only** (`:manage_payout_settings` / `:manage_finance`); admin review and audited 60-second presigned download (`Cache-Control: no-store`) restricted to **Platform Admin only**.
- **Upload security:** Presigned S3 POST to `private/tax-exemptions/organizations/<org_id>/<uuid>.<ext>` (bucket policy denies public read), allowed types `application/pdf`, `image/png`, `image/jpeg`, max **5 MB**, server-side `HEAD` + magic-byte verification (`%PDF-`, PNG, JPEG) with conditional `if_match` ETag copy.
- **Data retention (`config/data_retention.yml`):** Classify as `category: "tax/TIN"`, `period: "7_years_after_year_end"`, `trigger: "created_at"`, `action: "anonymize"` (respecting `LegalHold`), `pii_columns: ["storage_key", "review_note"]`.
- **CPA CSV integration:** Once implemented, `drt_exemption_verified` can emit `verified` / `pending` / `unverified` instead of `not_tracked`.

---

## Open questions for Leon and the CPA

Please review and mark each decision before we promote `2026-11-24-copa-draft` to live:

1. **Guam BPT base — fee-only working position vs. gross proceeds (11 GCA § 26202(c), P.L. 38-136):**
   - Does the CPA confirm that under the agency + custodial/no-claim-of-right wording in `Our role as your limited agent`, Shimizu Technology LLC can report only its **net HåfaPass service fees** (buyer-paid + organizer-absorbed, minus fee refunds) as its BPT gross receipts, excluding organizer ticket proceeds?
   - Should organizer-absorbed service fees be treated identically to buyer-paid service fees in the BPT base? (Our CPA export includes both.)
   - Does Shimizu Technology LLC qualify for **11 GCA § 26203.2** conditional 3% small-business BPT relief, or should monthly workpapers continue using the P.L. 38-136 statutory § 26202(c) rate (**4.50%** from Oct 1, 2025; **4.00%** from Oct 1, 2026) as the conservative estimate?
   - How should **cross-month fee refunds** (where `fee_revenue_net` is negative on an event or for a month) be reported on Form GRT-1 (netted across events in the same return, carried forward, or amended)?
2. **Bank-account custody / segregation:**
   - Currently Stripe settles into Shimizu Technology LLC's single business bank account while the HåfaPass ledger separates custodial liability from fee revenue. Does the CPA (or Guam counsel) require a dedicated custodial / clearing bank sub-account for organizer proceeds before Copa sales open, or is separate ledger accounting + period-stable monthly custodial reconciliation sufficient?
3. **Reserve base, percentage, window, and negative balances:**
   - **Confirm reserve applies only to proceeds HåfaPass holds:** confirm that the ~10% / 30-day reserve applies only to custodial net proceeds held by HåfaPass after organizer-borne card processing (excluding door cash and organizer-direct card-present/Clover proceeds — e.g., `$10` on `$100` Stripe + `$40` Clover, not `$14`), or decide whether the contract should say "up to 10% (or another percentage we notify you of before your event)" for flexibility.
   - Confirm the cross-event offset (within the same organizer only) and invoicing terms for negative balances.
4. **Stripe dispute-fee pass-through (new question from PR #239 reconciliation):**
   - Currently `Settlements::Calculator` posts lost dispute amounts automatically from the `disputes` table, while Stripe's dispute fee (typically $15) is **not** deducted automatically and only passes through if an admin posts a separate documented `manual_debit` balance adjustment. Should HåfaPass absorb Stripe dispute fees as a platform operating cost, or pass them through to organizers via a documented debit (as drafted)? If passing through, should engineering automate dispute-fee capture or keep manual documented debits?
5. **Nonprofit organizers & DRT exemption evidence:**
   - What exact DRT documents should HåfaPass collect from a nonprofit organizer (e.g., Marianas Open's affiliated nonprofit): general DRT 11 GCA § 26203 exemption letter, Specific Event Exemption Application, or both?
   - Confirm the exact **advance-filing lead time** (20 working days per `SPECIFICEVENTAPPLICATION.pdf`) on DRT's current form.
   - Confirm whether HåfaPass's **own service fee** on a nonprofit organizer's event remains taxable to Shimizu Technology LLC for Guam BPT (our CPA CSV conservatively keeps HåfaPass's fee in Shimizu's BPT base while marking `w9_nonprofit_classification = yes` and `drt_exemption_verified = not_tracked`).
   - Confirm whether the **interim email + restricted CPA folder** process is sufficient for Copa or whether we should build in-app private S3 document upload in a follow-up PR.
6. **Sales-tax-like or event-specific levies:**
   - Confirm that for Copa de Marianas (sports tournament at UOG Calvo Field House) and standard Guam events, no separate admissions tax (repealed under 11 GCA Ch. 22 Art. 3) or recreation-facility tax (§ 22401) applies to spectator tickets, and that keeping checkout all-in without a BPT tax line is compliant.
7. **1099 / backup withholding interplay:**
   - Confirm whether Shimizu Technology LLC must furnish Form **1099-K**, **1099-MISC**, **1099-NEC**, or **no form** (including for nonprofit or corporate payees), and whether returns file with **Guam DRT**, the **IRS**, or both.
   - Confirm how **backup withholding** taken on a payout (`backup_withholding_memo` in the monthly CPA CSV, `backup_withholding_mode` = `block` vs `withhold` at 24%) should be tracked as a separate tax-remittance liability (Form 945 / Guam equivalent) and reconciled if a payout is later reversed.
8. **Buyer list ownership & email consent:**
   - Confirm the wording in `Buyer information` ("The buyer list for your event belongs to you...") aligns with Leon's commercial promise to organizers while preserving HåfaPass's right to process order/ticket/tax/fraud records and operate its separate opt-in platform alerts (`PlatformSubscriber`, #233).
9. **Check-payout exception & money-transmission review:**
   - Moving default payouts to **bank transfer** reduces check-disbursement risk under FinCEN FIN-2014-R009, but the draft still permits **check by approved exception**. Counsel/CPA should confirm whether occasional exception checks are acceptable and whether Stripe has confirmed the account/platform model.

---

## Activation checklist (do NOT run until Leon + CPA sign off)

1. Record Leon and CPA sign-off in the restricted evidence location.
2. In a separate release PR, copy the approved replacement sections from `draft:` into top-level `documents:` in `hafapass_api/config/policies.yml`, bump `version` and `effective_date`, and remove the `draft:` block (or archive it).
3. Update `SiteSetting.payout_schedule_text` to `"within 2–3 business days after your event"`.
4. Approve the new `policy_register` digest in Admin → Integrations & policies.
5. Have organizers (including Marianas Open) re-accept the new Organizer Agreement before publishing paid events.
