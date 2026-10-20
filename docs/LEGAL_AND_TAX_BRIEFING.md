# HåfaPass Legal and Tax Briefing (for accountant and lawyer)

Status: working checklist, prepared 2026-10-21 by engineering. Nothing here is legal or tax advice, and none of it has been reviewed by a professional. Each item is a question, with our current assumption stated so it can be confirmed or corrected.

## Context

Shimizu Technology operates HåfaPass, an event ticketing platform for Guam. Card payments are processed through a Stripe account held by Shimizu Technology and registered with a US (Nevada) address. Buyer funds settle into Shimizu Technology's business bank account. Organizers are paid by check written from that account, on the payout schedule set in admin settings, after sales, refunds and disputes are reconciled. Our product and policy drafts treat the **organizer as the seller of the ticket**. HåfaPass acts as the organizer's limited agent to sell and collect payment, and sells its own ticketing service, for which it charges a service fee. Receipts and tickets read "Sold by [organizer] · Tickets by HåfaPass". The service fee (currently a percentage plus a flat amount per paid ticket; free tickets carry no fee) is configurable in admin settings. Organizers choose per event whether the buyer pays it, the organizer absorbs it, or it is split. Under the default setting, card processing costs are paid out of the fee.

Draft policies are in `hafapass_api/config/policies.yml` (version `2026-10-launch-draft`) and served at `/policies/<key>`.

## 1. Guam Business Privilege Tax (BPT)

- [ ] **Accountant:** Confirm the current BPT rate. Our reading is that P.L. 38-60 (FY2026 appropriations act, enacted by veto override in September 2025) sets the 11 GCA §26202 rate at 4.5% from 2025-10-01 and **4% from 2026-10-01**, down from 5%. Verify with the Department of Revenue and Taxation (DRT). We could not retrieve the full P.L. 38-60 PDF (file too large), and we found no DRT notice.
- [ ] **Accountant:** As an agent, does Shimizu Technology owe BPT only on its service fee? Or will DRT treat it as principal and tax the full ticket price? Our assumption is service fee only.
- [ ] **Accountant/lawyer:** What documentation supports agent treatment? What we have now:
  - Organizer Agreement language appointing Shimizu Technology as limited agent, with the buyer's payment satisfying the buyer's obligation to the organizer.
  - Receipts and tickets naming the organizer as seller.
  - Ledger records that keep organizer proceeds separate from service fees.
  - Is a separate bank account for organizer funds needed or advisable?
- [ ] **Accountant:** Are organizers responsible for BPT on their ticket proceeds, and should we tell them so? The draft agreement says they are.
- [ ] **Accountant:** When the organizer absorbs the fee, what are Shimizu Technology's gross receipts? The fee is deducted from organizer proceeds instead of being paid by the buyer.
- [ ] **Accountant:** How should refunded service fees be treated for BPT? A full refund returns the fee; a partial refund returns it proportionally.

## 2. Agent vs principal (revenue recognition)

- [ ] **Accountant:** Under ASC 606, should Shimizu Technology recognize revenue net (service fee only) or gross (full ticket price)? Our assumption is net, because the organizer sets prices, controls the event and bears refund risk.
- [ ] **Accountant:** How should organizer funds held between sale and payout be booked? Currently they are a liability to organizers.
- [ ] **Accountant:** How should we record negative organizer balances (refunds or chargebacks greater than proceeds), our right to offset them against future payouts, and amounts we invoice?
- [ ] **Accountant:** Does the federal answer have to match the Guam BPT answer?

## 3. Information reporting (1099) and W-9s

- [ ] **Accountant:** Who files Form 1099-K for these card sales: Stripe, Shimizu Technology, or both? Stripe pays Shimizu Technology; Shimizu Technology then pays organizers by check. The IRS FAQ says the entity that submits the instruction to transfer funds to the payee files. It also says there is no threshold for payment card transactions, while third-party settlement organizations (TPSOs) report above $20,000 and 200 transactions (threshold reinstated by the One, Big, Beautiful Bill; FAQ updated 2025-10-23).
- [ ] **Accountant:** Is Shimizu Technology a TPSO or a payment settlement entity for organizer payouts? Or should it issue 1099-NEC or 1099-MISC instead, or nothing?
- [ ] **Accountant:** We plan to collect a W-9 from every organizer before the first payout, and the draft agreement requires it. Which payee details, and which validation (TIN matching), should we collect?
- [ ] **Accountant:** Do Guam-based organizers file with the Guam DRT instead of the IRS, given Guam's mirror tax system? Does that change which forms we issue or where we file them?
- [ ] **Accountant:** Do we need backup withholding procedures for organizers who don't provide a TIN?

