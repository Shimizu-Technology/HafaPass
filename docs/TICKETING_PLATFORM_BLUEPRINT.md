# HafaPass Ticketing Platform Blueprint

Status: authoritative product and engineering specification
Owner: Shimizu Technology
Last verified: July 20, 2026 (Pacific/Guam)
Companion process: [PHASE_DELIVERY_PLAYBOOK.md](PHASE_DELIVERY_PLAYBOOK.md)

## 1. Purpose

This document is the source of truth for turning HafaPass from a strong ticketing prototype into a dependable Guam ticketing platform. It records what the application is, why it exists, the verified problems in the current implementation, the capabilities required to compete, the target architecture, and the acceptance criteria for every delivery phase.

Older roadmap and audit documents are historical context only when they conflict with this blueprint.

## 2. Product thesis

HafaPass is four connected products:

1. A Guam event-discovery marketplace for buyers.
2. A self-service event and sales workspace for organizers.
3. A commerce, ticket-fulfillment, and organizer-settlement platform.
4. An event-day admissions and box-office system.

The product should become:

> The fastest and most dependable way to publish, sell, discover, and operate an event in Guam, with transparent fees, secure tickets, accurate payouts, reliable offline entry, and real local support.

HafaPass exists because neither a generic overseas platform nor GuamTime completely serves this opportunity. Generic platforms provide mature software but not Guam-specific relationships and operations. GuamTime provides local trust, promotion, and staffing, but its organizer workflow is more assisted and its buyer experience is less modern. HafaPass can combine local service with a genuinely self-service platform.

The initial market is general-admission events:

- Nightlife, concerts, and festivals.
- Cultural, community, and school events.
- Food and drink events.
- Workshops and classes.
- Fundraisers and nonprofit events.
- Brand activations, hospitality events, and Ambros partner events.

Assigned-seat theaters, arenas, season packages, and resale are later capabilities. They must not delay a trustworthy general-admission platform.

## 3. Current application

Sections 3 and 4 preserve the verified pre-Phase-1 baseline that drove this program. They are historical findings, not claims about the post-Phase-10 codebase. Current disposition and remaining evidence gates are recorded in [Platform Completion Audit](PLATFORM_COMPLETION_AUDIT.md).

### 3.1 Stack

- Rails API backend with PostgreSQL.
- React 18 and Vite frontend.
- Clerk authentication.
- Stripe payment intents.
- Sidekiq/Redis background-job support.
- Resend email integration.
- S3-compatible image upload support.
- PWA and internationalization foundations.

### 3.2 Existing product capabilities

The repository already includes meaningful product work:

- Public event marketplace and event-detail pages.
- Organizer profiles and dashboards.
- Event creation, editing, publishing, recurrence, and cloning.
- Ticket types, time/quantity pricing tiers, and promo codes.
- Guest and authenticated checkout surfaces.
- Stripe test/live/simulated payment modes.
- QR tickets and printable PDF tickets.
- Organizer ticket scanning and manual check-in.
- Guest lists and complimentary ticket issuance.
- Order refunds.
- Waitlist signup and organizer notification controls.
- Organizer analytics and platform administration.
- Email jobs, pagination, rate limiting, SEO, and PWA work.

The public interface is already one of the project’s strongest assets. The work below should preserve that quality while repairing the transactional and operational core.

### 3.3 Verified baseline

The July 20, 2026 verification baseline is:

- Backend: 260 RSpec examples, zero failures.
- Frontend lint: completes with three React Hook dependency warnings.
- Frontend production build: completes with an initial-chunk size warning.
- Frontend automated tests: none.
- Production dependency audit: eight findings (one critical, six high, one moderate).

Passing backend tests does not prove the current payment and inventory behavior is correct. Several unsafe behaviors are currently untested or encoded as accepted behavior.

## 4. Verified risk register

This register records the defects found before the phase program began. The implementation status of every family below is superseded by the requirement/evidence matrix in [Platform Completion Audit](PLATFORM_COMPLETION_AUDIT.md); the original wording remains so the reason for each control is not lost.

### 4.1 P0: money, inventory, and data integrity

#### COM-001 — No immutable order-item ledger

Orders store aggregate totals, while tickets still refer to mutable ticket types and pricing tiers. The system cannot reliably reconstruct what was purchased, at what unit price, which discount applied, how fees were allocated, or how much belongs to an organizer.

Required outcome:

