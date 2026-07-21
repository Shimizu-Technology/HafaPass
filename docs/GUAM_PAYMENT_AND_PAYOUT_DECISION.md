# Guam Payment and Payout Decision

Status: Gate B implementation decision; external legal, accounting, bank, and provider approvals remain open.
Last verified against first-party sources: July 21, 2026

## Decision

HafaPass must keep checkout, organizer balances, and payout execution provider-neutral. The local ledger is authoritative; no provider dashboard is the source of truth for what an organizer is owed.

The launch order is:

1. Pursue PayPal Multiparty marketplace approval as the preferred automated Guam seller-onboarding and payout path.
2. Support a reviewed manual/local-bank payout path for a tightly controlled pilot, using compensating ledger records and finance reconciliation.
3. Keep the current Stripe checkout adapter for sandbox validation and only use Stripe for Guam production money movement after written confirmation that the exact HafaPass entity, Guam organizers, settlement bank accounts, Connect charge model, disputes, refunds, and payouts are supported.

Starting onboarding never makes an organizer payout-ready. An account is ready only when payment acceptance, payouts, submitted identity/business details, and an empty provider requirements list are recorded, complete decision evidence is submitted, and a different platform administrator approves that append-only evidence before it expires.

## Verified provider findings

### Stripe

Stripe's current support guidance says US territories other than Puerto Rico are not supported. Guam therefore cannot be treated as an ordinary US Stripe/Connect deployment. The global availability page alone is insufficient evidence for Guam eligibility. See [Stripe support for outlying territories](https://support.stripe.com/questions/stripe-availability-for-outlying-territories-of-supported-countries?locale=en-GB) and [Stripe Connect architecture](https://docs.stripe.com/connect/how-connect-works).

Deployment consequence: Stripe onboarding starts in `guam_eligibility_review`, and production enablement requires written provider confirmation plus a successful end-to-end test using the real entity and settlement bank configuration.

### PayPal

PayPal's current US agreement covers businesses organized in, operating in, or resident in US territories, and PayPal's state-code reference includes Guam as `GU`. PayPal Multiparty documents seller onboarding, partner fees, refunds/disputes, and payouts, but its current integration checklist says the platform must be an approved partner before going live. Seller permissions must match the features configured for the REST app, including payment, refunds, partner fees, delayed disbursement, and dispute access where used. See the [PayPal US User Agreement](https://www.paypal.com/us/legalhub/paypal/useragreement-full?locale.x=en_US), [PayPal state codes](https://developer.paypal.com/api/nvp-soap/state-codes/), [PayPal Multiparty overview](https://developer.paypal.com/docs/multiparty/?multiformSubmitted=true), [seller-onboarding checklist](https://developer.paypal.com/docs/multiparty/seller-onboarding/onboarding-checklist/), and [integration checklist](https://developer.paypal.com/docs/multiparty/integration-checklist/).

Deployment consequence: PayPal is the preferred automation investigation, not a presumed live capability. `partner_approval`, `seller_onboarding`, `business_verification`, and `payout_method` remain explicit requirements until evidenced.

### Local bank/manual settlement

Local merchant acquiring and banking discussions remain necessary. Bank of Hawaii currently describes a Fiserv/Clover merchant-services offering and explicitly markets Clover devices to businesses in Guam. That is useful evidence for local card-present acquiring, but it does not establish marketplace split payments, seller onboarding APIs, platform fees, automated organizer payouts, or HafaPass underwriting. Those points still require a written bank/Fiserv decision. See [Bank of Hawaii Merchant Services](https://www.boh.com/business/merchant-services) and [Clover Flex for Guam](https://www.boh.com/business/merchant-services/clover/flex).

Deployment consequence: manual payout is a pilot fallback, not an untracked spreadsheet process. It uses a verified connected-account record, immutable settlement version, unique payout idempotency key, finance reconciliation, and append-only audit entry.

## Merchant and liability questions that must be signed off

Before real paid inventory is published, legal, accounting, and the selected provider must document:

- whether HafaPass or the organizer is merchant of record and the exact agency relationship;
- who funds refunds, disputes, chargebacks, provider fees, reserves, and negative balances;
- organizer identity/business verification and prohibited-event controls;
- payout timing, minimums, holds, failed/reversed payout handling, and bank-account changes;
- Guam Business Privilege Tax treatment for ticket price, HafaPass fees, and organizer proceeds;
- PCI DSS scope, privacy/data retention, sanctions screening, and incident ownership.

## Technical invariants

- Money is stored and calculated as integer cents in one currency per organization.
- Finalized settlement versions and their items are immutable and never overwritten.
- A new sale, refund, processing cost, dispute, reserve, adjustment, or payout changes the source digest and requires a new version.
- Pending, processing, and paid payouts reserve funds against the entire event, not just one statement version.
- Organization-wide payout availability nets finalized event entitlements against committed payouts, so a post-payout refund or dispute is withheld from later proceeds.
- Payout retries require the same idempotency key; reusing a key for a different settlement or amount is rejected.
- Cross-organization references are rejected at authorization, model, foreign-key, and database-constraint boundaries where applicable.
- Financial reversals append compensating records. Operators do not edit or delete history.
- Provider capability booleans cannot by themselves enable paid publishing or payouts.
- Readiness evidence carries a SHA-256 digest and references the provider approval, merchant-of-record decision, approved fee/tax schedule, approved liability schedule, Guam territory confirmation, organizer onboarding, bank account, charges, payouts, refunds, and disputes.
- Evidence submission and approval require different administrators. Approval and revocation are new append-only records; approved evidence cannot be edited or deleted.
- Expired or revoked evidence immediately fails `payout_ready?`, even if a provider's last capability sync still says enabled.
- Each submission is bound to a canonical provider-state digest and monotonic readiness revision. Changing or disabling the provider account, capabilities, requirements, territory, currency, or account identifier permanently invalidates the old approval, even if a later sync restores the same values.
- The Gate B migration intentionally removes readiness from every legacy connected account until the two-person evidence process is completed.

## Pilot release gates

- Written PayPal marketplace approval or written approval for another production provider.
- Provider contract and merchant-of-record/liability decision signed off.
- At least one organizer completes real onboarding with a Guam business and settlement account.
- A small real charge, partial refund, settlement, payout, and payout reconciliation complete with zero-cent variance.
- A post-payout refund/dispute proves negative-balance carryforward.
- Manual fallback has dual-control approval, bank-detail verification, payout evidence, and reconciliation ownership.
- No paid event can publish unless its organization has a ready connected account.

Until every applicable gate is complete, HafaPass remains in simulation/sandbox mode for paid events.

The operational workflow and exact API contract are in [Gate B Payment Readiness Operations](./GATE_B_PAYMENT_READINESS_OPERATIONS.md).