## 4. Guam business license

- [ ] **Lawyer/accountant:** Which business license class(es) does Shimizu Technology need for online ticketing agency activity in Guam? Does each organizer need its own license for ticket sales?
  - Correction to an earlier lead: **11 GCA Chapter 26 is the Business Privilege Tax Law, not the business license law.** Business licensing is in 11 GCA Division 3, the Business License Law. That division includes Chapter 70 (General Provisions, §§70101-70134) and Chapter 72 (Commercial Licenses, with Article 1 "General Classes" and Article 2 "Special Commercial Classes"). Source: Guam Code Title 11 table of contents (Compiler of Laws, dated 2026-05-05). We have not read the chapter text, so the applicable class is not verified.
- [ ] **Accountant:** Does the existing Shimizu Technology license cover this activity, or is an amendment or new class needed?

## 5. Admissions or amusement tax

- [ ] **Accountant:** Is any admissions tax payable on Guam event tickets, and if so, who collects it? The current Guam Code table of contents lists 11 GCA Chapter 22, Article 3 "Admission Tax" as **[Repealed]**. An older version imposed 5% of the amount paid for admission. We have not confirmed when it was repealed or whether anything replaced it.
- [ ] **Accountant:** Does Chapter 22 Article 4 (Tax on Recreation Facilities, §§22401-22404) or any other levy apply to events our organizers run? Not reviewed.
- [ ] **Product note:** If a government tax ever applies, the checkout can show it separately from the all-in ticket price.

## 6. Money transmission and holding organizer funds

- [ ] **Lawyer:** Does holding buyer funds and paying organizers later make Shimizu Technology a money transmitter under federal or Guam law?
  - Federal: 31 CFR 1010.100(ff)(5)(ii)(B) exempts a person that only acts as a payment processor facilitating the purchase of goods or services "through a clearance and settlement system by agreement with the creditor or seller." FinCEN rulings (FIN-2013-R002, FIN-2014-R009) list four conditions. FIN-2014-R009 suggests that disbursing by monetary instrument outside a clearing system limited to BSA-regulated institutions may defeat the exemption. **Our payouts are by check, so this needs specific review.** Would paying organizers by ACH be safer?
  - Agent-of-payee: Does our agency appointment, under which the buyer's payment to HåfaPass satisfies the buyer's debt to the organizer, support an agent-of-payee position? Is the current wording enough?
  - Guam: The table of contents lists 11 GCA Chapter 109 as "Foreign Exchange" (§§109101-109123). A licensing consultant says Guam money transmitters are licensed under it by the Banking and Insurance Commissioner. Not verified from the statute text. Does it reach domestic payouts to organizers?
- [ ] **Lawyer:** Should organizer funds sit in a separate (trust or custodial) account?

## 7. Stripe structure

- [ ] **Lawyer/accountant:** Is the current structure acceptable to Stripe and under the law? Stripe's support article says businesses in US territories other than Puerto Rico are not supported and must be located in the 50 states, Washington, D.C., or Puerto Rico. Stripe's global availability page does not list Guam. This is why the account uses a Nevada address. Confirm that the account's business address, representative details and description are accurate and compliant.
- [ ] **Lawyer:** Stripe's restricted businesses list does not mention ticketing or events. It does list "payment facilitation and aggregation" and "receiving settlement proceeds for goods or services that you did not provide" as restricted. Does selling organizers' tickets on one Shimizu Technology account fall into these categories? Should we disclose the model to Stripe and get written confirmation?
- [ ] **Lawyer/accountant:** Should we move to Stripe Connect, with organizers as connected accounts, before scaling? That could resolve the money transmission, 1099-K and Stripe-restriction questions together. What would it change for Guam-based organizers who cannot hold their own Stripe accounts?
- [ ] **Accountant:** How should chargeback fees and losses be allocated? The draft charges them to organizer proceeds.

## 8. FTC Rule on Unfair or Deceptive Fees (16 CFR Part 464)

The rule took effect 2025-05-12 and covers live-event tickets, including third-party platforms.

- [ ] **Lawyer:** Confirm that what the app does now meets the rule:
  - The advertised ticket price is the all-in total, including the mandatory service fee, and is shown first and most prominently.
  - The fee breakdown is secondary.
  - The checkout total equals the advertised price.
  - Optional add-ons (merchandise, donations) and any government tax are shown separately before payment.