- Every sale snapshots ticket name, unit price, tier, quantity, discount, fee, tax, and organizer proceeds.
- Historical sales never change when an organizer edits current inventory.
- Financial events are additive records, not overwritten fields.

#### COM-002 — Pending orders reserve inventory indefinitely

Inventory is incremented before payment but pending orders have no reliable expiry and cleanup lifecycle.

Required outcome:

- Inventory is represented by explicit, expiring holds.
- A scheduled job releases expired holds idempotently.
- The final ticket cannot be oversold under concurrent checkout.

#### COM-003 — Payment webhook race conditions

Late or out-of-order Stripe events can create paid orders with cancelled tickets or released inventory. Webhooks are not first stored as durable, replayable events.

Required outcome:

- Store each webhook once before processing.
- Use an explicit payment/order state machine.
- Validate amount and currency.
- Make processing idempotent and safe for duplicates and out-of-order delivery.
- Reconcile impossible states instead of silently accepting them.

#### COM-004 — Refund history is lossy and concurrency is unsafe

Multiple partial refunds overwrite provider IDs and reasons. Refunds are not allocated to immutable order items and concurrent requests are not protected by a complete idempotency/locking strategy.

Required outcome:

- A refund and refund-item ledger.
- Provider idempotency keys.
- Ticket-level cancellation where appropriate.
- Gross, refunded, net, fee, and payout amounts reported separately.

#### COM-005 — Financial records can be destructively deleted

An organizer can destroy an event, cascading into related orders and tickets.

Required outcome:

- No hard deletion of financially or operationally relevant records.
- Archive, unpublish, cancel, and redact workflows with audit history.

#### COM-006 — Event capacity is not enforced

`max_capacity` is informational and can disagree with aggregate ticket inventory.

Required outcome:

- Capacity and sellable inventory are enforced within the same locked transaction.
- Complimentary, held, sold, refunded, and released inventory have defined effects.

#### COM-007 — Promo usage is not a reliable reservation

Unlimited codes do not increment usage. Limited-code uses can be consumed by abandoned or failed payments without being released.

Required outcome:

- Promo redemptions are held and finalized with the order.
- Failed/expired orders release reserved uses.
- Usage reporting counts all finalized redemptions.

### 4.2 P0: trust, authorization, and privacy

#### SEC-001 — Organizer-controlled privileged fields

Organizer event parameters permit `is_featured` and arbitrary `status`, allowing workflow and curation controls to be bypassed.

Required outcome:

- Organizer-safe fields and administrator-only fields are separated.
- State transitions use dedicated commands with validations and audit records.

#### SEC-002 — Users can self-assign partner status

Organizer profile parameters permit `is_ambros_partner`.

Required outcome:

- Partner verification is controlled only by authorized HafaPass staff.

#### SEC-003 — Organizer publishing has no trust gate

Any authenticated attendee can create an organizer profile and publish without identity, payout, policy, or risk readiness.

Required outcome:

- Organizer organizations, verification state, and risk controls.
- Paid-event publishing requires a payout-ready organizer.
- Admin review rules for higher-risk events.

#### SEC-004 — Ticket lookup exposes personal information

The public QR identifier can return attendee name and email, combining a scan credential with a personal-data bearer token.

Required outcome:

- Separate display, transfer, and scan credentials.
- QR validation returns the minimum data needed for authorized staff.
- Public ticket pages never expose buyer data without a protected token.

#### SEC-005 — Upload authorization and validation are incomplete

Authenticated users can request upload paths for arbitrary event IDs. MIME type is trusted from the request and SVG is accepted without a processing/sanitization pipeline.

Required outcome:

- Event ownership or staff authorization.
- Random collision-resistant object keys.
- Magic-byte validation, safe image processing, size limits, and orphan cleanup.

### 4.3 P0: buyer checkout and fulfillment

#### BUY-001 — Guest confirmation and cancellation are inconsistent

Guest order creation is allowed, while confirmation polling and cancellation rely on authenticated `/me` ownership.

Required outcome:

- A time-limited, revocable guest order access token.
- Guest confirmation, recovery, cancellation, and resend without account creation.

#### BUY-002 — Redirect-required Stripe payments return to an invalid route

The Stripe return URL does not include the required order route identifier.

Required outcome:

- A recoverable payment-return route.
- Checkout state persists across refresh, redirect, and browser closure.
- Payment completion is determined server-side, not trusted from browser state.

#### BUY-003 — Past published events remain purchasable

Order creation checks only `published`, while ticket availability does not consistently gate the event end date.

