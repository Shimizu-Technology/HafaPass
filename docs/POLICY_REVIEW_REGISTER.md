# HåfaPass policy and professional review register

Status: **draft, not professionally approved**. Engineering version `2026-10-counsel-draft-3`; registry status `draft-pending-legal-review`. The public text contains no bracketed counsel instructions. [Counsel review packet](COUNSEL_REVIEW_PACKET.md) contains the legal/tax issues, risk levels, sources and decision checklist. No document is certified for production by an attorney, CPA or privacy reviewer.

| Artifact | Live route | Reviewer | Evidence needed | State |
|---|---|---|---|---|
| Buyer Terms | [Buyer Terms](https://hafapass.shimizu-technology.com/policies/buyer-terms) | Guam/US counsel | seller/agency, remedy, consumer rights, venue approval | Draft |
| Organizer Agreement | [Organizer Agreement](https://hafapass.shimizu-technology.com/policies/organizer-agreement) | Counsel + CPA | money flow, fees, payout, taxes, reserves, indemnity | Draft |
| Privacy Policy | [Privacy](https://hafapass.shimizu-technology.com/policies/privacy) | Privacy counsel | data map, vendor terms, rights, breach, foreign visitor review | Draft |
| Refund & Cancellation | [Refunds](https://hafapass.shimizu-technology.com/policies/refunds) | Counsel + finance | cancellation and postponement workflow, allocation, timing | Draft |
| Acceptable Use | [Acceptable Use](https://hafapass.shimizu-technology.com/policies/acceptable-use) | Counsel + operations | prohibited events, bots, enforcement and review process | Draft |
| Data Retention | [Retention](https://hafapass.shimizu-technology.com/policies/retention) | Counsel + CPA | approved schedule, deletion and legal holds | Draft |
| Cookie Notice | [Cookies](https://hafapass.shimizu-technology.com/policies/cookies) | Privacy counsel | SDK/browser storage inventory | Draft |
| Accessibility | [Accessibility](https://hafapass.shimizu-technology.com/policies/accessibility) | Counsel + accessibility reviewer | tested journeys and claims | Draft |

The linked live site may still serve an older version until this branch is integrated and deployed. Confirm the displayed version when reviewing.

## Engineering verification

This review started from `origin/main` at `f11e191` on 2026-10-22. The policy, refund, email, export, retention, tax and pricing paths were inspected in that tree. Local checks on the branch before commit: 89 focused Rails examples and 20 policy-related frontend tests passed; RuboCop on five changed Ruby files, frontend lint, production build and Impeccable advisory scan passed (no advisory findings). In a local test environment, the buyer terms loaded at desktop width and privacy loaded at desktop and phone widths with the new version, draft notice, legal name and contact; the phone view had no horizontal overflow. These checks do not verify production settings, real email delivery, payment/refund outcomes or an end-to-end checkout. Existing live URL checks from the prior draft do not prove this version is deployed or professionally approved. Verify the rendered pages, checkout and configured support mailbox before any operational approval.

## Engineering and acceptance controls

`PolicyRegistry` renders the YAML templates with admin-set platform/contact/fee/payout values. It rejects unknown placeholders and bracketed drafting notes. The exact unrendered text and version participate in buyer, organizer and register digests; review notes do not. Changing only a support address does not change digests, but this draft's text **and version** do. Buyer checkouts record the current buyer-policy snapshot. Organizers must re-accept the Organizer Agreement before publishing, and an admin must approve the new register digest. The draft-launch acknowledgment is an operations record, not counsel approval. Verify these gates and record the approved source, effective date, reviewer and exact digest after professionals sign off. Never commit signatures, private legal advice or identity documents.

This version replaces `2026-10-counsel-draft-2`. The earlier approval and organizer acceptances are stale. The live deployment needs re-acceptance and re-approval; the lead should schedule these before serving the new text. Until deployment, do not describe these drafts as live.

## Outstanding legal-review items

This table mirrors `review_notes` in `hafapass_api/config/policies.yml`; the YAML is the source shown in the admin register. These notes are not served to buyers or organizers.

| Policy | Section | Reviewer question |
|---|---|---|
| buyer-terms | Who we are and who sells your ticket | Counsel to confirm seller responsibility and that payment to the agent fully discharges the buyer. |
| buyer-terms | Limits on our responsibility | Lawyer to confirm limitation wording and any consumer-law carve-outs. |
| buyer-terms | Governing law and disputes | Counsel to confirm Guam governing law, court venue, informal resolution wording, and enforceability for visiting buyers; decide whether arbitration is appropriate. No arbitration clause is proposed. |
| buyer-terms | Transfers and resale | Counsel to check Guam and federal ticket resale and anti-bot rules; the app supports transfers, not an authorized resale marketplace. |
| buyer-terms | Refunds, cancellations, and event changes | Counsel to set the buyer remedy and any deadline for cancellation, postponement and material changes; card cancellation refunds now start automatically, while cash and non-Stripe door-card returns need manual action. |
| privacy | Information we collect | Counsel to confirm TIN collection, encryption, audited admin disclosure, tax-authority sharing, retention and breach response. |
| privacy | How long we keep it | Counsel and CPA to approve retention periods and a deletion/legal-hold procedure. The 13-month analytics purge is implemented; a seven-year financial-record purge is not. |
| privacy | Service providers | Privacy counsel to review General Translation text transfers, vendor contracts and cross-border processing, including Japan APPI, Korea PIPA and any EU targeting. |
| privacy | Your choices and rights | Counsel to distinguish legal rights from voluntary requests and review marketing email consent, CAN-SPAM unsubscribe and organizer campaign controls. Checkout consent and one-click unsubscribe are implemented. |
| organizer-agreement | Our role as your limited agent | Counsel to confirm agent-of-payee appointment and buyer discharge, check disbursements under FinCEN FIN-2014-R009 and Guam 11 GCA Ch. 109, fund custody, withholding and offsets, and whether licensing or segregated accounts are required. |
| organizer-agreement | Tax information | Accountant to confirm fee-only BPT treatment and current rate, organizer gross receipts, 1099 form and filer, backup withholding, Guam reporting, and electronic substitute W-9 certification and retention. Product collection is not TIN matching or a filed return. |
| organizer-agreement | Chargebacks and negative balances | Lawyer to confirm payment terms and dispute-fee allocation. |
| organizer-agreement | Buyer information | Counsel to settle HåfaPass and organizer data roles, permitted event messages, independent marketing, incident notice and a data-processing addendum if needed. |
| organizer-agreement | Your responsibility for the event | Counsel to set organizer license, permit, alcohol, insurance and accessibility warranties, and decide when proof is required. |
| organizer-agreement | Indemnity and limitation of liability | Lawyer to confirm indemnity and the 12-month fee liability cap. |
| organizer-agreement | Governing law and changes | Lawyer to confirm governing law and venue. |
| retention | Financial, order, and audit records | Counsel and CPA to set a retention schedule and legal-hold process; the product does not automatically purge these records after seven years. |
| retention | Scanner devices | Counsel and operations to approve an enforced scanner-data deletion and lost-device procedure; current wording is an organizer instruction. |
| cookies | Payment and error monitoring | Privacy counsel to review current Clerk, Stripe and Sentry SDK storage/cookie inventory and whether consent controls are required for any nonessential activity. |
| accessibility | What we support | Accessibility reviewer to test actual keyboard and assistive technology journeys before making a broad conformance claim. |

## October 22 implementation review

Risk levels rank what must be checked before operational approval, not legal conclusions. The [counsel packet](COUNSEL_REVIEW_PACKET.md#october-22-policy-findings-and-primary-sources) links the primary sources and fuller questions.

| Risk | Finding | Current disposition |
|---|---|---|
| High | A shared fee-setting change can affect new orders on an already published event; the agreement said changes applied only to newly published events. | The agreement now says to check current terms before further sales. Product follow-up: notify organizers with published events of fee changes. |
| High | Cancellation refunds are automated only for eligible Stripe card payments. Cash, other card providers, disputes and failed attempts need manual reconciliation. | Buyer and organizer policies keep these exceptions explicit; assign an operator and deadline before approving the register. |
| High | The public deletion language implied a seven-year minimum and complete deletion of other records, although neither process exists. | Public text now states the actual retention state. Counsel and CPA must approve a schedule and legal-hold procedure. |
| Medium | A blank support setting sent policy readers to order recovery, which cannot receive privacy or accessibility requests. | Policy rendering now falls back to the mailbox in the support-email migration; confirm that mailbox is monitored. |
| Medium | Repository README names Shimizu Technology LLC while receipts and policies used Shimizu Technology. | Seller identity now uses the LLC name. Verify the registered name and Stripe merchant record before approval. |
| Medium | The refund page's absolute used/transfer/dispute exclusion conflicted with the cancellation promise. | Clarified ordinary requests, dispute handling and nonwaivable cancellation rights. |
| Low | Accessibility statement promised a five-business-day response without a tracked service level. | Removed the deadline and retained a direct assistance route. |

### Acceptance and deployment checks

- Confirm policy register version, `draft-pending-legal-review` status, all counsel notes, no unfilled placeholders, and exact digest.
- Confirm the legal name on policy pages, receipts and emails against registration and payment-provider records; confirm the configured support mailbox and mailing address.
- Confirm organizers re-accept the new agreement and an admin approves the new register digest. This operational acknowledgment does not constitute counsel approval.
- Test all-in event, ticket and checkout totals, cancellation exceptions, export permissions and two-day file expiry in the deployed build. The code inspection does not establish production configuration or delivery.
