# Phase 9 — Marketplace Growth and Guam Distribution

## Outcome

Phase 9 turns HafaPass from an event checkout surface into a governed Guam event marketplace. Buyers can discover only inventory that is currently purchasable, browse curated collections and credibility pages, save events, follow organizers, schedule reminders, and share measurable referral links. Administrators can curate supply, verify venues, manage hospitality and tourism partners, and see supply and conversion health without exposing buyer or visitor identity.

This phase deliberately separates three concepts:

1. Discovery is based on live sellable inventory, including active sales windows, ticket holds, waitlist offers, and event capacity.
2. Attribution is append-only evidence attached to an order. A successful purchase is recorded by the same order lifecycle that issues tickets; a browser event can never claim a sale.
3. Credibility is explicit. Venue and organizer verification flags are governed records, not inferred endorsements or paid ranking.

## Buyer and marketplace capabilities

- Curated, ordered collections with optional publish windows and SEO title/description.
- Tonight and This Weekend windows calculated in `Pacific/Guam`, plus category/family, current price, village, venue, organizer, and text filters.
- Current-price filtering honors the first active time- or quantity-based pricing tier rather than a stale base price.
- Paginated collection, venue, organizer, and event inventory; public collection shelves preview six events and hide empty shelves.
- Favorite events, followed organizers, scheduled email reminders, and a consolidated Saved page.
- User referral links with high-entropy codes. Public referral responses never reveal the referring user's identity.
- Venue pages with address, village, verification, accessibility notes, and upcoming inventory.
- Organizer pages with verification, Ambros-partner status, completed-event history, ticket volume, follower count, and upcoming inventory.
- Canonical sitemap entries for non-empty collections and venues/organizers with live inventory.

## Administrator and organizer capabilities

- Administrators can create/update/archive curated collections, venues, distribution partners, and trackable event links through protected APIs. The Marketplace admin screen supports the primary creation and supply-monitoring workflow.
- Partner kinds are constrained to hotel, concierge, tourism, Ambros, and promoter. Links can be independently disabled or expired; disabling a partner disables all its links.
- Supply health reports published upcoming events, presently purchasable events, unavailable inventory, empty collections, organizers without upcoming inventory, missing category supply, and villages represented.
- The admin attribution table groups completed/refunded order evidence by source, medium, and campaign. It contains order counts and gross order value, not customer identity.
- Organizer event analytics show anonymous landing/view/checkout/purchase totals and attributed order counts by source.

## Attribution and privacy contract

The browser creates a random UUID and sends it only for funnel correlation. The API stores an HMAC-SHA256 digest using the application secret; the raw identifier is never persisted. Funnel fields accept only short alphanumeric tracking tokens, so email addresses, names, free-form notes, and other likely personal data are dropped.

Governed distribution and referral links override client-supplied source labels:

- partner link: source = partner kind, medium = `partner`, campaign = governed link campaign;
- fan referral: source = `user_referral`, medium = `share`, campaign = referral code;
- ordinary UTM visit: sanitized source/medium/campaign;
- no source: `direct / none`.

Checkout snapshots one `AcquisitionAttribution` per order. Only `OrderLifecycle` creates the purchase funnel row, and a unique database index makes that operation idempotent. Failed, abandoned, cancelled, and expired checkouts do not become purchases. Anonymous, non-order funnel events are deleted after 13 months by `PurgeMarketplaceAnalyticsJob`; order-linked purchase evidence remains part of the commerce audit trail.

The frontend retains attribution for 30 days. A later redirect merges its governed code without erasing the trusted partner/referral fields. Checkout sends both the anonymous identifier and attribution snapshot, but the server independently resolves governed codes and rejects event mismatches.

## Reminder delivery contract

Creating or rescheduling a reminder increments its effective schedule through the stored `remind_at` value. `EventReminderJob` receives that timestamp and exits if a stale queued job runs after the reminder changed or was cancelled. Reminder mail uses the existing durable `MessageDelivery` pipeline for retries, provider idempotency, bounce/suppression history, and support visibility.

## Data integrity and performance

- Database uniqueness protects one favorite, follow, reminder, referral, collection membership, and acquisition snapshot per applicable owner/scope.
- Foreign keys use cascade only for user preferences; financial, funnel, referral, collection-event, and distribution evidence uses restrict semantics.
- Discovery indexes cover event status/start/category, case-insensitive village, venue availability, collection order, reminder schedules, funnel stage/time, visitor/time, and order purchase uniqueness.
- Public query endpoints use the shared pagination contract. Collection ordering uses a subquery so PostgreSQL can preserve editorial order without an invalid `DISTINCT`/`ORDER BY` combination.
- Inventory queries account for current holds and waitlist offers; empty and sold-out inventory is not promoted as purchasable.
- Rack Attack limits anonymous funnel and distribution-link write paths per IP.

## Operational workflow

1. Create and verify reusable venues before associating them with events. Association copies the current venue name/address/village onto the event as an operational snapshot.
2. Create distribution partners with a truthful kind and contact record. Never place guest/customer data in a campaign value.
3. Create one event-specific link for each channel or campaign that needs independent measurement. Disable the link or partner when the relationship ends.
4. Curate collections only from published events with live inventory. The public API and sitemap automatically suppress empty shelves, but the supply dashboard still reports them for remediation.
5. Review unattributed/direct, partner, and referral conversion in aggregate. Do not use the anonymous visitor hash as a customer profile or export it to partners.
6. Schedule `PurgeMarketplaceAnalyticsJob.perform_later` daily in production and alert on repeated job failure.

## Deployment and rollback

Deploy `20260721010000_create_marketplace_growth` before `20260721010100_create_marketplace_referrals`, then application instances and workers. Both migrations are additive. A test-database rollback drill successfully ran referral down, marketplace down, marketplace up, and referral up in sequence.

Rollback of application code is safe while the new tables/columns remain. Destructive schema rollback is not a normal production response because distribution and acquisition rows may already be audit evidence. Disable marketplace navigation/links first, retain the tables, and schedule a reviewed migration if permanent removal is ever required.

## Verification evidence

- Request tests cover non-empty collection governance, empty shelf suppression, pagination metadata, venue/organizer credibility, Guam filters, effective tier pricing, saved/follow/reminder isolation, referrals, link/event matching, trusted attribution labels, purchase idempotency, and admin authorization.
- Job tests cover anonymous funnel retention while preserving order-linked purchase evidence.
- Frontend unit tests cover anonymous identity and attribution/referral persistence.
- Playwright covers collection discovery, Guam filters, partner redirect persistence, and serious/critical automated accessibility findings.
- The repository release gate remains the final contract: complete RSpec and Vitest suites, RuboCop, Brakeman, dependency audits, production build, and full Playwright.

## Deliberate boundaries

- Attribution is directional product evidence, not multi-touch marketing science. It uses a 30-day last-governed-touch snapshot and does not fingerprint visitors.
- Referral tracking does not create a fan commission or cash entitlement. Paid promoter commissions remain the separately governed Phase 8 promoter ledger.
- Venue verification means an administrator reviewed the venue record; it is not a safety, licensing, accessibility, or event-quality guarantee.
- The admin UI prioritizes creation and monitoring; the protected APIs provide update/deactivation operations for support workflows.
- Assigned seats, sections, accessible/companion seat rules, exchanges, and large-venue seat maps belong to Phase 10 and must use the same order, transfer, refund, admission, and attribution lifecycles.
