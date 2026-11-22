# HåfaPass Readiness Plan — 2027 FD Alumni Basketball Tournament & CO2017 Fundraisers

- **Date:** 2026-11-22
- **Verified baseline:** `origin/main` at `05a81ddb` (updates the plan's `df5deb6a` audit)
- **Owner:** HåfaPass project lead for Leon Shimizu (Shimizu Technology)
- **Related plans:** `Brain-Dump/work/shimizu-tech/fd-co2017-host-year-plan-2026-11-21.md` (v5), `Brain-Dump/work/shimizu-tech/fd-alumni-tournament.md`
- **Target event window:** 2027 FD Alumni Basketball Tournament (~15 regular nights + 2 championship nights, tentative tip-off **Fri Jun 25, 2027**, finals mid-July with storm buffer to late July, FD Phoenix Center / "The Jungle", Guam) plus FD Class of 2017 fundraisers starting with the **Sat Mar 6, 2027** Bryan Ho 5K/beer mile.

## Settled Decisions & Operating Boundaries

- **Payments:** Buyers pay Shimizu Technology's Stripe account. Shimizu pays FDAA/FDMSAA (tournament proceeds) and CO2017 (class fundraisers, into the class's Bank of Guam account) by check. No separate legal review is planned. Hold the final payout ~30 days after the finals for chargebacks (tracked with HåfaPass's existing `reserve_hold` / `reserve_release` balance adjustments).
- **Two HåfaPass organizations:** `FDAA` (tournament tickets, passes, team registration) and `CO2017` (class fundraisers). Separate orgs keep statements, payouts, and tax records apart.
- **Activation timing (Leon, Nov 22):** Build and verify locally and on staging with no rush. Leon will run production activation (taking HåfaPass off pause, creating the `FDAA` and `CO2017` orgs, Render/Neon/Netlify/Stripe/Clerk changes) when we are ready. Section 7 keeps the exact steps ready without blocking implementation.
- **Hub integration:** FD Alumni Hub reads `GET /api/v1/events?organizer=<slug>` server-side and links buyers to HafaPass via `/go/:code`. Keep this contract stable (Section 2).
- **Golf stays separate:** The multi-client golf platform handles its own Stripe/payouts and does not call HåfaPass.

---

## 1. Verified Current State (`05a81ddb`)

### Changes since the plan's `df5deb6a` baseline

- `#196` (`chore/netlify-ignore-unchanged`): skips unchanged production frontend builds on Netlify (docs-only and API-only PRs do not burn Netlify credits).
- `#197` (`fix/phase2-ci-maintenance`): patched Rails, Puma, and MessagePack security advisories.
- `#199` (`1a9c3069`): parallelized RSpec and browser CI critical paths.
- `#200` (`05a81ddb`): upgraded Ruby to `3.3.14` and Brakeman to `8.1.1`.

### Capability audit against 2027 tournament needs

| Tournament need | Verified state at `05a81ddb` | Evidence / gap |
|---|---|---|
| Daily tickets (Adult $16, Student $8, Free $0 QR for alumni/kids/seniors) | **Works today** | `TicketType`, `Commerce::OrderCreator` (free orders skip payment, 0 fee, `DEFAULT_MAX_FREE_TICKETS_PER_IP = 0`), `TicketCredential`. |
| Mar 6, 2027 5K/beer mile single-night fundraiser | **Works today (zero code)** | Needs only Leon-gated production org setup (`CO2017`) and event creation. |
| Service fee (5% + $1 per paid ticket, buyer pays by default, all-in pricing) | **Works today** | `Commerce::ServiceFee`, `EventsController#ALL_IN_TICKET_PRICE_SQL`. $16 daily → $17.80; $70 season pass → $74.50; $45 championship pass → $48.25. |
| Multi-night Season Pass (15 regular nights, championship excluded) & 2-Night Championship Pass (cap 200 adult) | **Missing (Gap 1)** | Each `Order` and `Ticket` belongs to one `Event`; no pass-to-night linkage, no child ticket issuance, no cross-night cascade on refunds/transfers/reschedules. |
| Team registration ($420.16 early / $520.16 late, custom fields, waiver, export) | **Partial (Gap 2)** | `PricingTier` + `PricingTiersCRUD.jsx` work today. `RegistrationQuestion`, `RegistrationResponse`, `EventWaiver`, `CheckoutPage.jsx`, and `SalesToolsPage.jsx` exist, **but** (a) they are gated behind `advanced_sales_tools` alongside donations/catalog/campaigns (`launch_capabilities.rb:57-90`), (b) `SalesToolsPage.jsx` lacks edit/reorder/toggle controls, and (c) `OrganizerSalesExport` dumps all answers into one JSON-quoted string column (`notes_custom_answers`). |
| Tournament-wide sales & 16% revenue-share report | **Missing (Gap 3)** | `OrganizationFinanceSummary` (`GET /api/v1/organizer/finances`) aggregates *all* events for an organization with no tournament/series grouping, no channel/ticket-type rollup across nights, and no 16% revenue-share worksheet. |
| Championship rush load capacity (150+ concurrent buyers) & venue Wi-Fi / carrier NAT | **Needs work (Gap 4)** | Production `render.yaml` runs one `0.5c-512mb` web service with `HAFAPASS_RUNTIME=embedded` (3 web + 1 job thread). `rack_attack.rb` caps `req/ip` at `300/5m`, `orders/ip` at `30/m`, `marketplace-landing/ip` (`/go/:code`) at `60/m`, `marketplace-funnel/ip` at `60/m`, `users/ip` at `20/m`. `OrderCreator` caps held tickets/IP at `60`. `GET /api/v1/events` has no response cache and runs 5+ N+1 queries per event (`events_controller.rb:249-292`). |
| Storm-delay reschedules (`EventChange`) | **Exists for single-night; needs pass fan-out (Gap 1/5)** | `EventLifecycle` + `Organizer::EventsController#update` create `EventChange`, coalesce edits for 10 min (`NOTICE_COALESCE_WINDOW`), and notify direct orders + transferred holders. Pass holders on a rescheduled night are not notified until Gap 1 extends `EmailService#send_event_change_notifications_async`. |
| Cloning 17 nights | **Partial (Gap 5)** | `POST /api/v1/organizer/events/:id/clone` clones `ticket_types`, `pricing_tiers`, and inactive `promo_codes`, **but** `clone_event` (`events_controller.rb:516-528`) drops `venue_id`, `fee_policy`, `buyer_fee_percent`, and `transfers_enabled`, and only clones one night at a time with blank dates. |
| Cash sales & free walk-ups at the door | **Works today** | `BoxOfficeController` + `Commerce::CashSaleCreator` (0 fee, `door_cash` retained by organizer and subtracted from platform payable in `Settlements::Calculator`). Free ($0) walk-ups complete without creating a `Payment`. |
| Offline multi-device gate scanning | **Works today; needs pass count/lock integration + physical drill** | RSA-PSS signed manifests (`Admissions::ManifestBuilder`), IndexedDB verification, offline queue, first-scan-wins reconciliation (`Admissions::Reconciler`), journal recovery. `Admissions::Counts` SQL currently filters `orders.event_id = @event.id` (`admissions/counts.rb:35`), which must be updated for pass child tickets. |

### Repository gates, open PRs, and in-flight worktrees

- **Branch protection on `main`:** `strict: true`, `enforce_admins: true`, `required_conversation_resolution: true`, and 7 required checks:
  `Backend / RSpec`, `Backend / Quality and security`, `Frontend / Test, build, and security`, `Browser / Service recovery smoke tests`, `Repository / Secret and debug hygiene`, `Release / Freeze contract`, and `CodeRabbit`.
- **Cross-family review rule:** In addition to CodeRabbit, this design doc and every money, admissions, locking, or auth PR gets an independent cross-family review (Sol or Opus, since the lead is Gemini) before merge.
- **Open GitHub PRs at `05a81ddb`:** `#198` (Dependabot Ruby), `#195` (Dependabot frontend), `#175` (`.claude/settings.json`). None conflict with our work.
- **Local sibling worktrees on this Mac (do not touch; coordinate if they open PRs):** `t3/ticket-audit-lock-order`, `t3/actor-lock-order-deadlock`, `t3/admissions-recovery-feedback`, `codex/hafapass-commerce-recovery`, `t3/refund-reconciliation-corrections`, `t3/scanner-lock-order`, `t3/admissions-recovery-slice` (1–3 local commits each ahead of `05a81ddb`). Keep edits to `Admissions::Reconciler`, `Ticket#with_entry_lock`, and `Commerce::RefundCreator` minimal, well-isolated, and faithful to `docs/LOCKING.md`.
- **Main checkout (`/Users/leonshimizu/Desktop/ShimizuTechnology/HafaPass`):** Has unrelated uncommitted files; do not touch it.

---

## 2. Stable Public Contract for FD Alumni Hub 2027

The **FD Alumni Hub 2027** lead integrates with HåfaPass via two public paths. All changes in this plan are strictly additive and preserve backwards compatibility:

### 2.1 Event listing (`GET /api/v1/events`)

- **Query:** `GET https://hafapass-api.onrender.com/api/v1/events?organizer=<org-slug>&per_page=50`
  - Example slugs once Leon creates the orgs: `fdaa` (tournament) and `co2017` (class fundraisers).
  - Optional filters already supported: `date_from`, `date_to`, `category`, `featured`, `window` (`tonight`/`weekend`), `price` (`free`/`under_25`/`under_50`), `q`.
  - Additive filter added in Slice 1: `series=<series-slug>` so the hub can fetch only the 2027 tournament events once `FDAA` hosts multiple years.
- **Visibility semantics (`Event.discoverable`):** Only returns `published`, non-suspended, non-held, verified-organizer events whose `COALESCE(ends_at, starts_at) > NOW()` and that have at least one on-sale `ticket_type` with available inventory. Note: a **sold-out** event drops out of `GET /api/v1/events` (`Event.discoverable` filters remaining > 0) while remaining reachable by slug at `GET /api/v1/events/:slug`.
  - **Additive option for the hub (Slice 5):** support `?include_sold_out=true` when `organizer` (or `series`) is specified so the hub can display "Championship Pass — Sold Out" instead of silently hiding a sold-out pass card. Default behavior (`include_sold_out` omitted/false) stays unchanged.
- **Key response fields per event (guaranteed stable):**
  - `id`, `title`, `slug`, `short_description`, `starts_at`, `ends_at`, `doors_open_at`, `timezone`, `status`, `venue_name`, `venue_city`, `purchasable`
  - `organizer`: `{ id, business_name, slug, logo_url, verified }`
  - `ticket_types[]`: `{ id, name, description, price_cents, current_price_cents, all_in_price_cents, service_fee_cents, regular_all_in_price_cents, quantity_available, quantity_sold, quantity_remaining, on_sale, max_per_order, max_per_buyer, sales_start_at, sales_end_at, active_tier, next_tier }`
  - Additive pass metadata (Slice 2): `is_pass: boolean`, `included_events_count: integer`, `included_events: [{ id, title, slug, starts_at, ends_at, status }]` on `ticket_types[]`, and optional `series: { id, slug, name, role }` on the event object.
- **Headers & caching:** Always sends `Vary: Accept-Language`. After Slice 5, unauthenticated `GET /api/v1/events` and `GET /api/v1/events/:slug` return `Cache-Control: public, max-age=15, stale-while-revalidate=30`. The hub's Rails API should still cache server-side (~5 min) and never send user auth tokens on this call.

### 2.2 Attribution deep links (`/go/:code`)

- **Link format:** `https://hafapass.shimizu-technology.com/go/<CODE>`
- **Flow:** `DistributionRedirectPage.jsx` calls `GET /api/v1/distribution_links/:code?anonymous_id=...`, logs a `MarketplaceFunnelEvent` (`stage: :landing`), saves attribution, and redirects to `/events/<event.slug>?distribution_code=<CODE>`. Completed purchases record `AcquisitionAttribution` + `MarketplaceFunnelEvent` (`stage: :purchase`).
- **Admin management:** Partners and links are created via `/api/v1/admin/distribution_partners` and `/api/v1/admin/distribution_links`.
- **Load protection (Slice 5):** Raise `marketplace-landing/ip` and `marketplace-funnel/ip` from `60/min` to `300/min` (ENV-configurable) so a rush from the hub behind Guam carrier NAT does not 429 on `/go/:code`.

---

## 3. Technical Design by Gap

### 3.1 Gap 1: Multi-Night Passes (Season Pass & 2-Night Championship Pass)

#### Architecture decision: Pass Event + Linked `$0` Child `Ticket` Rows on the Same Paid `Order`

**How an organizer sets up the 2027 tournament:**
1. Create an `EventSeries`: `"2027 FD Alumni Basketball Tournament"` (`slug: "fd-2027-alumni-basketball"`).
2. Create the 15 regular-season night events (`role: "regular_night"`) and 2 championship night events (`role: "championship_night"`), each with its daily ticket types (`Adult Daily $16`, `Student Daily $8`, `Free Alumni / Kids / Seniors $0`).
3. Create dedicated pass-sale events (`role: "pass_sale"`):
   - `"2027 FD Alumni Basketball — Season Pass"` with pass ticket types `Adult Season Pass ($70)` and `Student Season Pass ($35)`, each linked to the **15 regular nights** (championship nights excluded by linkage, not hardcoded logic).
   - `"2027 FD Alumni Basketball — Championship Pass (2 Nights)"` with `Adult Championship Pass ($45, quantity_available: 200)` and `Student Championship Pass ($25)`, each linked to the **2 championship nights**.
4. Create `"2027 FD Alumni Basketball — Team Registration"` (`role: "registration"`) with early/late pricing tiers and registration questions.

**Why child `Ticket` rows on the Pass `Order` (not 15 separate `$0` child `Order` rows):**
- **Single source of truth for payment state:** Because each child ticket has `ticket.order_id = pass_order.id`, `ticket.order.ticket_fulfilled?`, `ticket.order.ticket_access_blocked?` (disputes), and `ticket.order.full_refund_pending?` automatically govern admission on every single night with zero async fan-out or drift.
- **Clean settlements and buyer history:** All revenue, Stripe fees, HåfaPass service fee (5% + $1 charged **once** on the pass, not 15×), refunds, disputes, and payouts live on the single Pass `Order` and Pass `Event` statement. Night events record zero pass revenue (no double-counting) while counting pass holders in attendance and door lists. Buyers see **1 order, 1 receipt, 1 confirmation email** instead of 16 orders.
- **Unchanged night-level scanning:** Every child ticket has `ticket.event_id = night_event.id`, its own `qr_code`, its own `scan_credential`, its own `status` (`issued` / `checked_in` / `cancelled`), and `ticket.ticket_type_id = pass_ticket_type.id` (so door scanners immediately display `"Adult Season Pass"` or `"Student Championship Pass"` for wristband color and ID checks). Each night's RSA-PSS offline manifest and first-scan-wins conflict detection work without altering the scanner protocol.

#### Data model changes

1. **`event_series`**
   - `id`, `organization_id` (FK, NOT NULL), `name` (string, NOT NULL), `slug` (string, NOT NULL), `description` (text), `status` (integer enum: `draft: 0, active: 1, completed: 2, archived: 3`, default `0`), `revenue_share_bps` (integer, nullable, check `0..10000`), `revenue_share_base` (string, default `"admissions_net_proceeds"`), `revenue_share_includes_door_cash` (boolean, default `true`, NOT NULL), `revenue_share_label` (string, nullable, e.g. `"Host Class (CO2017)"`), `primary_share_label` (string, nullable, e.g. `"FDAA / FDMSAA"`), timestamps.
   - Unique index `[:organization_id, :slug]`.

2. **`event_series_memberships`**
   - `id`, `event_series_id` (FK, NOT NULL), `event_id` (FK, NOT NULL), `role` (integer enum: `regular_night: 0, championship_night: 1, pass_sale: 2, registration: 3, other: 4`, default `0`), `position` (integer, default `0`, NOT NULL), timestamps.
   - Unique index `[:event_series_id, :event_id]`.
   - Model validation: `event.organization_id == event_series.organization_id`.

3. **`ticket_type_included_events`** (pass entitlements)
   - `id`, `ticket_type_id` (FK, NOT NULL), `included_event_id` (FK → `events.id`, NOT NULL), `position` (integer, default `0`, NOT NULL), timestamps.
   - Unique index `[:ticket_type_id, :included_event_id]`.
   - Check constraint `included_event_id IS NOT NULL`.
   - Model validations:
     - `included_event.organization_id == ticket_type.event.organization_id`
     - `included_event_id != ticket_type.event_id` (no self-reference)
     - Neither the pass event nor any included event may have `event_seating_configuration` (passes are general admission only)
     - `included_event` cannot itself contain pass ticket types (no nested passes)
     - Removing an included event is refused once `ticket_type.quantity_sold > 0` or active holds exist. Adding a new night later is allowed via an explicit organizer action (`POST /api/v1/organizer/events/:event_id/ticket_types/:id/sync_pass_holders`) that idempotently issues missing child tickets for active (`issued`) parent passes (relying on the partial unique index below).

4. **`tickets` column addition**
   - `parent_ticket_id` (bigint, nullable, FK → `tickets.id`, `on_delete: :restrict`).
   - Index on `parent_ticket_id`.
   - **Partial unique index:** `[:parent_ticket_id, :event_id], unique: true, where: "parent_ticket_id IS NOT NULL"` — DB-level guarantee of at most one child ticket per parent pass per night.
   - Check constraint: `parent_ticket_id IS NULL OR order_item_id IS NULL` — DB-level guarantee that child tickets never own an `order_item` (so financial allocation and per-ticket refund math never split pass dollars across 16 rows).
   - Helper methods on `Ticket`:
     - `pass_child?`: `parent_ticket_id.present?`
     - `pass_parent?`: `parent_ticket_id.nil? && ticket_type.pass?` (where `TicketType#pass?` checks `ticket_type_included_events.exists?` or preloaded association).
     - `pass_container?`: alias/same as `pass_parent?` — parent pass tickets hold ownership, value, refund, and transfer authority; they are **not** directly scannable at a door (`admission_allowed?` returns `false` when `pass_parent?` is true, and `ManifestBuilder` excludes `pass_parent?` tickets so staff cannot accidentally scan a Season Pass on the sales event).

#### Codebase invariants caught & exact handling

Every invariant below was verified against `05a81ddb`:

| Invariant / Code Location | What breaks without explicit handling | Required fix |
|---|---|---|
| **`Admissions::Counts`** (`admissions/counts.rb:28-52`) | `eligible_orders` and `refund_totals` filter `WHERE o.event_id = @event.id`. Child tickets belong to `pass_order` (`o.event_id = pass_event.id`), so `eligible_unadmitted` would count `0` for all pass holders! Also `refund_tickets` check only matches `rt.ticket_id = t.id`, missing a partial-order pending refund on `t.parent_ticket_id`. | Scope `eligible_orders` / `refund_totals` to `o.id IN (SELECT DISTINCT order_id FROM tickets WHERE event_id = @event.id)`. Update pending-refund `NOT EXISTS` to check `rt.ticket_id = t.id OR (t.parent_ticket_id IS NOT NULL AND rt.ticket_id = t.parent_ticket_id)`. Exclude `pass_parent` tickets from scannable counts. |
| **`Ticket#refund_pending?`** (`ticket.rb:82-84`) | If a buyer purchases 2 Season Passes in one order and refunds 1 pass, `RefundTicket` references `parent_ticket_1`, not its 15 children. `child.refund_pending?` would return `false` while the refund is pending! | Check `order.full_refund_pending? || pending_refund_tickets.any? || (parent_ticket&.pending_refund_tickets&.any? || false)`. Preload `parent_ticket: :pending_refund_tickets` in `Admissions::ManifestBuilder`. |
| **`Ticket#release_inventory!`** (`ticket.rb:171-181`) and **`OrderLifecycle#release_locked_order!`** (`order_lifecycle.rb:319`) | Child tickets have `ticket_type_id = pass_ticket_type.id` and `order_item_id = nil`. Calling `release_inventory!` on 15 child tickets would decrement `pass_ticket_type.quantity_sold` 15 times (violating `quantity_sold >= 0` or leaking 14 phantom inventory units!). | Guard `Ticket#release_inventory!`: `return if pass_child?`. Inventory is incremented and released strictly once per **parent** pass ticket. |
| **`OrdersController#cancel_ticket`** (`orders_controller.rb:249`) | `if ticket.refundable_cents.zero?` runs `cancel_free_ticket!`. Because a paid Season Pass's child ticket has `order_item_id: nil` → `refundable_cents == 0`, a buyer calling `cancel_ticket` on a child ticket could silently destroy their own Night 5 entry with no refund! | Reject `cancel_ticket` when `ticket.pass_child?` with `422` (`"Multi-night pass tickets cannot be cancelled one night at a time"`). |
| **`Event#max_capacity` & `OrderCreator#enforce_event_capacity!`** (`order_creator.rb:638`, `event.rb:195`) | Capacity checks currently sum `event.ticket_types.sum(:quantity_sold)` and `event.inventory_holds`, ignoring pass child tickets and active pass holds targeting that night. | Count active non-cancelled child tickets on `event_id` AND active holds on pass `ticket_types` whose `ticket_type_included_events` includes `event_id`. On pass checkout, enforce `max_capacity` on the pass event AND every included night event (under sorted event locks). |
| **`OrganizerSalesQuery` & `OrganizerSalesExport`** (`organizer_sales_query.rb:38,85`, `organizer_sales_export.rb:83`) | On a night event, `orders` view filters `@event.orders` (missing pass orders, which is actually right for revenue so Night 1–15 don't double-count $70); `filters["ticket_type"]` rejects pass `ticket_type_id`; `OrganizerSalesExport#allocated` falls into `legacy_residual` when `ticket.order_item` is nil! | In `OrganizerSalesExport`, if `ticket.pass_child?`, financial columns return `$0.00` (with `ticket_type` showing `"Adult Season Pass (Pass)"`). In `OrganizerSalesQuery`, allow filtering by pass `ticket_type_id`s linked to `@event`, and keep `orders` view scoped to direct orders on `@event` so night financial exports never double-count pass revenue. |
| **`TicketEmailAttachments`** (`ticket_email_attachments.rb:10`) | `MAX_ATTACHMENTS = 10`. A 15-night Season Pass generates 15 child tickets; attaching 15 PDFs exceeds the cap and bloats email payloads. | For pass orders with >2 child tickets, omit per-night PDF attachments from the confirmation email and link directly to the Order / Pass page where each night's QR and PDF can be opened/downloaded. For ≤2-night passes (e.g. Championship Pass), attach the 2 night PDFs normally. Exclude `pass_parent?` tickets from PDF attachments. |
| **`CompletePastEventsJob` & `EventLifecycle` `:complete`** (`event_lifecycle.rb:109`) | If a typhoon delays Night 15 or Finals past the Pass Event's original `ends_at`, `CompletePastEventsJob` could auto-complete the Pass Event early. | Block completing a Pass Event while any included night event is still `draft`, `published`, or `postponed`. |
| **`Admissions::ManifestBuilder`** (`manifest_builder.rb:84`) | A scanner accidentally opened on the Pass sales event would see parent pass tickets if not filtered. | Exclude `pass_parent?` tickets from manifests (only scannable tickets appear). On night events, child tickets appear normally with `ticket_type: "Adult Season Pass"` and `code: "HP-T<child_id>"`. |

#### Locking contract extension (`docs/LOCKING.md`)

All pass operations strictly obey and extend `docs/LOCKING.md` so no lock-order cycles are possible:

- **Extended Rank order:**
  - Rank 0: `Actor` (`FOR NO KEY UPDATE`) — scanners/staff only, never acquired by checkout/refund/webhook.
  - Rank 1: `Organization` (`FOR NO KEY UPDATE` for checkout/completion/transfer/reconciler; `FOR UPDATE` for refunds/disputes/lifecycle). Note: `FOR NO KEY UPDATE` conflicts with `FOR NO KEY UPDATE` and `FOR UPDATE`, while remaining compatible with FK `KEY SHARE` (so single-event commerce audit inserts cannot cycle).
  - Rank 2: All involved `Event` rows locked in **ascending `event.id` order** (`Event.where(id: ids).order(:id).lock(...)`).
  - Rank 2a: Scanner device & actor grants (reconciler only).
  - Rank 3: `Order`, then `Payment`, `InventoryHold`, `Refund`.
  - Rank 3a: `Ticket` rows in **ascending `ticket.id` order** (parent + all children), then `TicketTransfer` rows in ascending `id` order.
  - Rank 4: Waitlist locks (passes do not hold per-night waitlist offers; only pass-event waitlist if used).
  - Rank 5: `TicketType` rows in ascending `id` order, then `PricingTier` rows in ascending `id` order.

- **Deadlock proof across the 5 critical concurrent races:**
  1. *Pass Checkout vs Night N Daily Checkout:* Pass Checkout holds `ORG (FOR NO KEY UPDATE)` → sorted events; Night N Checkout holds `night_event (FOR NO KEY UPDATE)` → writes `Order` + `AuditLog` (taking `ORG` FK `KEY SHARE`, which is compatible with `FOR NO KEY UPDATE`). Zero cycle.
  2. *Pass Refund (`RefundCreator`) vs Night N Admission Sync (`Reconciler`):* Both acquire Rank 1 (`ORG`) before any event/order/ticket; `RefundCreator` never acquires Rank 0 (`Actor`). Serialized at `ORG`. Zero cycle.
  3. *Pass Transfer (`TicketTransfers::Manager`) vs Night N Admission Sync (`Reconciler`):* Both acquire `ORG (FOR NO KEY UPDATE)` before events/order/tickets. Serialized at `ORG`. Zero cycle.
  4. *Pass Lost Dispute (`StripeWebhookProcessor`) vs Night N Admission Sync (`Reconciler`):* `StripeWebhookProcessor#cancel_disputed_tickets!` acquires `ORG (FOR UPDATE)` → sorted events → `order` → sorted tickets (parent + children). Serialized at `ORG`. Zero cycle.
  5. *Pass Order Completion (`OrderLifecycle.complete!`) vs Night N Manifest Download (`ManifestBuilder`):* `OrderLifecycle.complete!` detects pass items and takes `ORG (FOR NO KEY UPDATE)` → sorted `[pass_event, *included_events]` before locking `order` and creating child tickets. `ManifestBuilder` takes `ORG (FOR NO KEY UPDATE)` → `night_event`. Serialized at `ORG`. Zero cycle.

#### Cascade rules (Refunds, Disputes, Transfers, Reschedules, Cancellations)

- **Issuance (`OrderLifecycle#issue_tickets!`):** Atomically creates 1 parent pass ticket (`event: pass_event`, `order_item: item`) and $N$ child tickets (`event: included_event`, `order_item: nil`, `parent_ticket: parent_ticket`, `ticket_type: item.ticket_type`), each with a unique `qr_code` and copied `attendee_name`/`attendee_email`/`holder_user`/`holder_email`. Works identically for Stripe, free `$0`, and `BoxOffice` cash sales.
- **Refunds (`Commerce::RefundCreator` + `Commerce::FinancialReversalInventory`):**
  - Selecting a `pass_child` ticket directly in `tickets:` is rejected (`"Refund the parent pass instead of a single night"`).
  - **Unused pass** (zero child tickets `previously_admitted?`): refunding the parent ticket or full order cancels the parent AND every child ticket, bumps `scan_credential_version` on every child (invalidating offline QR/manifests on sync and next build), and releases 1 unit of pass `ticket_type.quantity_sold` (and tier).
  - **Partially used pass** (at least one child ticket `previously_admitted?`):
    - Buyer self-serve and organizer ticket-selected refunds are refused (`"Pass has already been used on one or more nights; use an organizer custom-amount refund or contact support"`).
    - Full-order / admin refund / lost dispute cancels the parent and all **unadmitted** child tickets (stopping future-night entry immediately), while each **already-admitted** child ticket runs through `FinancialReversalInventory` (retaining occupancy history via `TicketInventoryRetention` + `ReconciliationException` `admitted_inventory_retained`, never erasing past attendance).
- **Transfers (`TicketTransfers::Manager`):**
  - Transferring an individual `pass_child` ticket is refused (`"Multi-night passes must be transferred as a whole pass"`). Season passes are per-person (ID + wristband at The Jungle); splitting nights across 15 people is intentionally disallowed.
  - Transferring the `pass_parent` ticket is allowed only when `pass_event.transfers_available?`, zero child tickets have been admitted (`child_tickets.none?(&:previously_admitted?)`), and at least one included night has `starts_at > Time.current`.
  - On `accept!`: under the `ORG → sorted events → order → sorted tickets → transfer` lock, updates `holder_user`, `holder_email`, `attendee_name`, `attendee_email`, and increments `display_credential_version` + `scan_credential_version` on the parent AND all active (`issued`) child tickets.
- **Storm Delays / Reschedules (`EventChange`):**
  - Rescheduling Night N updates `night_n.starts_at`/`ends_at` and creates an `EventChange` on Night N. Child tickets stay attached to Night N and automatically reflect the new date/time on buyer views, PDFs, Wallet passes (`Wallet::PassSync.event_changed`), and Night N's scanner manifest.
  - Extend `EmailService.send_event_change_notifications_async(change)` to also notify holders of active (`issued`) child tickets on `change.event` (deduped by normalized email against direct orders on `change.event`, idempotency key `event-change/#{change.id}/pass-holder/#{email_sha256_32}`).
  - Self-serve event-change refunds apply to the Pass Event if the Pass Event itself is postponed/cancelled; individual night shifts notify pass holders that their pass automatically covers the new date without triggering an automatic $70 full refund after partial attendance.
- **Single-Night Cancellation (`EventLifecycle` `:cancel` on Night N):**
  - Direct orders on Night N receive automatic `EventCancellationRefunds` unchanged.
  - Child tickets on Night N are cancelled (`cancellation_reason: "event_cancelled"`) and pass holders receive the Night N cancellation email; the remaining 14 nights stay active. Any discretionary partial credit is handled by organizer/admin partial refund on `pass_order`.
- **Buyer UX (`OrderConfirmationPage.jsx`, `MyTicketsPage.jsx`, `TicketPage.jsx`):**
  - `OrderPresenter` and `Api::V1::Me::TicketsController` nest `child_tickets` (ordered by `event.starts_at ASC`) under each `pass_parent` ticket instead of flattening 16 cards.
  - The Pass Card highlights **"Tonight's Ticket"** (matching today's Guam date or next upcoming published night) with one tap to open its QR code, Apple/Google Wallet pass, or PDF, plus an expandable list of all included nights with status pills (`Upcoming`, `Checked in`, `Postponed`, `Cancelled`).

---

### 3.2 Gap 2: Team Registration

**What works today at `05a81ddb`:**
- Early/late pricing (`$420.16` early / `$520.16` late) via `TicketType` (`max_per_order: 1`) + time-based `PricingTier`s (`PricingTiersCRUD.jsx`).
- Custom registration questions (`short_text`, `long_text`, `selection`, `checkbox`, `required`, `options`, `position`, `active`) and versioned `EventWaiver`s in `OrderCreator`, `CheckoutPage.jsx`, and `SalesToolsPage.jsx`.

**What we will build (Slice 3):**
1. **Decouple `registration_forms` from `advanced_sales_tools` (`LaunchCapabilities`):**
   - Today `registration_questions` and `event_waivers` require `advanced_sales_tools`, which also unlocks `catalog_items` (including pass-through donations, which complicate FDAA's 501(c)(3) receipts), `promoters`, and `communication_campaigns`.
   - Promote `registration_questions` and `event_waivers` into core `general_admission` (always available when an organizer adds questions/waivers to an event — zero impact on events without them), while keeping `catalog_items`, `promoters`, and `communication_campaigns` gated behind `advanced_sales_tools`. No Render env var flip needed for team registration!
2. **Organizer question management UX (`SalesToolsPage.jsx`):**
   - Wire existing `PATCH /api/v1/organizer/events/:event_id/registration_questions/:id` so organizers can edit prompt/required/options, reorder (`position` up/down), and deactivate/reactivate questions without deleting questions that have responses.
   - Surface Registration Questions & Waivers directly from the Event Editor navigation (not hidden behind an `advanced_sales_tools` gate).
3. **Structured registration CSV export (`OrganizerSalesExport` & `SalesExportsController`):**
   - Fix `registration_answers` formatting (`answer["value"]` scalar formatting instead of `answer.to_json` with literal `\"` escapes).
   - Add an `expand_questions=true` option (default on a new **"Export Registrations (CSV)"** preset in `AttendeesPage.jsx`) that appends one column per `RegistrationQuestion` on the event (ordered by `position, id`, matching `prompt_snapshot` fallback for deactivated questions) alongside `Order #`, `Buyer Name`, `Email`, `Phone`, `Ticket Type`, `Pricing Tier`, `Total Paid`, `Status`, and `Purchase Date`.
   - Standardize the recommended 2027 FD Team Registration question template in runbook notes: *Class / Team Name* (`short_text`, required), *Division* (`selection`: Maroon / Gold / Platinum / Special, required), *Team Captain Name* (`short_text`, required), *Captain Phone / WhatsApp* (`short_text`, required), *Co-Captain / Rep* (`short_text`, optional), *Jersey Color(s)* (`short_text`, optional), *Roster / Notes* (`long_text`, optional), plus *Rules & Waiver* (`EventWaiver`).

---

### 3.3 Gap 3: Tournament-Wide Sales & 16% Revenue-Share Report

**Design (Slice 4):**
- **Single financial source of truth:** Built on `EventSeries` (from Slice 1) and `Settlements::Calculator.call(event)` per member event — read-only reporting layer that never mutates `Settlement`, `Payout`, or the single-payee ledger.
- **API endpoints (requires organization-level `view_finance` permission):**
  - `GET /api/v1/organizer/event_series/:id/report` — JSON tournament rollup
  - `GET /api/v1/organizer/event_series/:id/report_export` — downloadable UTF-8 BOM CSV (multi-section: Summary & Revenue Share, Per-Event Breakdown, Ticket-Type & Channel Breakdown)
- **What the report calculates (integer cents throughout, excluding test/simulated payments in production via `Order.excluding_test_payments`):**
  1. **Per-event table** grouped by `role` (`regular_night`, `championship_night`, `pass_sale`, `registration`, `other`):
     - Tickets issued (paid / free / pass child admissions), checked-in count, gross ticket sales, discounts, buyer refunds, buyer-paid HåfaPass fees, organizer-absorbed fees, processing fees (platform-covered vs organizer-paid), organizer proceeds, door cash retained, net platform payable, paid out, remaining owed, and settlement/payout status (`awaiting_completion`, `not_finalized`, `ready`, `paid`).
  2. **Subtotals by group:**
     - **Admissions (Daily + Season Pass + Championship Pass)**
     - **Team Registration**
     - **All Tournament Events Combined**
  3. **Channel breakdown:** Online (Stripe) vs Door Cash (`door_cash`) vs Free/Comp QR (ticket & check-in counts).
  4. **Ticket-type breakdown across the tournament:** Adult Daily, Student Daily, Free Alumni/Kids/Seniors, Adult Season Pass, Student Season Pass, Adult Championship Pass, Student Championship Pass, Team Registration (Early vs Late tier).
  5. **16% Revenue-Share Worksheet (configurable per `EventSeries` until FDMSAA confirms direction & base):**
     - Inputs stored on `event_series` (editable by org finance/admin, audited):
       - `revenue_share_bps`: default `1600` (16.00%)
       - `revenue_share_base`: `admissions_net_proceeds` (default: admissions organizer proceeds minus refunded proceeds) | `admissions_gross` | `admissions_net_after_processing` | `all_net_proceeds`
       - `revenue_share_includes_door_cash`: `true` (default; shows door cash separately so cash already in hand is never double-paid)
       - `revenue_share_label` (e.g. `"Host Class (CO2017) — 16%"`) & `primary_share_label` (e.g. `"FDAA / FDMSAA — 84%"`)
     - Math: `Commerce::MoneyAllocator.call(base_cents, [revenue_share_bps, 10_000 - revenue_share_bps])` — guarantees `share_cents + remainder_cents == base_cents` with zero penny drift.
     - Displays both the 16% share AND the 84% remainder clearly so whichever direction FDMSAA confirms, no code rewrite is needed.
  6. **Payout closeout note (verified DB constraint):** `payouts` enforces `idx_payouts_unique_provider_id` (`UNIQUE(provider, provider_payout_id) WHERE provider_payout_id IS NOT NULL`). Because payouts remain per-event, if Shimizu writes one physical check (e.g., Check #1042) settling multiple finalized tournament events, record each event payout's `provider_payout_id` as `CHK-1042-E<event_id>` and reference Check #1042 in `evidence.reference` and `evidence.reason`. For the 30-day post-finals chargeback holdback, use existing `BalanceAdjustment` (`kind: "reserve_hold"` negative amount, then `"reserve_release"` 30 days after finals).

---

### 3.4 Gap 4: Load Prep for Championship Rush (Target: by Jun 10)

#### Bottlenecks verified in `05a81ddb`

1. **`EventsController#index` N+1 queries and zero caching (`events_controller.rb:249-292`):**
   - For each event, `event_json` runs separate uncached queries for `active_tickets.count`, `catalog_items.available`, `registration_questions.published`, `event_waivers.published`, and `active_tickets.limit(10).pluck(:attendee_name)`. For 20 tournament events (`?organizer=fdaa`), one request runs 100+ SQL queries.
2. **`Rack::Attack` shared-IP limits (`rack_attack.rb:83-275`):**
   - Guam cellular carriers (Docomo, GTA, IT&E) use carrier-grade NAT and The Jungle puts hundreds of fans on one Wi-Fi egress IP. Current limits will 429 legitimate fans during a 200-pass championship rush:
     - `req/ip`: `300 / 5 min` (60/min total across all fans on one IP)
     - `orders/ip`: `30 / 1 min`
     - `marketplace-landing/ip` (`/go/:code` from Hub): `60 / 1 min`
     - `marketplace-funnel/ip`: `60 / 1 min`
     - `users/ip`: `20 / 1 min`
     - `payment-resume/ip`: `20 / 1 min`
3. **Per-IP hold cap (`OrderCreator::DEFAULT_MAX_HELD_TICKETS_PER_IP = 60`):**
   - 30 buyers behind one NAT holding 2 championship passes hits 60 and blocks buyer #31.
4. **Production runtime (`render.yaml`):**
   - Single `0.5c-512mb` web service with embedded Solid Queue (3 web threads, 1 job thread, `DB_POOL=10`) and Neon auto-suspend/low min CU.

#### Concrete fixes (Slice 5 — code & staging k6; infra apply is Leon-gated in Section 7)

1. **N+1 elimination + short-TTL public cache on `GET /api/v1/events` & `GET /api/v1/events/:slug`:**
   - Preload `active_ticket_counts` in one `Ticket.where(event_id: ids).where.not(status: :cancelled).group(:event_id).count` query (excluding `pass_parent` tickets from attendee counts on pass events if desired, or counting issued units consistently), preload `catalog_items`, `registration_questions`, `event_waivers`, and skip `attendees_preview` query when `show_attendees` is false.
   - Add bounded `ActiveSupport::Cache::MemoryStore` (`size: 32.megabytes`) in production (each Puma worker holds a tiny hot cache; safe across workers because TTL is 15s and invalidation isn't needed for strict checkout inventory—checkout always reads live locked DB rows!).
   - Cache unauthenticated (`@current_user.nil?`) `GET /api/v1/events` and `GET /api/v1/events/:slug` JSON payloads for **15 seconds**, keyed by normalized query params + `request_locale` + `SiteSetting.instance.updated_at.to_i`, and emit `Cache-Control: public, max-age=15, stale-while-revalidate=30` + `Vary: Accept-Language`. Authenticated requests continue returning `Cache-Control: private, no-store` so viewer state (`favorited`, `followed`, `reminder`) never leaks.
   - Add optional `?include_sold_out=true` when `organizer` or `series` filter is present (for the hub's "Sold Out" pass badge).
2. **Re-key / tune `Rack::Attack` limits for Guam CGNAT & venue Wi-Fi:**
   - Make every public IP ceiling ENV-tunable with CGNAT-safe defaults, while keeping strict per-email / per-user / per-credential throttles intact:
     - `RACK_ATTACK_REQ_PER_IP_5M`: default `1200` (was `300`; 240/min/IP)
     - `RACK_ATTACK_ORDERS_PER_IP_1M`: default `120` (was `30`; per-email stays `5/min`, plus `OrderCreator` enforces 1 active unpaid checkout per email + `max_per_buyer` on passes!)
     - `RACK_ATTACK_MARKETPLACE_LANDING_PER_IP_1M`: default `300` (was `60` — protects `/go/:code` hub rushes)
     - `RACK_ATTACK_MARKETPLACE_FUNNEL_PER_IP_1M`: default `300` (was `60`)
     - `RACK_ATTACK_USERS_SYNC_PER_IP_1M`: default `60` (was `20`)
     - `RACK_ATTACK_PAYMENT_RESUME_PER_IP_1M`: default `60` (was `20`)
   - Set `HAFAPASS_MAX_HELD_TICKETS_PER_IP=250` in Render for June–July (Leon-gated; already ENV-configurable in `order_creator.rb:582`).
3. **k6 championship-rush load test (`load_tests/fd_championship_rush.js`):**
   - Target staging (isolated `[LOAD TEST]` fixture with a 2-night Championship Pass capped at 200 units + 150–200 concurrent VUs).
   - Exercise the realistic funnel: `GET /api/v1/events?organizer=<slug>` → `GET /api/v1/distribution_links/:code` → `GET /api/v1/events/:slug` → `POST /api/v1/orders` (using free test pass fixture so Stripe isn't hit, matching `gate_f_onsale.js` safety rules).
   - Pass criteria:
     - **0 oversell:** exactly 200 parent passes + 400 child tickets created; remaining VUs receive clean `422` sold-out responses.
     - **0 unexpected 5xx or 429s** under both distributed-IP and shared-NAT runs.
     - **Latency:** `p(95) <= 1500ms` for checkout, `p(95) <= 300ms` for cached `GET /api/v1/events`.
     - **Stability:** Solid Queue worker keeps up with confirmation deliveries and hold expiry with zero OOM restarts or DB pool exhaustion.
4. **June–July Render + Neon upgrade topology (Leon-gated, see Section 7):**
   - Web service `hafapass-api`: upgrade `0.5c-512mb` → **Standard (`2 CPU / 2 GB`)**, `HAFAPASS_RUNTIME=solid_queue`, `WEB_CONCURRENCY=2`, `RAILS_MAX_THREADS=5`, `DB_POOL=15`.
   - Add 1 dedicated Render Background Worker (`bundle exec bin/jobs`, `HAFAPASS_RUNTIME=solid_queue`, `0.5c-512mb`, `DB_POOL=10`) sharing the same PostgreSQL Solid Queue tables (exact path documented in `docs/SINGLE_SERVICE_RUNTIME.md:41`; no Redis needed).
   - Neon: raise minimum compute (no scale-to-zero) for June–July and confirm pooled connection capacity ≥ 60.
   - Return to `0.5c-512mb` `embedded` in August after tournament closeout.

---

### 3.5 Gap 5: Operational Polish (Cloning 17 Nights, Free QR Tickets, Door Cash, Gate Drill)

1. **Fix `clone_event` & add bulk schedule clone (Slice 1):**
   - Fix `Organizer::EventsController#clone_event` (`events_controller.rb:516-528`) to also copy `venue_id`, `fee_policy`, `buyer_fee_percent`, and `transfers_enabled` (when capability enabled).
   - Add `POST /api/v1/organizer/events/:id/bulk_clone` (max 25 nights per call, transactional) accepting `occurrences: [{ title, starts_at, ends_at, doors_open_at }]` + optional `event_series_id` and `series_role`, creating all 15 regular nights + 2 championship nights as consistent drafts linked into the `EventSeries` in one action.
2. **Free $0 QR tickets (alumni, kids, seniors, FD students):**
   - Configure dedicated $0 `TicketType`s on each daily night (and optionally on championship nights per FDMSAA rules: e.g., `FD Alumni (Free w/ ID)` on regular nights only, `Kids / Seniors (Free w/ ID)` with `max_per_order: 4`).
   - Confirm walk-up free tickets work in `BoxOfficePage.jsx` (`door_cash` with `$0.00` total completes cleanly with no `Payment` row) and add a short test covering `$0` box-office issuance.
3. **3-device offline gate drill (pre-Jun 1 physical rehearsal):**
   - Follow `docs/EVENT_DAY_OPERATIONS.md` on 3 real phones on The Jungle's network using staging/rehearsal events before June 1, explicitly testing:
     - Daily Adult/Student paid ticket + Free $0 QR ticket + Season Pass Night N child ticket + Championship Pass Night 1 child ticket.
     - Offline duplicate scan of a Season Pass child ticket across Device A and Device C → reconnect → first wins, second flags conflict.
     - Revoked/refunded pass child ticket + transferred pass child ticket → rejected on sync and marked invalid in fresh manifest.

---

## 4. Risks & Mitigations

| Risk | Likelihood / Impact | Mitigation |
|---|---|---|
| **Cross-event lock-order deadlock** between pass checkout/refund/transfer and night-event scanner reconciliation | Medium / High | Enforce Rank 1 (`ORG`) → Rank 2 (sorted `event_id`s) → Rank 3 (`order`) → Rank 3a (sorted `ticket_id`s) in `docs/LOCKING.md`, and add latch-based PostgreSQL concurrency specs (short `lock_timeout`, independent PIDs) proving all 5 concurrent races deadlock-free. |
| **Partial-order refund or free-cancel loophole on $0 child tickets** | Medium / High | DB check constraint (`parent_ticket_id IS NULL OR order_item_id IS NULL`), guard `Ticket#release_inventory!` (`return if pass_child?`), block `cancel_ticket` and `RefundCreator` direct child selection, and extend `Ticket#refund_pending?` + `Admissions::Counts` SQL to check `parent_ticket_id`. |
| **Storm mass-reschedule sends 6+ emails to every Season Pass holder** | Medium / Medium | Document storm runbook: postpone affected nights first, then batch schedule updates inside `EventChange::NOTICE_COALESCE_WINDOW` (10 min per night); keep email copy clear ("Night X moved to [new date] — your Season Pass automatically covers it"). |
| **Championship rush throttled on Guam carrier NAT / Jungle Wi-Fi** | High / High | Raise ENV-configurable IP ceilings (`orders/ip`, `req/ip`, `/go/:code`, `HAFAPASS_MAX_HELD_TICKETS_PER_IP`), cache unauthenticated `GET /events` + eliminate N+1s, upgrade Render + Neon for June–July, prove with k6 at 150+ VUs on staging. |
| **Stripe holds/freezes funds partway through 15+ nights** | Low–Med / High | Accepted by Leon (Nov 22); hold final payout ~30 days post-finals via `reserve_hold` adjustment; door cash (`BoxOffice`) works offline from Stripe; zero-code daily-ticket fallback stays intact. |
| **Merge conflicts with local sibling worktrees** (`lock-order`, `admissions-recovery`, `refund-reconciliation`, `commerce-recovery`) | Medium / Medium | Keep `Admissions::Reconciler` and `Commerce::RefundCreator` diffs minimal and isolated in helper services (`Passes::Issuance`, `Passes::Cancellation`, `Passes::TransferCascade`); rebase cleanly if any sibling branch merges to `main`. |
| **Multi-night passes slip past Jun 1** | Low / Medium | Zero-code fallback from plan §5: sell daily + championship tickets on HåfaPass and sell physical season passes at the door. |

---

## 5. Test & QA Plan

Every implementation slice follows `shimizu-pr-workflow` and `application-qa`:

1. **Automated backend tests (RSpec):**
   - Unit & request specs for `EventSeries`, `bulk_clone`, pass issuance (Stripe, free, box office cash), `Admissions::ManifestBuilder` + `Admissions::Counts` + `Admissions::Reconciler` with pass child tickets, pass refunds (unused, partially used, partial-order pending refund, full-order/admin, lost dispute), pass transfers (whole-pass success, child-blocked, post-admission blocked, credential rotation across all nights), `EventChange` fan-out to pass holders, single-night cancellation vs reschedule, `CompletePastEventsJob` pass guard, `Event#max_capacity` with passes, registration question edit/reorder + expanded CSV export, tournament series report + 16% / 84% `MoneyAllocator` cent-exactness, `Rack::Attack` ENV ceilings, and `EventsController` N+1 + cache isolation (authenticated vs unauthenticated, locale `Vary`).
   - **Latch-based PostgreSQL concurrency specs** (`pass_locking_spec.rb`, modeling `ticket_locking_spec.rb`) proving zero deadlocks across Races A–E with short `lock_timeout`.
2. **Automated frontend tests (Vitest + ESLint + Impeccable):**
   - Pass configuration UI, `OrderConfirmationPage` & `MyTicketsPage` Pass Card ("Tonight's Ticket" + night schedule list), `SalesToolsPage` registration question edit/reorder/toggle, `AttendeesPage` expanded registration export, Tournament Series Report & CSV download UI.
   - Run `IMPECCABLE_NO_TELEMETRY=1 npx impeccable@4.6.0 detect --json <changed UI paths>` on every frontend slice.
3. **Real browser QA (local & staging):**
   - End-to-end flows on desktop + mobile viewports (390px): buy a 3-night test pass → verify grouped Pass Card → scan Night 1 (admitted), re-scan Night 1 (conflict), scan Night 2 (admitted) → reschedule Night 3 → verify email delivery record & updated date → refund unused pass → verify all child tickets cancelled in manifest → test team registration checkout + expanded CSV export → verify tournament series report totals match per-event settlements to the exact cent.
4. **Staging load test (k6):**
   - Run `load_tests/fd_championship_rush.js` at 150+ concurrent VUs against isolated staging fixture before Jun 10; archive summary JSON and memory/DB telemetry.
5. **Physical 3-device offline gate drill (Leon + staff, by Jun 1):**
   - Execute `docs/EVENT_DAY_OPERATIONS.md` drill on 3 real phones at The Jungle covering daily, free, season pass, and championship pass tickets.

---

## 6. PR-Sized Implementation Slices & Schedule

All code slices are built and verified locally + on staging; production activation happens only when Leon is ready (Section 7).

| Slice | PR Scope | Est. Days | Review Gates | Acceptance Checks | Target Date |
|---|---|---|---|---|---|
| **Slice 0 (this PR)** | `docs/FD_TOURNEY_2027_READINESS.md` (verified state, design, hub contract, PR plan, activation runbook) | 0.5 | CodeRabbit + **cross-family review (Sol or Opus)** | Design approved; zero unresolved technical/locking objections. | Nov 22–24, 2026 |
| **Slice 1** | **Event Series + Bulk Night Clone:** `event_series` & `event_series_memberships` migrations/models/organizer CRUD, `clone_event` bugfix (`venue_id`/`fee_policy`/`buyer_fee_percent`/`transfers_enabled`), `POST .../bulk_clone`, public `GET /api/v1/events?series=<slug>` filter, organizer Series UI. | 1.5–2 | CodeRabbit + CI | Clone 17 nights in one call into a series; `?series=` & `?organizer=` work; zero regression in `EventsController`. | Dec 2026 – Feb 2027 |
| **Slice 2A** | **Multi-Night Passes — Backend Core, Locking & Cascades:** `ticket_type_included_events` + `tickets.parent_ticket_id` migration, `Passes::Issuance`, `OrderLifecycle` / `OrderCreator` capacity + issuance, `Admissions::Counts` / `ManifestBuilder` / `Reconciler` updates, `RefundCreator` + `FinancialReversalInventory` + `OrdersController#cancel_ticket` + `StripeWebhookProcessor` cascades, `TicketTransfers::Manager` cascade, `EventChange` pass-holder notifications, `CompletePastEventsJob` guard, `docs/LOCKING.md` update + `pass_locking_spec.rb`. | 4–5 | CodeRabbit + **mandatory cross-family review (Sol/Opus)** (money, admissions, locking) | All RSpec + 5-race latch concurrency specs pass; zero oversell; scanner manifest & offline sync work identically on night events; refunds/transfers/disputes/reschedules cascade with 0 cent drift. | Mar – Apr 2027 |
| **Slice 2B** | **Multi-Night Passes — Organizer & Buyer UI:** Organizer pass-entitlement picker on `TicketTypeCRUD`, `sync_pass_holders` action, buyer Pass Card ("Tonight's Ticket" + night schedule) in `OrderConfirmationPage`, `MyTicketsPage`, `TicketPage`, and `OrganizerSalesExport` pass-child display. | 2–3 | CodeRabbit + Impeccable + browser QA (desktop + 390px mobile) | Buyer buys Season Pass & 2-Night Championship Pass in browser QA, opens Tonight's QR, sees rescheduled night update, and organizer scans + exports door list cleanly. | By May 15, 2027 (**passes on sale by Jun 1**) |
| **Slice 3** | **Team Registration Polish:** Promote `registration_questions` + `event_waivers` out of `advanced_sales_tools` into GA (keeping donations/catalog gated), add edit/reorder/toggle UI in `SalesToolsPage.jsx`, add `expand_questions=true` per-question CSV export + clean scalar formatting in `OrganizerSalesExport` & `AttendeesPage.jsx`. | 1–2 | CodeRabbit + Impeccable + browser QA | Team registration works with `HAFAPASS_LAUNCH_SCOPE=general_admission` (no donations exposed); early/late `PricingTier` switches on schedule; expanded CSV has one clean column per question. | **By Apr 15, 2027** |
| **Slice 4** | **Tournament-Wide Sales & 16% Revenue-Share Report:** `EventSeriesReport` service (backed by `Settlements::Calculator`), JSON + CSV endpoints, configurable 16%/84% share worksheet (`MoneyAllocator`), series closeout/payout checklist, Organizer Series Report UI. | 1.5–2 | CodeRabbit + **cross-family review** (financial reporting) + browser QA | Series totals reconcile to the exact cent with per-event `Settlements::Calculator` and `OrganizationFinanceSummary`; 16% + 84% sum exactly to base; CSV downloads cleanly with formula injection protection (`SpreadsheetExport`). | **By May 1, 2027** |
| **Slice 5** | **Load Prep, Caching & k6 Championship Rush:** Eliminate `EventsController#index` N+1s, 15s unauthenticated response cache + `?include_sold_out=true`, ENV-configurable CGNAT-safe `Rack::Attack` defaults, `load_tests/fd_championship_rush.js`, staging k6 run at 150+ VUs, and `render.tournament.yaml` reference template (not auto-applied). | 2–3 | CodeRabbit + **cross-family review** (throttling/caching security) + staging k6 evidence | `EventsController#index` SQL count drops from 100+ to <15; auth state never leaks via cache; staging k6 150+ VU run hits 0 oversell, 0 unexpected 429/5xx, p95 checkout ≤ 1500ms. | **By Jun 10, 2027** |

---

## 7. Production Activation Checklist (Leon-Gated — Run When Ready)

None of these steps are executed by agents. Run them only when Leon decides to activate production.

### Phase A: Baseline production & Mar 6, 2027 fundraiser pilot (zero code required)

1. **Keep HåfaPass unpaused:** Confirm `hafapass-api` (`srv-d6bsuq0gjchc73fu35hg`) stays active on Render ($7/mo) and `https://hafapass.shimizu-technology.com` + `/api/v1/config` report `production` and `live` mode (verify approvals in `docs/PRODUCTION_CUTOVER.md` §8: Policy Register, Resend production, Stripe live).
2. **Create two production organizations** (Admin → Organizations):
   - **`CO2017`** (`slug: "co2017"`, e.g. `"FD Class of 2017"`): for class fundraisers; payout check payee = Class of 2017 Bank of Guam account.
   - **`FDAA`** (`slug: "fdaa"`, e.g. `"FD Alumni Association / FDMSAA"`): for 2027 tournament daily tickets, season/championship passes, and team registration; payout check payee per FDMSAA payout note.
3. **Verify both organizations & payout readiness:**
   - Approve organizer verification for both `CO2017` and `FDAA`.
   - Configure each org's `check` `ConnectedAccount` (payee name, mailing/delivery instructions), submit and approve Gate B payment readiness review, and enter W-9 / tax-exempt info (`OrganizerTaxInformation`) so payouts are not subject to 24% backup withholding.
   - Confirm `ADMIN_EMAILS`, `ADMISSION_MANIFEST_PRIVATE_KEY_PEM`, and `ACTIVE_RECORD_ENCRYPTION_*` are backed up securely.
4. **Create `fd-alumni-hub` distribution partner (Admin → Marketplace → Distribution Partners):**
   - Partner slug: `fd-alumni-hub` (`kind: partner` / `media`).
   - Create `/go/:code` `DistributionLink`s for each fundraiser event, tournament pass event, team registration, and daily night; share codes with the **FD Alumni Hub 2027** lead.
5. **Run the Mar 6, 2027 Bryan Ho 5K/beer mile pilot under `CO2017`:**
   - Publish single-night tickets (~Feb 1).
   - Verify end-to-end live path: online Stripe charge → QR scan at check-in → event completion → statement finalization → check payout into the class's Bank of Guam account → admin payout confirmation with bank/check reference.

### Phase B: 2027 Tournament setup (by Jun 1, after Slices 1–4 deploy)

1. **Confirm open FDMSAA items (through Vince / Jeramiah via Leon):**
   - Exact 2027 dates (tentative Jun 25 – Jul 16, storm buffer to late July).
   - Written one-page payout note: payee name, 5% + $1 buyer-paid fee, refund/storm policy, and ~30-day post-finals chargeback holdback.
   - 16% revenue-share direction and base (host class gets 16% vs FDAA keeps 16%; net ticket proceeds vs gross; whether team registration is included).
   - Team registration fee bearer (`$420.16` early / `$520.16` late all-in or buyer-pays fees) and deadline.
   - 2027 Championship Pass cap (200 adult?) and free-group QR rules (alumni, kids, seniors, FD students).
2. **Create the 2027 Tournament Series under `FDAA`:**
   - Create `EventSeries` (`slug: "fd-2027-alumni-basketball"`) with confirmed 16% reporting parameters.
   - Create Team Registration event (on sale by Apr 15) with early/late pricing tiers, registration questions, and waiver.
   - Bulk-clone the 15 regular nights (`role: regular_night`) and 2 championship nights (`role: championship_night`) with Adult, Student, and Free $0 ticket types and venue `FD Phoenix Center ("The Jungle")`.
   - Create the Season Pass event (linked to the 15 regular nights only) and Championship Pass event (linked to the 2 championship nights, capped per FDMSAA) with `max_per_buyer` configured to prevent scalping.
   - Run the 3-device offline gate drill on real phones at The Jungle.
   - Put Season Passes on sale by **Jun 1**; release Championship Passes ~2 weeks before finals (consider releasing in waves if demand spikes).

### Phase C: June–July load upgrade & August scale-down (by Jun 10 / Aug closeout)

1. **Before Championship Pass release (by Jun 10, Leon-gated):**
   - Verify staging k6 150+ VU run passed on the exact release commit.
   - Upgrade Render `hafapass-api` to **Standard (`2 CPU / 2 GB`)**, switch `HAFAPASS_RUNTIME=solid_queue`, set `WEB_CONCURRENCY=2`, `RAILS_MAX_THREADS=5`, `DB_POOL=15`, `HAFAPASS_MAX_HELD_TICKETS_PER_IP=250`.
   - Start 1 dedicated Render Background Worker (`bundle exec bin/jobs`, `HAFAPASS_RUNTIME=solid_queue`, `0.5c-512mb`, `DB_POOL=10`, identical secrets/encryption keys/DB URLs). Drain embedded queue cleanly during cutover per `docs/SINGLE_SERVICE_RUNTIME.md`.
   - Raise Neon minimum compute (no scale-to-zero) for June–July.
   - Verify `/api/v1/readiness` confirms live worker/scheduler heartbeats and zero overdue jobs.
2. **Closeout (late July – August):**
   - Complete all nights, finalize statements, place 30-day chargeback `reserve_hold` balance adjustment on final proceeds, export final Tournament Series Report + 16% worksheet, write checks, release reserve 30 days post-finals, reconcile payouts (`CHK-<num>-E<event_id>`), and archive closed events.
   - Scale Render back down to single `0.5c-512mb` `HAFAPASS_RUNTIME=embedded` and lower Neon minimum compute.