Required outcome:

- Upcoming, on-sale, capacity, and policy rules enforced in the backend.
- The public UI explains upcoming, on sale, sold out, ended, cancelled, or postponed states.

#### BUY-004 — Free tickets are not necessarily free

The flat service fee applies even when ticket subtotal is zero.

Required outcome:

- An explicit business rule for free events, documented and consistently calculated.

### 4.4 P0: Guam time correctness

#### EVT-001 — Local event times can be interpreted as UTC

Organizer `datetime-local` values are sent without an offset and the create flow does not reliably bind them to an event timezone. Public formatting often uses the viewer’s browser timezone.

Required outcome:

- `Pacific/Guam` is the default event timezone.
- Parse local organizer input with the selected IANA timezone, store UTC, and preserve the event timezone.
- Format buyer, email, PDF, calendar, export, and scanner times in the event timezone and label ChST.
- Validate doors, sales, start, end, refund deadline, and recurrence relationships.

### 4.5 P0: delivery safety and operations

#### OPS-001 — Repository CI is misplaced and incomplete

The workflow lives under `hafapass_api/.github`, which GitHub does not treat as repository-level workflow configuration. It also assumes backend files exist at repository root and runs Minitest instead of RSpec.

Required outcome:

- Repository-root CI with explicit backend/frontend working directories.
- RSpec, frontend lint/test/build, security scans, and dependency audits.
- A single local gate command matching CI.

#### OPS-002 — Frontend behavior has no automated coverage

Required outcome:

- Unit/component tests for calculations and critical UI state.
- Playwright coverage for public discovery, guest checkout, authenticated tickets, organizer publishing, and scanner authorization.

#### OPS-003 — Job and webhook failures are not operationally visible

Required outcome:

- Durable production worker.
- Error tracking and structured logs.
- Alerts for payment, webhook, reconciliation, email, and job failures.
- Admin replay/retry tools with audit records.

#### OPS-004 — Production dependency vulnerabilities exist

Required outcome:

- Upgrade or replace affected production packages.
- Enforce dependency scanning in CI.

## 5. P1 functional gaps

### 5.1 Event-day operations

- Organization and event-level staff roles.
- Offline event manifest and offline scan queue.
- Cross-browser QR decoding fallback.
- Duplicate/conflict resolution across devices.
- Manual attendee search, check-in undo, and audit history.
- Printable emergency door list.
- Door cash sales and a confirmed Guam-supported card-present integration.
- Device health, last-sync, admitted, and remaining counts.

### 5.2 Ticket lifecycle

- Buyer self-service resend and order lookup.
- Secure ticket transfer.
- Barcode rotation after transfer or compromise.
- Apple Wallet and Google Wallet.
- Ticket-level refunds and cancellations.
- Reschedule acceptance/refund flow.
- Dispute state and ticket-freeze policy.
- Attendee detail changes with audit history.

### 5.3 Organizer operations

- Organizations with owner, manager, finance, marketer, box-office, and scanner roles.
- Connected-account readiness and payout status.
- Settlement statements and payout reconciliation.
- Team invitations with expiration.
- Message history and admin resend.
- Refund, cancellation, and reschedule workflows.
- Correct event cloning of pricing, windows, and recurrence semantics.

### 5.4 Marketplace and discovery

- Server-side category, date, location, price, and availability filtering.
- Pagination or load-more through all results.
- One canonical category taxonomy.
- Upcoming-only default inventory.
- Accurate ticket-based attendee counts.
- Correct JSON-LD, canonical URLs, social images, and sitemap domain.
- Curated collections such as Tonight, This Weekend, Family, and village/location.

### 5.5 Waitlist

The current waitlist is a notification list. A real waitlist requires:

- FIFO or organizer-approved policy.
- A signed, single-use offer token.
- Reserved inventory for a defined period.
- Enforced offer expiration.
- Skip/decline/cancel actions.
- Conversion tracking and next-person promotion.
- Rate limiting and privacy-safe status lookup.

### 5.6 Messaging and support

- Durable delivery record with provider ID and state.
- Consolidated order fulfillment instead of one email per ticket.
- Complete HTML escaping and safe URL handling.
- Bounce/suppression handling.
- Admin resend and support notes.
- Cancellation, postponement, refund, waitlist, and reminder templates.
- SMS/WhatsApp consent, opt-out, and delivery history before marketing use.

## 6. P2 competitive expansion