- [ ] **Lawyer:** The FTC FAQ says businesses must explain what a fee is for and names "service fees" as a vague label to avoid. Our UI and policies call it a "service fee". The Buyer Terms explain what it covers. Is that enough, or should the UI label change (for example, "HåfaPass ticketing fee")?
- [ ] **Lawyer:** When the organizer absorbs the fee, is any fee disclosure needed at all?
- [ ] **Lawyer:** Does the rule apply to free-ticket RSVPs, or to events that may not count as "live events" (for example, film screenings, which the FAQ excludes)?
- [ ] Context: In April 2026, StubHub agreed to pay $10 million to settle FTC charges under this rule. The FTC alleged it showed ticket prices without the full amount, including mandatory fees. Order entered 2026-04-10.

## 9. Guam Deceptive Trade Practices–Consumer Protection Act

- [ ] **Lawyer:** Review pricing displays, refund rules and event-change handling under 5 GCA Chapter 32 (§32201 et seq.), which is to be liberally construed in favor of the consumer. Note *Marfega Trading Co.* (1998 Guam 4), which applied the act to a 5% charge added above advertised car rental prices. That makes it directly relevant to fee display.
- [ ] **Lawyer:** Is our default refund rule acceptable when an organizer states no policy? The default is no refunds except for cancellation, postponement or material change, or where the law requires.
- [ ] **Lawyer:** Do any other Guam consumer rules (refund disclosure, ticket resale, price caps) apply?

## 10. Privacy

