# Phase 8 — Competitive General-Admission Features

## Outcome

Phase 8 closes the most important product gaps between HafaPass and mature general-admission ticketing platforms while preserving the commerce, identity, admission, and settlement controls delivered in Phases 1–7.

The implementation deliberately keeps ticket revenue, buyer-paid fees, organizer-absorbed fees, catalog revenue, discounts, refunds, referral commission, and inventory in one order lifecycle. It does not create a second checkout or parallel financial truth for merchandise, donations, or waitlist sales.

## Buyer capabilities

- Secure ticket transfer by email. Acceptance requires the invited Clerk account and atomically rotates both the public display credential and admission credential. The originating order retains history but no longer exposes the accepted ticket credential.
- Apple Wallet `.pkpass` generation with the current admission credential, SHA-1 manifest, detached PKCS#7 signature, pass certificate, and WWDR certificate.
- Google Wallet Save link generation using an RS256 service-account JWT containing an event-ticket class and object.
- Inventory-reserving waitlist offers with a signed, expiring, single-use claim credential and exact ticket/price snapshot.
- Checkout add-ons, merchandise, concessions, and custom donations.
- Required registration questions and versioned waiver acceptance with immutable snapshots.
- Referral-code attribution and UTM source/medium/campaign capture.
- Buyer-pays, organizer-absorbs, or percentage-split platform fees with order and line-item snapshots.
- English fallback plus maintained Japanese and CHamoru event title/description content.

## Organizer capabilities

- A consolidated Sales Tools page configures fee policy, transfer policy, languages, catalog items, registration questions, waivers, promoters, and campaigns.
- Promoter reporting exposes attributed order count, earned commission, refund reversals, and net commission.
- CRM segment counts and authenticated attendee CSV export use the current ticket holder rather than assuming the original purchaser remains the attendee.
- Campaigns can target all attendees, checked-in attendees, not-checked-in attendees, or a ticket type. Recipient emails are deduplicated and all sends use the durable `MessageDelivery` pipeline, idempotency keys, retry handling, and suppression history.
- Physical catalog items have a mutable fulfillment record separate from immutable order-item financial rows.

## Financial and inventory invariants

1. An event row lock serializes checkout, waitlist issuance, ticket inventory, event capacity, and catalog inventory decisions.
2. An active waitlist offer counts against ticket, pricing-tier, and event capacity. Claiming it credits back only that offer during validation and replaces it with an order hold in the same transaction.
3. Catalog inventory moves `available → held → sold`, or `held → released/expired`. A full refund restocks an unfulfilled physical item; already fulfilled inventory is not silently returned.
4. Platform fees are computed only on ticket value. The configured buyer share becomes `service_fee_cents`; the remaining share becomes `organizer_fee_cents`. Both are snapshotted on the order and allocated to ticket order items.
5. A full refund reverses buyer fee, organizer fee, organizer proceeds, refundable catalog inventory, and promoter commission. Settlement and ledger totals consume the same refund components.
6. Order items and refund items remain append-only. Catalog fulfillment is intentionally stored separately so operational fulfillment cannot mutate financial history.
7. Referral commission is created once when payment completes and reversed proportionally from successful refund allocations.

## Wallet provider requirements

Apple requires a pass package containing `pass.json` and image assets, a SHA-1 manifest, and a detached PKCS#7 signature created with the Pass Type ID certificate and Apple intermediate certificate. See [Creating the Source for a Pass](https://developer.apple.com/documentation/walletpasses/creating-the-source-for-a-pass) and [Building a Pass](https://developer.apple.com/documentation/walletpasses/building-a-pass).