- Donations and nonprofit flows.
- Merchandise, concessions, and event add-ons.
- Registration questions, waivers, and consent capture.
- Promoter/referral attribution and commission reporting.
- Organizer audience exports and segmentation.
- Favorites, followed organizers, reminders, and referrals.
- Venue pages and hotel/concierge distribution.
- Japanese and CHamoru localization where content can be maintained.
- Assigned seating with accessible/companion seat controls.
- Event packages and season products when market demand is proven.

Open resale, speculative tickets, opaque dynamic pricing, and app-only access are not planned launch features.

## 7. Competitive product requirements

### 7.1 GuamTime

GuamTime is active and should be treated as an operational competitor. Its current strengths include local support, event staffing, scanners, assigned seating, merchandise/concession capability, donations, reporting, promotion, and post-event payout. Its opportunity gaps are assisted/manual onboarding, fee complexity, and a less modern self-service experience.

HafaPass must beat GuamTime through:

- Publish in minutes after verification rather than manual page setup.
- Clear all-in pricing and explicit absorb/pass/split settings.
- Modern mobile buyer and organizer experiences.
- Real-time, financially correct reporting.
- Dependable offline entry.
- Automated, reconcilable settlements.
- Promoter attribution and Ambros/hospitality integrations.
- Equal or better local event-day support.

