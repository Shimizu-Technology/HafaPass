# Gate D Provider and Policy Evidence

Status: **application controls implemented; external provider exercises and professional approvals pending**.

HåfaPass must distinguish three facts that are easy to conflate:

1. credentials exist;
2. an integration worked in a test;
3. the exact production configuration and operating model are approved for use.

Only the third fact enables a production capability. The administrative surface at `/admin/provider-readiness` records an evidence reference and SHA-256 digest, a complete control snapshot, effective and expiry times, the exact configuration digest, the submitting administrator, and an independent approving administrator. Reviews are append-only. Rejection and revocation create new records. Expiry, revocation, policy-content changes, provider credential rotation, public identifier changes, or a `PROVIDER_CONFIGURATION_REVISION` change disable the capability without deleting history.

Never paste provider secrets, private legal advice, identity documents, raw webhook bodies, payment data, or customer PII into the evidence reference. Store those in the approved controlled record system and record only its reference and a digest here.

## Capability contracts

### Stripe live payments

Required evidence affirms written territory/entity approval, signed webhook tests, the complete sandbox scenario matrix, zero unexplained reconciliation variance, refund/dispute behavior, and browser-loss/idempotency behavior. Live mode cannot be selected from admin settings without current approval. A legacy database value of `live` also fails closed before an order is created and never exposes the live publishable key.

This capability must not be approved for a Guam entity based only on ordinary Stripe account credentials. The selected provider must confirm the exact entity, territory, merchant model, organizer onboarding, charges, refunds, disputes, settlement bank, and payouts in writing.

### Resend production email

Required evidence affirms domain verification, signed webhooks, event deduplication, delivery/retry behavior, bounce/complaint/suppression behavior, and support resend. Production raises a delivery failure when approval is missing; it does not silently pretend a simulated message reached a buyer. Development and test may still simulate safely.

### Apple and Google Wallet

Wallet buttons are returned to the browser only for independently approved capabilities. Apple evidence covers issuer approval, signing, device installation, and invalidation behavior. Google additionally requires an approved event-ticket class. Configured-but-unapproved endpoints return `503`; no unsigned or placeholder credential is emitted.

### Production policy register

The approved snapshot is bound to the exact backend policy version and content digest. Controls require counsel, accounting, and privacy approval plus effective dates, reacceptance rules, and the retention/deletion/legal-hold workflow. Any content or version change invalidates the approval. In production, readiness fails, checkout returns `503`, and event publication/resumption fails its checklist until the current register is approved.

## Configuration binding

Provider configuration requires a non-secret `PROVIDER_CONFIGURATION_REVISION`. Increment it whenever provider-side state changes even if environment variables do not: verified domains, webhook destinations/subscriptions, provider accounts, issuer/class review, settlement routing, or equivalent settings. Environment credential rotations are fingerprinted automatically using SHA-256; only the resulting aggregate configuration digest is stored. Raw values are never returned by readiness or admin APIs.

## Evidence procedure

1. Freeze the immutable release candidate under Gate A.
2. Configure dedicated sandbox or production-candidate credentials and increment `PROVIDER_CONFIGURATION_REVISION`.
3. Execute the documented matrix and export provider-side results.
4. Reconcile every amount and state transition; unresolved variance means the control is false.
5. Put the report and approvals in the controlled evidence system and calculate its SHA-256 digest.
6. One administrator submits the exact capability snapshot.
7. A different administrator independently compares the reference, digest, controls, configuration, effective time, and expiry, then approves or rejects it.
8. Verify `/api/v1/readiness` reports the intended capability as approved. Optional unapproved wallets remain explicitly disabled without making the whole service unavailable.
9. Revoke immediately when an approval is withdrawn, a material incident occurs, or the approved operating facts are no longer true.

Use `/api/v1/health` as the infrastructure liveness probe while the private production candidate is being configured. `/api/v1/readiness` is the launch/admission signal and intentionally remains `503` until required email and policy evidence is approved. The candidate must remain private or in maintenance mode during that interval; operators need a private route to the admin surface rather than weakening readiness.

## Remaining external evidence

- signed provider event exports for success, decline, authentication, duplication, reordering, browser loss, expiry, refund, dispute, and unknown outcome;
- provider-to-local reconciliation covering payments, fees, refunds, organizer proceeds, settlements, and exceptions with zero unexplained cents;
- Resend domain, delivery, retry, bounce, complaint, suppression, and support-resend evidence;
- real-device Apple/Google installation and invalidation evidence if those capabilities will launch;
- counsel/accounting/privacy-approved policy documents, effective dates, processor/data map, reacceptance rules, retention schedule, deletion procedure, and legal-hold procedure.

The software makes missing evidence visible and enforceable. It does not create the external approval or make a legal, accounting, privacy, or provider decision.