- [ ] **Lawyer:** Review the Privacy Policy, Cookie Notice and Data Retention Schedule drafts against Guam's breach notification law, 9 GCA Chapter 48 (§§48.10-48.80, enacted as P.L. 30-04 in 2009). The draft commits to notify as that law and other US laws require. Confirm the notice duties, timing and the definition of personal information.
- [ ] **Lawyer:** Confirm our COPPA position. HåfaPass is not directed to children under 13 and does not knowingly collect their data. Parents can buy tickets for children, and attendee names may include minors.
- [ ] **Lawyer:** Confirm whether any US state privacy laws (for example, California's) apply to off-island buyers at our size, and what rights-request process we need. The draft offers access, correction, deletion and export.
- [ ] **Lawyer/accountant:** Set retention periods. The draft says financial, order and audit records are kept at least 7 years (proposed), and marketplace analytics not tied to an order are deleted after 13 months.
- [ ] **Lawyer:** Confirm the processor list and whether we need data processing agreements: Clerk, Stripe, Resend, AWS S3, Sentry, Render, Netlify, Neon, and Apple/Google Wallet.
- [ ] **Lawyer:** What terms should organizers accept for using buyer data they receive for their own events?

## 11. Insurance, entity, contracts and liability

- [ ] **Lawyer:** Is Shimizu Technology's current entity the right one to hold this business, or should ticketing sit in a separate entity?
- [ ] **Insurance broker/lawyer:** Which coverage do we need: general liability, cyber/privacy, errors and omissions, crime/fidelity for held funds? Should we require organizers to carry event insurance and name Shimizu Technology as additional insured?
- [ ] **Lawyer:** Is click-through acceptance of the Organizer Agreement enough? The platform records the accepted version, content digest and time. Should larger organizers also sign the agreement?
- [ ] **Lawyer:** Are the limitation of liability, indemnity, governing law (Guam) and venue clauses enforceable as drafted? All are marked `[Lawyer to confirm]`.
- [ ] **Lawyer/accountant:** What is our exposure if an organizer cancels after being paid out and cannot fund refunds and chargebacks? Should we hold reserves, pay out only after the event, or require personal guarantees?

## 12. Documents to bring or prepare

- [ ] Organizer Agreement draft (`/policies/organizer-agreement`)
- [ ] Buyer Terms draft (`/policies/buyer-terms`)
- [ ] Refund & Cancellation Policy draft (`/policies/refunds`)
- [ ] Privacy Policy, Cookie Notice, Data Retention Schedule, Acceptable Use Policy and Accessibility Statement drafts
- [ ] Stripe account documents: business profile, address, representative, business description, and Stripe Services Agreement
- [ ] Current fee schedule and fee-bearer settings from admin settings
- [ ] Sample receipt, ticket and ticket PDF showing "Sold by … · Tickets by HåfaPass"
- [ ] Payout process: reconciliation report, check-writing procedure, holds and reserves, sample payout statement
- [ ] W-9 collection template and organizer onboarding checklist
- [ ] Shimizu Technology's Guam BPT filings and business license(s)
- [ ] Bank account structure (whether organizer funds are segregated)

## Sources

"Verified" means we opened the page and checked the cited point on 2026-10-21. "Search only" means we saw the cited point in search results but did not open the page.

| Source | URL | Status |
|---|---|---|
| Guam P.L. 38-60 (BPT rate) | https://guamlegislature.gov/38th_Guam_Legislature/Public_Laws_38th/Public%20Law%2038-60.pdf | Search only (PDF too large to fetch). Confirm the rate with DRT. |
| Guam Chamber of Commerce statement on the BPT veto override | https://www.postguam.com/forum/letter_to_the_editor/guam-chamber-of-commerce-statement-on-veto-override-restoring-bpt-relief/article_808da6cd-5bb1-4ffe-a5fe-32bb8231a806.html | Search only |
| Isla Public Media article on BPT | not found | Not found; use the Chamber statement or DRT instead |
| Guam Code Title 11 table of contents (Compiler of Laws, 2026-05-05) | https://col.guamcourts.gov/sites/default/files/11gc_TOC_Q.pdf | Verified (chapter titles, Admission Tax repealed, Ch. 109 Foreign Exchange) |
| 11 GCA Ch. 26, Business Privilege Tax Law (Justia) | https://law.justia.com/codes/guam/title-11/division-2/chapter-26/ | Search only (Justia blocked fetch) |
| 11 GCA Ch. 109 summary (licensing consultant, secondary) | https://faisalkhan.com/solutions/licensing/money-transmitter-license/guam-money-transmitter-license | Search only; not authoritative |
| 5 GCA Ch. 32, Deceptive Trade Practices–Consumer Protection Act (Justia PDF) | https://statecodesfiles.justia.com/guam/2024/title-5/division-3/chapter-32/chapter-32.pdf | Search only |
| *Marfega Trading Co.*, 1998 Guam 4 | https://guamcourts.gov/legacydata/files/Supreme-Court-Opinions/images/1998Guam04.pdf | Search only |
| 9 GCA Ch. 48, breach notification (Justia) | https://law.justia.com/codes/guam/title-9/chapter-48/ | Search only |
| Stripe global availability | https://stripe.com/global | Verified (Guam not listed) |
| Stripe: availability for outlying territories | https://support.stripe.com/questions/stripe-availability-for-outlying-territories-of-supported-countries | Verified |
| Stripe restricted businesses | https://stripe.com/legal/restricted-businesses | Verified (no ticketing entry; payment facilitation and settlement-proceeds entries quoted above) |
| FTC press release: Fees Rule effective 2025-05-12 (ftc.gov/node/88198) | https://www.ftc.gov/news-events/news/press-releases/2025/05/ftc-rule-unfair-or-deceptive-fees-take-effect-may-12-2025 | Verified. Note: node/88198 is this press release, not the StubHub action. |
| FTC: Rule on Unfair or Deceptive Fees, FAQ | https://www.ftc.gov/business-guidance/resources/rule-unfair-or-deceptive-fees-frequently-asked-questions | Verified (prominence, tax exclusion, vague-label guidance) |
| FTC final rule text (16 CFR Part 464) | https://www.ftc.gov/system/files/ftc_gov/pdf/r207011_udf_rule_2024_final_0.pdf | Search only |
| FTC press release: StubHub $10 million | https://www.ftc.gov/news-events/news/press-releases/2026/04/stubhub-refunding-10-million-fees-consumers-after-deceptive-ticket-pricing | Search only |
| FTC case page: FTC v. StubHub Holdings | https://www.ftc.gov/legal-library/browse/cases-proceedings/252-3117-stubhub-holdings-ftc-v | Search only |
| IRS: Form 1099-K FAQs, general information | https://www.irs.gov/newsroom/form-1099-k-faqs-general-information | Verified ($20,000/200 TPSO threshold; no threshold for card payments) |
| IRS: Form 1099-K FAQs, third-party filers | https://www.irs.gov/newsroom/form-1099-k-faqs-third-party-filers-of-form-1099-k | Search only |
| IRS: Should my organization file Form 1099-K? | https://www.irs.gov/newsroom/form-1099-k-faqs-should-my-organization-be-preparing-filing-and-furnishing-form-1099-k | Search only |
| FinCEN ruling FIN-2013-R002 (payment processor exemption) | https://www.fincen.gov/sites/default/files/administrative_ruling/FIN-2013-R002.pdf | Search only |
| FinCEN ruling FIN-2014-R009 | https://www.fincen.gov/sites/default/files/administrative_ruling/FIN-2014-R009.pdf | Search only |
| 31 CFR 1010.100 (eCFR) | https://www.ecfr.gov/current/title-31/subtitle-B/chapter-X/part-1010/subpart-A/section-1010.100 | Not verified (fetch blocked); quoted text comes from the FinCEN rulings |