Source: [GuamTime Services](https://www.guamtime.net/services)

### 7.2 Ticketmaster

Adopt the capabilities that protect buyers and event operations:

- Trusted digital tickets.
- Barcode replacement after transfer.
- Wallet passes.
- Controlled transfer.
- Entry and inventory analytics.
- Clear seat/accessibility metadata when seating is introduced.
- Upsells that do not obscure the ticket price.

Do not initially copy global resale, premium inventory, large-venue complexity, or proprietary fan identity systems.

Sources: [Ticketmaster ticket sales](https://business.ticketmaster.com/solutions/ticket-sales/), [Ticketmaster SafeTix](https://business.ticketmaster.com/safetix-encrypted-digital-ticketing/)

### 7.3 Alternative-platform lessons

- Ticket Tailor: simple organizer experience, team access, branding, and offline scanning.
- Luma: low-friction event pages, community, and actionable waitlist/approval flows.
- Humanitix: donations, nonprofit positioning, and fee transparency.
- Eventbrite: self-service publishing and marketplace discovery.
- DICE: nightlife focus, controlled transfers, and buyer fairness.

Sources: [Ticket Tailor features](https://www.tickettailor.com/en-us/features), [Ticket Tailor offline check-in](https://help.tickettailor.com/en/articles/9546560-how-to-use-the-check-in-app-offline), [Luma waitlist](https://help.luma.com/p/waitlist), [Humanitix features](https://humanitix.com/us/features), [Eventbrite pricing](https://www.eventbrite.com/organizer/pricing/), [DICE for venues](https://dice.fm/partners/work-with-us/venues)

## 8. Target domain model

The exact migration sequence may evolve, but the final architecture must express these concepts explicitly.

### Identity and authorization

- `users`: Clerk-backed people.
- `organizations`: organizer or venue businesses.
- `organization_memberships`: role and membership lifecycle.
- `event_staff_assignments`: least-privilege event access.
- `organizer_verifications`: identity/risk review state.
- `audit_logs`: actor, action, target, before/after metadata, timestamp, request context.

### Catalog and inventory

- `venues`: reusable location and accessibility information.
- `events`: schedule, timezone, lifecycle, policy, organization, venue.
- `ticket_types`: current sellable catalog definition.
- `pricing_tiers`: current pricing rules.
- `inventory_holds`: expiring checkout/waitlist reservations.
- `promo_codes` and `promo_redemptions`: reservation and finalized use.

### Commerce ledger

- `orders`: buyer-facing aggregate and lifecycle.
- `order_items`: immutable sale snapshots.
- `fee_components`: platform, processing estimate/actual, tax, organizer fee.
- `payments`: provider attempt and amount.
- `payment_events`: append-only normalized provider events.
- `webhook_events`: raw receipt, processing status, retry/replay state.
- `refunds` and `refund_items`: append-only refund history.

### Fulfillment and admission

- `tickets`: entitlement and lifecycle.
- `ticket_credentials`: revocable/rotatable display and scan tokens.
- `ticket_transfers`: sender, recipient, status, acceptance, credential rotation.
- `check_ins`: append-only admission actions, device, staff, source, reversal.
- `scanner_devices`: authorization and manifest sync state.

### Money movement

- `connected_accounts`: onboarding and payout readiness.
- `settlements`: event/order proceeds calculation.
- `settlement_items`: auditable components.
- `payouts`: provider payout and reconciliation state.
- `adjustments`: reserves, disputes, chargebacks, and manual corrections.

### Lifecycle and communication

- `waitlist_entries` and `waitlist_offers`.
- `message_deliveries`: channel, provider ID, status, attempts, template, actor.
- `event_changes`: cancellation/reschedule change record and buyer response.

Financial tables must prefer append-only events and compensating records. Provider calls must use idempotency keys. Money is stored in integer minor units with explicit currency. Database constraints must defend important invariants in addition to Rails validations.

## 9. Product behavior specification

### 9.1 Event lifecycle

Allowed lifecycle commands are explicit: create draft, submit/verify, publish, unpublish where safe, postpone, reschedule, cancel, complete, and archive. Organizers cannot directly set arbitrary enum values.

Publishing requires:

- Verified organizer and payout readiness for paid events.
- Title, description, category, venue, timezone, start, and end.
- Valid doors and sales windows.
- At least one valid ticket type.
- Capacity/inventory agreement.
- Refund and cancellation policy.
- Required age/accessibility disclosures.
- No start time in the past.

### 9.2 Checkout lifecycle

1. Server validates event/ticket/promo eligibility.
2. Server creates order, immutable items, and expiring holds under locks.
3. Payment attempt receives a unique idempotency key.
4. Buyer completes free or paid checkout.
5. Server reconciles payment using durable provider events.
6. Successful payment finalizes inventory and issues tickets once.
7. Failure, cancellation, or expiration releases inventory and promo reservations once.
8. Confirmation reads authoritative server state through authenticated or guest-token access.

### 9.3 Refund lifecycle

- Calculate refundable balance from the ledger.
- Lock the order/refund scope.
- Create a pending local refund with an idempotency key.
- Submit provider refund.
- Reconcile provider result.
- Allocate the refund to order items and tickets.
- Cancel/reissue/release inventory according to event policy.
- Append financial and audit records.
- Notify the buyer and update settlement/payout calculations.

### 9.4 Check-in lifecycle

- Staff/device authorization is scoped to an event.
- Scanner downloads a signed, versioned event manifest.
- Online and offline scans append device-local actions.
- Server reconciliation accepts one first valid admission and surfaces conflicts.
- Reversal is a separate audited action; check-in history is not overwritten.
- Staff see the minimum buyer information needed to operate the door.

## 10. Security, compliance, and policy requirements

Professional legal and accounting advice is required before production. Engineering must support, not guess, the final policies.

Required decisions and artifacts:

- Merchant-of-record and organizer-agent relationship.
- Organizer agreement and permitted-event policy.
- Buyer terms, privacy policy, refund policy, cancellation/reschedule policy.
- Event permit and organizer warranty requirements.
- Fraud, dispute, negative-balance, reserve, and payout policy.
- Data retention, deletion, export, and breach response.
- Marketing consent and opt-out records.
- Guam business-license and Business Privilege Tax treatment.

The current Guam GRT form lists 5% for major categories, but an accountant must determine what HafaPass and organizer amounts are taxable: [Guam GRT form](https://www.guamtax.com/forms/GRT1.pdf).

Stripe's support guidance says US territories other than Puerto Rico are unsupported, so Guam production eligibility must not be inferred from the US availability listing. HafaPass uses the provider-neutral decision in [GUAM_PAYMENT_AND_PAYOUT_DECISION.md](GUAM_PAYMENT_AND_PAYOUT_DECISION.md): pursue PayPal Multiparty approval, retain a controlled local-bank/manual fallback, and require written confirmation before any Stripe production use. See [Stripe territory support](https://support.stripe.com/questions/stripe-availability-for-outlying-territories-of-supported-countries?locale=en-GB), [PayPal Multiparty](https://developer.paypal.com/docs/multiparty/?multiformSubmitted=true), and [PayPal state codes](https://developer.paypal.com/api/nvp-soap/state-codes/).

Stripe-hosted fields reduce card-data scope but do not eliminate PCI duties. The platform must confirm its correct PCI DSS 4.0.1 SAQ and script/vulnerability controls: [PCI SSC SAQ guidance](https://blog.pcisecuritystandards.org/faq-clarifies-new-saq-a-eligibility-criteria-for-e-commerce-merchants).

Public flows target WCAG 2.2 AA. Assigned seating must implement accessible-seat purchase, price, companion, transfer, and release rules: [ADA web guidance](https://www.ada.gov/resources/web-guidance/), [ADA ticket-sales guidance](https://www.ada.gov/resources/ticket-sales/).

## 11. Quality and operational service levels

### Correctness

- Oversold tickets: zero.
- Unreconciled payment/order differences: zero at event settlement.
- Duplicate ticket issuance: zero.
- Payout statement variance from ledger: zero.
- All privileged actions: attributable through audit logs.

### Performance targets

- Online scan response: p95 under 500 ms under pilot load.
- Offline cached scan feedback: under 100 ms perceived response.
- Public API p95: under 500 ms for normal catalog queries.
- Checkout pages: no avoidable render-blocking bundle regressions.

### Reliability targets

- Payment and webhook paths are idempotent.
- Job retries are observable and bounded.
- Recovery from provider outage does not lose orders.
- Backup restore is tested before pilot and periodically thereafter.
- Emergency door operation remains possible without internet.

### Product metrics

- Organizer signup-to-publish time.
- Checkout conversion and payment success.
- Active upcoming event inventory.
- Repeat organizer rate.
- Refund completion time.
- Payout accuracy and timeliness.
- Scan latency, throughput, and false-rejection rate.
- Support contacts per 100 orders.
- Waitlist offer conversion.
- Email/SMS delivery success.

## 12. Delivery phases

Implementation details, branch names, test protocol, PR requirements, and Greptile loop are defined in [PHASE_DELIVERY_PLAYBOOK.md](PHASE_DELIVERY_PLAYBOOK.md).

| Phase | Outcome | Exit gate |
|---|---|---|
| 0 | Authoritative blueprint and delivery process | Documentation reviewed and merged |
| 1 | CI, dependency security, gate, worker reliability, observability | Local gate equals green CI; failures alert |
| 2 | Commerce ledger, holds, state machines, refunds, reconciliation | Concurrency and Stripe edge-case matrix passes |
| 3 | Organizer trust, publishing, ChST, accurate marketplace | Privilege, time, past-event, and discovery E2E tests pass |
| 4 | Recoverable checkout and secure ticket lifecycle | Guest, 3DS, privacy, refund, and fulfillment matrix passes |
| 5 | Organizations, staff roles, connected accounts, settlements, payouts | Test organizer settlement reconciles to the cent |
| 6 | Offline scanner and event-day operations | Multi-device offline door simulation passes |
| 7 | Communications, support, compliance, and pilot readiness | Full pilot checklist and real test charge/refund pass |
| 8 | Transfers, wallets, actionable waitlist, add-ons, attribution | Competitive feature E2E suites pass |
| 9 | Marketplace growth and Guam distribution | Discovery and attribution metrics are measurable |
| 10 | Assigned/accessibility-aware seating and larger venues | Seat contention and ADA workflow tests pass |

## 13. Pilot definition of done

HafaPass is pilot-ready only when all are true:

- No open P0 findings from this blueprint.
- CI and the local gate pass on the exact release commit.
- Production dependency scan has no unaccepted critical/high findings.
- The enabled-provider sandbox matrix covers success, decline, additional authentication, browser loss, duplicate/out-of-order webhook, expiration, refund, and dispute; the current Stripe adapter remains part of sandbox regression.
- Local ledger reconciles exactly with enabled-provider sandbox data.
- Guest and authenticated checkout work on desktop and mobile.
- Guam event time is consistent across every surface.
- Organizer onboarding and settlement are exercised end-to-end.
- Three-device offline scanning simulation passes with conflict reconciliation.
- Email delivery, resend, failure, and bounce paths are observable.
- Backup restoration and rollback are tested.
- Legal, accounting, payment, privacy, and event policies are approved.
- An event-day runbook, named support owner, and fallback door list exist.
- A small real test charge and refund are completed before selling pilot inventory.

## 14. Full platform completion definition

The program is complete only when every requirement allocated through Phase 10 has:

1. An implementation merged to `main` through its phase PR.
2. Automated tests at the appropriate unit, request, integration, or end-to-end layer.
3. Runtime/browser evidence for user-visible behavior.
4. Passing CI and local gate evidence.
5. A clean Greptile 5/5 review with actionable comments resolved.
6. Updated documentation and operational runbooks.
7. No contradictory current-state evidence in the completion audit.

Partial feature presence, an endpoint stub, a green narrow test, or a plausible implementation is not evidence of completion.
