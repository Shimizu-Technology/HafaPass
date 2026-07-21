# Gate B Payment Readiness Operations

## Purpose

Gate B converts provider, legal, accounting, and bank decisions into a fail-closed application control. It does not make those decisions for HafaPass. Paid publishing and payouts remain unavailable until real evidence has been reviewed by two different administrators.

Never put contracts, bank details, identity documents, provider secrets, or unredacted transaction evidence in Git or API fields. Store those in the founder-approved restricted operations system. HafaPass retains only a stable reference, a SHA-256 digest of the approved redacted evidence bundle, decision references, control attestations, actors, and timestamps.

## Required decisions

Before submitting evidence, the actual HafaPass entity, counsel, accountant, selected provider, and bank must resolve and sign:

1. provider and production product approval for Guam;
2. the merchant of record and organizer agency model;
3. the exact charge, partner-fee, refund, dispute, reserve, and payout flow;
4. organizer onboarding and prohibited-event responsibilities;
5. settlement-bank eligibility and bank-detail change verification;
6. Guam Business Privilege Tax and any other applicable tax treatment;
7. fee presentation, absorb/pass/split behavior, and refundability;
8. negative balances, chargebacks, reserves, failed/reversed payouts, and insolvency responsibility;
9. PCI, privacy, sanctions, record-retention, and incident ownership; and
10. effective and expiry/review dates.

The authoritative Guam tax source is the current [11 GCA Chapter 26 Business Privilege Tax Law](https://www.guamcourts.org/compileroflaws/GCA/11gca/11gc026.PDF). The application deliberately does not encode a guessed BPT rate or tax base; the approved fee/tax schedule reference is mandatory.

## Evidence workflow

### 1. Record provider state

An administrator records the provider account identifier, charge capability, payout capability, submitted details, and outstanding provider requirements through the connected-account sync endpoint. Even when all provider fields are positive, HafaPass adds `independent_readiness_approval` and keeps the account blocked.

### 2. Submit the decision snapshot

`POST /api/v1/admin/connected_accounts/:connected_account_id/payment_readiness_reviews`

Required fields:

- `evidence_reference`: restricted-system path or record ID;
- `evidence_digest`: lowercase 64-character SHA-256 digest;
- `provider_approval_reference`: provider/bank approval or contract reference;
- `merchant_of_record`: `platform`, `organizer`, or `provider_managed`;
- `fee_tax_schedule_reference`;
- `liability_schedule_reference`;
- `effective_at` and `expires_at`; and
- every control below set to true.

Required controls:

- `guam_territory_confirmed`
- `platform_entity_model_confirmed`
- `organizer_onboarding_confirmed`
- `charges_confirmed`
- `payouts_confirmed`
- `refunds_disputes_confirmed`
- `bank_account_confirmed`
- `fee_tax_schedule_approved`
- `liability_schedule_approved`

The submitter is the verifier of the source bundle, not the final approver. HafaPass also records a server-generated digest of the connected account and a monotonic readiness revision; clients cannot supply or override it.

### 3. Independently approve

A different administrator reviews the restricted evidence and uses:

`PATCH /api/v1/admin/payment_readiness_reviews/:submission_id/approve`

Self-approval, duplicate approval, expired evidence, incomplete controls, and approving while another approval is active all fail closed. Approval appends a new immutable record and removes the local readiness requirement only when provider requirements are also complete.

Any later change to the provider account ID, territory, currency, capabilities, charge/payout flags, submitted-details state, requirements, or disabled state increments the readiness revision and invalidates that approval permanently. Restoring the same values does not revive old evidence.

If the snapshot is wrong or incomplete, record a reasoned rejection instead:

`POST /api/v1/admin/payment_readiness_reviews/:submission_id/reject`

The rejected record remains in the audit chain, the account stays blocked, and the submitter can create a corrected snapshot. Rejection and approval are serialized so competing reviewers cannot decide the same submission differently.

### 4. Revoke or replace

Revoke immediately when provider permission, seller consent, bank details, entity/model, fees/taxes, liability terms, or scope changes:

`POST /api/v1/admin/payment_readiness_reviews/:approval_id/revoke`

Include a specific `reason`. Revocation appends a record, restores `independent_readiness_approval`, and disables paid publishing and payouts. To replace evidence, revoke the current approval, create a new submission, and obtain a new independent approval. Never edit old evidence.

## Provider-specific acceptance

### PayPal Multiparty

Retain approved-partner confirmation, live app/BN code, enabled seller features, Guam seller eligibility, seller merchant ID, onboarding/consent state, webhook configuration, refund/dispute permissions, disbursement mode, partner-fee permission, settlement bank result, and provider contacts. Sandbox success is not production approval.

### Manual local-bank pilot

Retain bank/merchant underwriting, verified organizer bank instruction, out-of-band bank-detail confirmation, two-person payout authorization, immutable settlement digest, transfer confirmation, bank receipt, and cent-exact reconciliation owner. Manual means controlled bank execution—not an untracked spreadsheet or a fake automated payout.

### Stripe

Keep sandbox-only unless Stripe provides written approval for the exact Guam entity, organizers, Connect architecture, settlement banks, charges, refunds, disputes, reserves, and payouts. A working test key or a US availability page is not sufficient.

## Exit evidence

Gate B is complete only when:

- signed merchant, tax/fee, and liability decisions exist in restricted storage;
- written provider/bank approval covers Guam and the exact HafaPass model;
- one real organizer and settlement account pass onboarding;
- the app contains a current two-person readiness approval whose digest matches the retained bundle;
- paid publishing stays blocked when evidence is absent, incomplete, expired, or revoked; and
- Gate H is still reserved for the later live low-value charge/refund/settlement/payout/bank-receipt loop.