Google event tickets use an `EventTicketClass` for shared event data and an `EventTicketObject` for the individual ticket. Web issuance uses an RS256-signed Save to Google Wallet JWT and `https://pay.google.com/gp/v/save/<jwt>`. See [Event ticket classes and objects](https://developers.google.com/wallet/tickets/events/overview/how-classes-objects-work), [Web issuance](https://developers.google.com/wallet/tickets/events/web), and [JWT issuance](https://developers.google.com/wallet/tickets/events/use-cases/jwt).

Required environment variables are documented in `hafapass_api/.env.example`. Until credentials and issuer approval are installed, wallet endpoints return `503 Service Unavailable`; they never emit an unsigned or fake pass.

### Saved pass updates and voiding

Every issued Apple pass serial and Google ticket object is recorded in `wallet_passes`, bound to the scan credential version it carried. When a ticket changes (transfer accepted, holder QR refresh, cancellation, refund or refund pending, dispute opened or resolved, retained inventory, check-in or undo, or an event status/time/venue change), `WalletPassSyncJob` updates the saved pass:

- **Apple.** `pass.json` carries `webServiceURL` (`PUBLIC_API_URL` + `/api/v1/wallet/apple`) and a random per-download `authenticationToken`; only SHA-256 digests of tokens are stored. The PassKit web service under `/api/v1/wallet/apple/v1/...` implements device registration, unregistration, changed-serial listing (`passesUpdatedSince`, a microsecond tag, newest first), latest-pass download with `Last-Modified`/`If-Modified-Since`, and device logs, with `ApplePass` token checks and a per-IP throttle. The job sends an empty APNs push over HTTP/2 to `api.push.apple.com` with the Pass Type ID certificate, and drops device registrations APNs reports as gone. A replaced or ended ticket's latest pass is `voided: true` with no barcode; a temporary pause (dispute, refund pending, postponed event, checked in) removes the barcode without voiding. A status header field announces each change on the device.
- **Google.** The job replaces the `EventTicketObject` through the Google Wallet REST API using a service-account OAuth token (`wallet_object.issuer` scope), holding a row lock on the pass from build to response and queueing another sync if the ticket changed meanwhile. Event title, time and venue live on the shared `EventTicketClass`; an event change updates that class once (sent back as `UNDER_REVIEW`, creating it if Google never saw it) before each object is refreshed. The state becomes `INACTIVE` for an invalid ticket, `EXPIRED` after the event, `COMPLETED` once checked in, and the barcode is removed whenever the credential no longer admits. If the holder never saved the object, an invalid ticket's object is created already inactive so an old save link cannot add a working one.

Both providers stay no-ops until their capability approval is active, and the web service answers `503` until Apple approval is active. Jobs retry throttling, provider errors and network failures with backoff; a definite rejection is recorded on the pass (`last_error`) and retried at the next ticket change. Apple approval now also requires an HTTPS `PUBLIC_API_URL`, because a pass without the web service could never be voided.

To turn the wallets on later, obtain and configure:

| Provider | Variable | Where it comes from |
| --- | --- | --- |
| Apple | `APPLE_TEAM_IDENTIFIER` | Apple Developer Program membership (Team ID) |
| Apple | `APPLE_PASS_TYPE_IDENTIFIER` | A Pass Type ID registered in Certificates, Identifiers & Profiles, e.g. `pass.com.hafapass.ticket` |
| Apple | `APPLE_PASS_CERTIFICATE_BASE64`, `APPLE_PASS_CERTIFICATE_PASSWORD` | The Pass Type ID certificate and private key exported as a `.p12`, base64-encoded, plus its export password. The same certificate signs passes and authenticates APNs pushes |
| Apple | `APPLE_WWDR_CERTIFICATE_BASE64` | Apple Worldwide Developer Relations intermediate certificate (G4), DER, base64-encoded |
| Apple | `APPLE_PASS_ICON_PATH` | Path to the pass icon PNG inside the deployed image |
| Apple | `PUBLIC_API_URL` | Already set in production; must be the HTTPS API origin |
| Google | `GOOGLE_WALLET_ISSUER_ID` | Google Pay & Wallet Console issuer account |
| Google | `GOOGLE_WALLET_SERVICE_ACCOUNT_EMAIL`, `GOOGLE_WALLET_PRIVATE_KEY` | A Google Cloud service account with the Google Wallet API enabled and added as a user on the issuer account; the JSON key's `client_email` and `private_key` |
| Google | `GOOGLE_WALLET_CLASS_REVIEW_STATUS` | `APPROVED` only after Google approves the event-ticket class / issuer for publishing |
| Both | `PROVIDER_CONFIGURATION_REVISION` | Increment when provider configuration changes, then record the capability approval in Gate D |

### Ticket PDFs in emails

Order confirmation and ticket emails attach a PDF for each ticket that admits (up to 10), so buyers can open tickets offline. The durable email payload stores only a signed URL under `PUBLIC_API_URL` + `/api/v1/ticket_email_attachments/`, which Resend fetches when it sends; no URL is added without an HTTPS `PUBLIC_API_URL`. Only tickets that admit right now (`Ticket#admission_allowed?`) get an attachment, so blocked, refunded, disputed, cancelled, transferred and cancelled- or postponed-event tickets do not. The email says exactly what is attached, including when an order exceeds the 10-attachment cap. The link is bound to the ticket's display and scan credential versions and its holder, so after a QR refresh, transfer or refund it returns a short "no longer valid" PDF instead of a working QR code. Links are also limited per link for `GET` and `HEAD` (a `HEAD` probe never renders a PDF). Links expire after three days; a delivery replayed after that gets a 404 for its attachment, so reconcile such deliveries rather than replaying them. Each link and each IP have their own fetch limits.

## Operational rollout

1. Deploy migrations before application instances. Run down/up verification in staging.
2. Configure Apple certificate material and icon path through the secret manager. Validate a pass on a physical iPhone and confirm that the admission QR scans.
3. Configure the Google issuer and service account, approve the generated class in the Google Wallet console, and validate Save-to-Wallet on Android.
4. Start with transfer and waitlist offers enabled for internal events. Exercise accept/cancel/expiry and simultaneous offer/checkout scenarios.
5. Reconcile one buyer-pays, organizer-absorbs, and split-fee order through full and partial refund, settlement, and promoter reporting.
6. Verify merchandise fulfillment and full-refund behavior before enabling physical inventory broadly.
7. Send campaigns first through simulation, then a small internal segment; confirm delivery, bounce, complaint, and suppression handling.
8. Have fluent reviewers approve Japanese and CHamoru content. English remains the guaranteed fallback.

## Automated evidence

- Request coverage for buyer transfer, organizer configuration, waitlist offers, CRM export, campaigns, fulfillment, wallet access, and localization.
- Service coverage for exact transfer credential rotation, single-use waitlist conversion, registration/waiver snapshots, fee allocation, catalog inventory, referral commission, refund reversal, Apple pass structure, and Google JWT structure.
- Non-transactional concurrency coverage for the final ticket, shared event capacity, final door allocation, final catalog item, duplicate waitlist offers, duplicate transfers, and competing refunds.
- The repository gate remains the release contract: RSpec, RuboCop, Brakeman, Ruby and npm audits, frontend tests, production build, and Playwright.
