# HåfaPass Readiness Plan — 2027 FD Alumni Basketball Tournament & CO2017 Fundraisers

- **Date:** 2026-11-22 (revised after CodeRabbit & Opus 5.5 cross-family design review)
- **Verified baseline:** `origin/main` at `05a81ddb` (updates the plan's `df5deb6a` audit)
- **Owner:** HåfaPass project lead for Leon Shimizu (Shimizu Technology)
- **Related plans:** `Brain-Dump/work/shimizu-tech/fd-co2017-host-year-plan-2026-11-21.md` (v5), `Brain-Dump/work/shimizu-tech/fd-alumni-tournament.md`
- **Target event window:** 2027 FD Alumni Basketball Tournament (~15 regular nights + 2 championship nights, tentative tip-off **Fri Jun 25, 2027**, finals mid-July with storm buffer to late July, FD Phoenix Center / "The Jungle", Guam) plus FD Class of 2017 fundraisers starting with the **Sat Mar 6, 2027** Bryan Ho 5K/beer mile.

## Settled Decisions & Operating Boundaries

- **Payments:** Buyers pay Shimizu Technology's Stripe account. Shimizu pays FDAA/FDMSAA (tournament proceeds) and CO2017 (class fundraisers, into the class's Bank of Guam account) by check. No separate legal review is planned. Hold the final payout ~30 days after the finals for chargebacks (tracked with HåfaPass's existing `reserve_hold` / `reserve_release` balance adjustments, followed by re-finalizing the statement, writing the final check for the released amount, and recording that payout).
- **Two HåfaPass organizations:** `FDAA` (tournament tickets, passes, team registration) and `CO2017` (class fundraisers). Separate orgs keep statements, payouts, and tax records apart.
- **Activation timing (Leon, Nov 22):** Build and verify locally and on staging with no rush. Leon will run production activation (taking HåfaPass off pause, creating the `FDAA` and `CO2017` orgs, Render/Neon/Netlify/Stripe/Clerk changes) when we are ready. Section 7 keeps the exact steps ready without blocking implementation.
- **Hub integration:** FD Alumni Hub reads `GET /api/v1/events?organizer=<slug>` server-side and links buyers to HafaPass via `/go/:code`. Keep this contract stable (Section 2).
- **Golf stays separate:** The multi-client golf platform handles its own Stripe/payouts and does not call HafaPass.

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
| Daily tickets (Adult $16, Student $8, Free $0 QR for alumni/kids/seniors) | **Works today** | `TicketType`, `Commerce::OrderCreator` (free orders skip payment, 0 fee; `DEFAULT_MAX_FREE_TICKETS_PER_IP = 0` deliberately leaves the per-IP free cap off so venue Wi-Fi / Guam carrier NAT isn't blocked, relying on `max_per_order`/`max_per_buyer`), `TicketCredential`. |
| Mar 6, 2027 5K/beer mile single-night fundraiser | **Works today (zero code)** | Needs only Leon-gated production org setup (`CO2017`) and event creation. |
| Service fee (5% + $1 per paid ticket, buyer pays by default, all-in pricing) | **Works today** | `Commerce::ServiceFee`, `EventsController#ALL_IN_TICKET_PRICE_SQL`. $16 daily → $17.80; $70 season pass → $74.50; $45 championship pass → $48.25. |
| Multi-night Season Pass (15 regular nights, championship excluded) & 2-Night Championship Pass (cap 200 adult) | **Missing (Gap 1)** | Each `Order` and `Ticket` belongs to one `Event`; no pass-to-night linkage, no child ticket issuance, no cross-night cascade on refunds/disputes/reschedules. |
| Team registration ($420.16 early / $520.16 late, custom fields, waiver, export) | **Partial (Gap 2)** | `PricingTier` + `PricingTiersCRUD.jsx` work today. `RegistrationQuestion`, `RegistrationResponse`, `EventWaiver`, `CheckoutPage.jsx`, and `SalesToolsPage.jsx` exist, **but** (a) they are gated behind `advanced_sales_tools` across 5 backend/frontend gate sites alongside donations/catalog/campaigns, (b) `SalesToolsPage.jsx` lacks edit/reorder/toggle controls, and (c) `OrganizerSalesExport` dumps all answers into one JSON-quoted string column (`notes_custom_answers`). |
| Tournament-wide sales & 16% revenue-share report | **Missing (Gap 3)** | `OrganizationFinanceSummary` (`GET /api/v1/organizer/finances`) aggregates *all* events for an organization with no tournament/series grouping, no channel/ticket-type rollup across nights, and no 16% revenue-share worksheet. |
| Championship rush load capacity (150+ concurrent buyers) & venue Wi-Fi / carrier NAT | **Needs work (Gap 4)** | `render.yaml` configures `hafapass-api` (`0.5c-512mb`) with `HAFAPASS_RUNTIME=embedded` (3 web + 1 job thread; note the env group is historically named `hafapass-staging-runtime` while setting `RAILS_ENV: production`). `rack_attack.rb` uses Postgres counters (`PostgresThrottleStore`) and caps `req/ip` at `300/5m`, `orders/ip` at `30/m`, `marketplace-landing/ip` (`/go/:code`) at `60/m`, `marketplace-funnel/ip` at `60/m`, `users/ip` at `20/m`. `OrderCreator` caps held tickets/IP at `60`. `GET /api/v1/events` has no response cache and runs N+1 queries per event (`events_controller.rb:249-314`). |
| Storm-delay reschedules (`EventChange`) | **Exists for single-night; needs pass fan-out (Gap 1/5)** | `EventLifecycle` + `Organizer::EventsController#update` create `EventChange`, coalesce edits for 10 min (`NOTICE_COALESCE_WINDOW`), and notify direct orders + transferred holders. Pass holders on a rescheduled night need an informational pass-holder email template (`EventChangeResponse` rejects cross-event orders). |
| Cloning 17 nights | **Partial (Gap 5)** | `POST /api/v1/organizer/events/:id/clone` clones `ticket_types`, `pricing_tiers`, and inactive `promo_codes`, **but** `clone_event` (`events_controller.rb:516-528`) drops `venue_id`, `fee_policy`, `buyer_fee_percent`, and `transfers_enabled`, and only clones one night at a time with blank dates. |
| Cash sales & free walk-ups at the door | **Works today** | `BoxOfficeController` + `Commerce::CashSaleCreator` (0 fee, `door_cash` retained by organizer and subtracted from platform payable in `Settlements::Calculator`). Free ($0) walk-ups complete without creating a `Payment`. |
| Offline multi-device gate scanning | **Works today; needs pass eligibility/count integration + physical drill** | RSA-PSS signed manifests (`Admissions::ManifestBuilder`), IndexedDB verification, offline queue, first-scan-wins reconciliation (`Admissions::Reconciler`), journal recovery. `Admissions::Counts` SQL filters `orders.event_id = @event.id` (`admissions/counts.rb:35`), and `Ticket#check_in!` duplicates eligibility checks instead of sharing `admission_allowed?`. |

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
- **Visibility semantics (`Event.discoverable`):** Only returns `published`, non-suspended, non-held, verified-organizer events whose `COALESCE(ends_at, starts_at) > NOW()` and that have at least one on-sale `ticket_type` with available inventory. A **sold-out** event drops out of `GET /api/v1/events` while remaining reachable by slug at `GET /api/v1/events/:slug`.
  - **Additive option for the hub (Slice 5):** support `?include_sold_out=true` when `organizer` (or `series`) is specified so the hub can display "Championship Pass — Sold Out" instead of silently hiding a sold-out pass card. Default behavior (`include_sold_out` omitted/false) stays unchanged.
- **Key response fields per event (guaranteed stable):**
  - `id`, `title`, `slug`, `short_description`, `starts_at`, `ends_at`, `doors_open_at`, `timezone`, `status`, `venue_name`, `venue_city`, `purchasable`
  - `organizer`: `{ id, business_name, slug, logo_url, verified }`
  - `ticket_types[]`: `{ id, name, description, price_cents, current_price_cents, all_in_price_cents, service_fee_cents, regular_all_in_price_cents, quantity_available, quantity_sold, quantity_remaining, on_sale, max_per_order, max_per_buyer, sales_start_at, sales_end_at, active_tier, next_tier }`
  - Additive pass metadata (Slice 2B): `is_pass: boolean`, `included_events_count: integer`, `included_events: [{ id, title, slug, starts_at, ends_at, status }]` on `ticket_types[]`, and optional `series: { id, slug, name, role }` on the event object.
- **Headers & caching:** Always sends `Vary: Accept-Language, Authorization` with `Cache-Control: private, no-store` at the browser boundary (server-side 15s in-memory caching accelerates unauthenticated reads without risking browser-side auth leakage). The hub's Rails API should cache its server-side fetch for ~5 minutes and never send user auth tokens on this call.

### 2.2 Attribution deep links (`/go/:code`)

- **Link format:** `https://hafapass.shimizu-technology.com/go/<CODE>`
- **Flow:** `DistributionRedirectPage.jsx` calls `GET /api/v1/distribution_links/:code?anonymous_id=...`, logs a `MarketplaceFunnelEvent` (`stage: :landing`), saves attribution, and redirects to `/events/<event.slug>?distribution_code=<CODE>`. Completed purchases record `AcquisitionAttribution` + `MarketplaceFunnelEvent` (`stage: :purchase`).
- **Admin management:** Partners and links are created via `/api/v1/admin/distribution_partners` and `/api/v1/admin/distribution_links`.
- **Load protection (Slice 5):** Raise `marketplace-landing/ip` and `marketplace-funnel/ip` from `60/min` to `600/min` (ENV-configurable) so a rush from the hub behind Guam carrier NAT does not 429 on `/go/:code`.

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

**Pass event schedule & capacity semantics:**
- **Dates:** A pass event's `starts_at` is set to the earliest included night's `starts_at`, and its `ends_at` is set to the latest included night's `ends_at`. When an included night is rescheduled later than the pass event's `ends_at` (e.g., a storm pushes finals from Jul 16 to Jul 30), the night update automatically extends the pass event's `ends_at` to match (without creating a pass-event `EventChange` refund window). This keeps `sales_open?`, `sales_end_at <= ends_at`, `CompletePastEventsJob`, buyer upcoming/past grouping, and `RetentionGuard` / `DataRetentionPurgeJob` anchored to the true final night.
- **Capacity (`max_capacity`):** On a **pass sales event**, `max_capacity` is the maximum total pass units across all pass ticket types on that event (e.g., 200 adult + 100 student = 300 on the Championship Pass event). On each **night event**, `max_capacity` is the maximum total physical admissions to The Jungle that night (daily sold/held tickets + pass child tickets + active pass holds targeting that night).

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

3. **`ticket_types` column addition**
   - `is_pass` (boolean, default `false`, NOT NULL) — persisted flag kept in sync when `ticket_type_included_events` are modified, so `Ticket#pass_parent?` (`parent_ticket_id.nil? && ticket_type.is_pass?`) never runs an `exists?` query in manifests, check-in, or hot paths.

4. **`ticket_type_included_events`** (pass entitlements)
   - `id`, `ticket_type_id` (FK, NOT NULL), `included_event_id` (FK → `events.id`, NOT NULL), `position` (integer, default `0`, NOT NULL), timestamps.
   - Unique index `[:ticket_type_id, :included_event_id]`.
   - Model validations:
     - `included_event.organization_id == ticket_type.event.organization_id`
     - `included_event_id != ticket_type.event_id` (no self-reference)
     - Neither the pass event nor any included event may have `event_seating_configuration` (passes are general admission only)
     - `included_event` cannot itself contain pass ticket types (no nested passes)
     - Removing an included event is refused once `ticket_type.quantity_sold > 0` or active holds exist. Adding a new night later is allowed via an explicit organizer action (`POST /api/v1/organizer/events/:event_id/ticket_types/:id/sync_pass_holders`) that acquires `ORG (FOR NO KEY UPDATE)`, then all affected events in ascending `event.id` order, then active pass `orders` in ascending `order.id` order, verifies that each newly included night's `max_capacity` (accounting for daily sold/held/seat-held inventory, existing child tickets, and active pass holds) can accommodate every missing active parent pass, updates pass effective-end coverage atomically with the entitlement change (deriving `effective_ends_at` across active included nights so sales, buyer upcoming/past classification, completion, and retention immediately reflect the newly linked night without overwriting configured `ends_at`), and only then idempotently issues missing child tickets (failing cleanly with `422` and zero partial issuance if capacity is insufficient).

5. **`tickets` column addition**
   - `parent_ticket_id` (bigint, nullable, FK → `tickets.id`, `on_delete: :restrict`).
   - Index on `parent_ticket_id`.
   - **Partial unique index:** `[:parent_ticket_id, :event_id], unique: true, where: "parent_ticket_id IS NOT NULL"` — DB-level guarantee of at most one child ticket per parent pass per night (intentionally prevents re-issuing a cancelled child ticket for the same pass and night).
   - Check constraint: `parent_ticket_id IS NULL OR order_item_id IS NULL` — DB-level guarantee that child tickets never own an `order_item`.
   - Helper methods on `Ticket`:
     - `pass_child?`: `parent_ticket_id.present?`
     - `pass_parent?`: `parent_ticket_id.nil? && ticket_type.is_pass?`
     - Parent pass tickets hold ownership, value, and refund authority; they are **not** directly scannable (`admission_allowed?` returns `false` when `pass_parent?` is true).

#### Codebase invariants caught & exact handling

Every invariant below was verified against `05a81ddb` (incorporating CodeRabbit and Opus 5.5 review findings):

| Invariant / Code Location | What breaks without explicit handling | Required fix |
|---|---|---|
| **Single admission eligibility gate** (`ticket.rb:77-80`, `ticket.rb:135-156`, `manifest_builder.rb:112-123`, `admissions_controller.rb:16`) | `Ticket#check_in!` duplicates eligibility checks instead of calling `admission_allowed?`, so direct check-in or organizer search could admit a `pass_parent` ticket or a child ticket whose parent has a pending refund. | Route `Ticket#admission_allowed?`, `Ticket#check_in!`, `Admissions::ManifestBuilder`, and `Admissions::Reconciler` through one shared eligibility check (`admission_block_reason`). Reject `pass_parent?` tickets everywhere (`ManifestBuilder`, `Admissions::Counts`, `AdmissionsController#search`, `Admissions::DoorListPdf`, and `check_in!`). |
| **`Admissions::Counts`** (`admissions/counts.rb:28-52`) | `eligible_orders` and `refund_totals` filter `WHERE o.event_id = @event.id` (missing pass child tickets' orders), `refund_tickets` ignores `t.parent_ticket_id`, and `pass_parent` tickets on a pass event would be counted as scannable. | Scope `eligible_orders` / `refund_totals` to `o.id IN (SELECT DISTINCT order_id FROM tickets WHERE event_id = @event.id)`. Check `rt.ticket_id = t.id OR (t.parent_ticket_id IS NOT NULL AND rt.ticket_id = t.parent_ticket_id)`. Exclude `pass_parent` tickets (`JOIN ticket_types tt ON tt.id = t.ticket_type_id WHERE NOT (t.parent_ticket_id IS NULL AND tt.is_pass)`). |
| **`Ticket#refund_pending?`** (`ticket.rb:82-84`) | If a buyer buys 2 Season Passes in one order and refunds 1 pass, `RefundTicket` references `parent_ticket_1`, not its 15 children. | Return true if `order.full_refund_pending?`, `pending_refund_tickets.any?`, or `parent_ticket&.pending_refund_tickets&.any?`. Preload `parent_ticket: :pending_refund_tickets` in `Admissions::ManifestBuilder`. |
| **`OrderCreator#enforce_buyer_limit!`** (`order_creator.rb:550-566`) | Counts tickets by `ticket_type`, so 1 Season Pass counts as 16 rows and immediately trips `max_per_buyer`. | Filter `Ticket` count with `.where(parent_ticket_id: nil)` so each pass counts as 1 unit. |
| **All 6 capacity check sites** (`event.rb:195`, `event.rb:436-443`, `event.rb:466`, `event.rb:665-671`, `order_creator.rb:638`, `order_lifecycle.rb:244-255`) | Only counting `event.ticket_types.sum(:quantity_sold)` and direct `inventory_holds` misses pass child tickets and active pass holds targeting a night. | Extract a shared helper (`EventCapacity` / `Event#committed_inventory_for_capacity`) used by `Event.discoverable`, `Event#remaining_capacity`, `Event#capacity_covers_committed_inventory`, `Event#publish_checklist`, `OrderCreator#enforce_event_capacity!`, and `OrderLifecycle#event_capacity_free?`. Include active non-cancelled child tickets (`tickets.where.not(parent_ticket_id: nil, status: :cancelled)`) and active holds on pass `ticket_types` linked via `ticket_type_included_events`. On pass checkout, enforce capacity on the pass event and every included night. |
| **`Ticket#release_inventory!`** (`ticket.rb:171-181`) & **`OrderLifecycle#release_locked_order!`** (`order_lifecycle.rb:319`) | Child tickets have `order_item_id: nil` and `ticket_type_id = pass_ticket_type.id`. Releasing inventory on 15 children would decrement `pass_ticket_type.quantity_sold` 15 times. | Guard `Ticket#release_inventory!`: `return if pass_child?`. Inventory is incremented and released strictly once per **parent** pass ticket. |
| **`OrdersController#cancel_ticket` & `cancel_free_ticket!`** (`orders_controller.rb:249`, `:456-479`) | (a) Paid pass child tickets have `refundable_cents == 0`, so buyers could free-cancel a single night with no refund. (b) Free `$0` pass parent tickets would cancel only the parent, leaving all 15 child tickets usable and letting a buyer loop for unlimited free passes! | (a) Reject `cancel_ticket` when `ticket.pass_child?` with `422`. (b) In `cancel_free_ticket!`, when `ticket.pass_parent?`, reject if any child was `previously_admitted?`, and otherwise atomically cancel the parent AND every child ticket (bumping `scan_credential_version` on all children, releasing inventory only on parent) before evaluating whether the order should transition to `cancelled`. |
| **Partially used pass refunds (`Commerce::FinancialReversalInventory`)** (`financial_reversal_inventory.rb:20-31`) | The parent pass is never scanned directly, so `parent.previously_admitted?` is `false` — releasing 1 pass inventory unit for resale while admitted children stay retained! Also creating 15 separate `ReconciliationException` rows for one refunded pass spams the reconciliation queue. | Treat `pass_parent` as admitted whenever `child_tickets.any?(&:previously_admitted?)` so its sold unit stays retained until physical reconciliation. Cancel all **unadmitted** future child tickets immediately (stopping future entry), retain admitted children, and create **one** grouped `ReconciliationException` (`admitted_inventory_retained`, storing `parent_ticket_id` and `admitted_child_ticket_ids` in `details`) linked to the parent's `TicketInventoryRetention`. |
| **`EventChangeResponse` & `EventChangeRefundEligibility`** (`event_change_response.rb:19-23`, `event_change_refund_eligibility.rb`) | `EventChangeResponse` requires `order.event_id == event_change.event_id`, so a pass holder receiving the standard `event_change` email gets a `422` if they click Accept or Request Refund. | Add a dedicated `pass_event_change` email template (informational only: tells pass holders Night N moved to the new date/time and their pass automatically covers it; links to their pass/order with **no** Accept/Refund actions). Explicitly exclude cross-event orders (`change.event_id != order.event_id`) in `EventChangeRefundEligibility`. |
| **Org dashboard & night stats counts** (`organizer/events_controller.rb:74`, `:279-296`) | Org home `tickets_sold` counts 16 rows per Season Pass; night `stats` includes child tickets in `total_tickets_sold` but omits them from `tickets_by_type` (because pass `ticket_type` belongs to Pass Event). | Scope org `summary` `tickets_sold` to `where(parent_ticket_id: nil)` (1 Season Pass = 1 sold). On night `stats`, report direct night `tickets_sold` and `tickets_by_type`, plus an explicit `pass_tickets` summary (`eligible`, `checked_in`, grouped by pass `ticket_type.name`, `$0` night revenue). |
| **`OrganizerSalesQuery` & `OrganizerSalesExport`** (`organizer_sales_query.rb:38,85`, `organizer_sales_export.rb:83`) | Night `orders` view filters `@event.orders`; `filters["ticket_type"]` rejects pass `ticket_type_id`; `allocated` falls into `legacy_residual` when `order_item` is nil. | In `OrganizerSalesExport`, return `$0.00` for financial columns on `pass_child` rows (label `ticket_type` as `"<Name> (Pass)"`). In `OrganizerSalesQuery`, allow filtering by linked pass `ticket_type_id`s on night events, while keeping night `orders` view scoped to direct night orders so night financial CSVs never double-count pass revenue. |
| **`TicketEmailAttachments`** (`ticket_email_attachments.rb:10`) | `MAX_ATTACHMENTS = 10`; a 15-night Season Pass exceeds the cap. | Exclude `pass_parent?` tickets from PDF attachments. For pass orders with >2 child tickets, omit per-night PDF attachments from the confirmation email and link directly to the Order/Pass page. For ≤2-night passes (Championship Pass), attach the 2 night PDFs normally. |
| **`CompletePastEventsJob` & `EventLifecycle` `:complete`** (`event_lifecycle.rb:109`, `complete_past_events_job.rb:23`) | Storm delays could cause a Pass Event to auto-complete while an included night is still `published` or `postponed`. | Auto-extend Pass Event `ends_at` when an included night moves later, AND block `:complete` on a Pass Event while any included night is `published` or `postponed` (do not block on unused `draft` nights). |
| **Retention & buyer upcoming/past classification** (`retention_guard.rb`, `data_retention_purge_job.rb`, `me/tickets_controller.rb`) | Keying a pass off its `starts_at` (Night 1) would classify an active Season Pass as "past" on Night 2, and could anchor retention earlier than Finals. | Classify passes as upcoming/past and anchor retention off the latest included night's `ends_at` (synced onto the Pass Event's `ends_at`). |

#### Locking contract extension (`docs/LOCKING.md`)

All pass operations obey `docs/LOCKING.md` (which allows skipping a rank, and forbids ever moving up a rank):

- **Core rules (fixing M1 & M2 from Opus review):**
  1. **Buyer pass checkout & issuance NEVER acquire Rank 1 (`Organization`)** unless claiming a waitlist offer (matching single-event checkout). Taking `ORG (FOR NO KEY UPDATE)` on checkout would queue every championship-rush buyer behind 3-device gate scanning and manifest downloads! Instead, pass checkout and all pass issuance paths lock **only Rank 2 (`Event` rows sorted by ascending `event.id`, `FOR NO KEY UPDATE`)** → Rank 3 (`Order`) → Rank 5 (`TicketTypes`, `PricingTiers` sorted by `id`).
     - Every path that issues pass child tickets must use this exact sorted-event prefix: Stripe `OrderLifecycle.complete!`, `CashSaleCreator`, `PaymentRecovery`, and late completion.
     - Locking the included night events `FOR NO KEY UPDATE` guarantees the child ticket `INSERT` (which takes FK `KEY SHARE` on `night_event`) never blocks behind or deadlocks with a night `FOR UPDATE` lock.
  2. **Pass refunds (`RefundCreator`) and lost disputes (`StripeWebhookProcessor`) DO NOT lock the night events.**
     - Why: `RefundCreator` (`refund_creator.rb:166,250,442`) and `StripeWebhookProcessor` (`stripe_webhook_processor.rb:352`) hold `ORG (FOR UPDATE)`, which conflicts with night checkout's `AuditLogger` FK `KEY SHARE` on `organizations`. Locking night events while holding `ORG (FOR UPDATE)` would deadlock with any night checkout or box-office cash sale!
     - Because cancelling child tickets does not mutate any night's `TicketType#quantity_sold` (and night capacity only increases when a child is cancelled), pass refunds and disputes lock **only `ORG (FOR UPDATE)` → `pass_event` → `pass_order` → `tickets` (parent + children sorted by `ticket.id`)**.
  3. **`sync_pass_holders` (organizer-only admin action, never in buyer hot path)** locks **`ORG (FOR NO KEY UPDATE)` → `[pass_event, *new_night_events].sort_by(&:id)` (`FOR NO KEY UPDATE`) → active pass `orders` sorted by `order.id` → parent `tickets` sorted by `ticket.id`**. Because it holds `ORG (FOR NO KEY UPDATE)` (not `FOR UPDATE`), night checkout's `AuditLogger` FK `KEY SHARE` remains compatible, while `Reconciler` and `ManifestBuilder` (which also take `ORG FOR NO KEY UPDATE`) serialize cleanly at Rank 1!

- **Deadlock proof across all 6 concurrent races (planned validation — must be proven before release by latch-based PostgreSQL specs in `pass_locking_spec.rb`):**
  1. *Pass Checkout / Issuance vs Night N Daily Checkout / Cash Sale:* Both skip Rank 1 and lock events (`FOR NO KEY UPDATE`) in ascending `event.id` order (Night N locks 1 event; Pass locks sorted `[pass_event, *included_events]`). Same lock order → zero cycle.
  2. *Pass Refund (`RefundCreator`) vs Night N Checkout / Cash Sale:* Refund holds `ORG (FOR UPDATE)` → `pass_event` → `pass_order` → `tickets` and **never locks `night_event`**. Night N holds `night_event` and briefly waits for `ORG KEY SHARE` on `AuditLog` insert until Refund commits. Refund never waits on Night N → zero cycle.
  3. *Pass Lost Dispute (`StripeWebhookProcessor`) vs Night N Cash Sale / Checkout:* Same proof as Race 2 — Dispute holds `ORG (FOR UPDATE)` → `pass_event` → `pass_order` → `tickets` and never locks `night_event`. Zero cycle.
  4. *Pass Refund / Dispute vs Night N Admission Sync (`Reconciler`):* Both acquire Rank 1 (`ORG`) before any event/order/ticket; Refund/Dispute never acquires Rank 0 (`Actor`). Serialized at `ORG`. Zero cycle.
  5. *Pass Order Completion (`OrderLifecycle.complete!`) vs Night N Manifest Download / Reconciler:* Completion locks sorted `[pass_event, *included_events]` (`FOR NO KEY UPDATE`), inserts child tickets (reusing its owned `night_event` lock), and writes `AuditLog` (`ORG KEY SHARE`, compatible with `Reconciler`/`ManifestBuilder`'s `ORG FOR NO KEY UPDATE`). `Reconciler` cannot lock the new `pass_order` because child tickets do not exist yet, and `ManifestBuilder` never locks `pass_event`. Zero cycle.
  6. *`sync_pass_holders` vs Night N Reconciler & Night N Checkout:* Against `Reconciler`, both start with `ORG (FOR NO KEY UPDATE)` (serialized at Rank 1). Against Night N Checkout, `sync_pass_holders` holds `ORG (FOR NO KEY UPDATE)` (compatible with Checkout's `AuditLog` `ORG KEY SHARE`) and acquires `night_event` (`FOR NO KEY UPDATE`); Checkout never acquires `pass_event` or strong `ORG`. Zero cycle.

#### Cascade rules (Refunds, Disputes, Transfers, Reschedules, Cancellations)

- **Issuance (`Passes::Issuance` called from `OrderLifecycle#issue_tickets!`):** Atomically creates 1 parent pass ticket (`event: pass_event`, `order_item: item`) and $N$ child tickets (`event: included_event`, `order_item: nil`, `parent_ticket: parent_ticket`, `ticket_type: item.ticket_type`), each with a unique `qr_code` and copied `attendee_name`/`attendee_email`/`holder_user`/`holder_email`. Works identically for Stripe, free `$0`, and `BoxOffice` cash sales.
- **Refunds & Disputes (`Commerce::RefundCreator`, `Commerce::FinancialReversalInventory`, `StripeWebhookProcessor`):**
  - Selecting a `pass_child` ticket directly in `tickets:` is rejected (`"Refund the parent pass instead of a single night"`).
  - **Unused pass** (zero child tickets `previously_admitted?`): cancels parent AND all children, bumps `scan_credential_version` on every child, releases 1 unit of pass `ticket_type.quantity_sold` (and tier).
  - **Partially used pass** (≥1 child ticket `previously_admitted?`): buyer self-serve and organizer ticket-selected refunds are refused (`"Pass has already been used on one or more nights; use an organizer custom-amount refund or contact support"`). Full-order / admin refund / lost dispute retains the parent's inventory unit (treating parent as admitted), cancels all unadmitted future child tickets, retains admitted children, and creates **one** grouped `ReconciliationException`.
- **Transfers (deferred out of Slice 2A):** `ticket_transfers` is currently OFF in `general_admission` production (`launch_capabilities.rb:12-14`). In Slice 2A-1, explicitly reject transfers on both `pass_child` and `pass_parent` tickets (`"Multi-night passes cannot be transferred"`). Full whole-pass transfer cascade (before first admission, rotating all child credentials under `ORG → sorted events → order → sorted tickets → transfer`) is deferred to a post-launch follow-up if Leon later enables `ticket_transfers` in production — avoiding premature churn in `Ticket#with_entry_lock` while sibling lock-order branches are in flight.
- **Storm Delays / Reschedules (`EventChange`):**
  - Rescheduling Night N updates `night_n.starts_at`/`ends_at`, auto-extends the Pass Event's `ends_at` if Night N moved past it, refreshes Night N Wallet passes (`Wallet::PassSync.event_changed`), and sends the informational `pass_event_change` email (no Accept/Refund actions) to holders of active (`issued`) child tickets on Night N (deduped by email against direct night buyers, idempotency key `event-change/#{change.id}/pass-holder/#{email_sha256_32}`).
- **Single-Night Cancellation (`EventLifecycle` `:cancel` on Night N):**
  - Direct orders on Night N receive automatic `EventCancellationRefunds` unchanged.
  - Child tickets on Night N are cancelled (`cancellation_reason: "event_cancelled"`) and pass holders receive the informational `pass_event_change` notice; the remaining nights stay active. Pass-holder partial credit policy is confirmed with FDMSAA (Section 7).
- **Buyer UX (`OrderConfirmationPage.jsx`, `MyTicketsPage.jsx`, `TicketPage.jsx`):**
  - `OrderPresenter` and `Api::V1::Me::TicketsController` nest `child_tickets` (ordered by `event.starts_at ASC`) under each `pass_parent` ticket instead of flattening 16 cards.
  - The Pass Card highlights **"Tonight's Ticket"** (matching today's Guam date or next upcoming published night) with one tap to open its QR code, Apple/Google Wallet pass, or PDF, plus an expandable list of all included nights with status pills (`Upcoming`, `Checked in`, `Postponed`, `Cancelled`).

---

### 3.2 Gap 2: Team Registration

**What works today at `05a81ddb`:**
- Early/late pricing (`$420.16` early / `$520.16` late) via `TicketType` (`max_per_order: 1`) + time-based `PricingTier`s (`PricingTiersCRUD.jsx`).
- Custom registration questions (`short_text`, `long_text`, `selection`, `checkbox`, `required`, `options`, `position`, `active`) and versioned `EventWaiver`s in `OrderCreator`, `CheckoutPage.jsx`, and `SalesToolsPage.jsx`.

**What we will build (Slice 3):**
1. **Promote `registration_questions` and `event_waivers` into core `general_admission` across all 5 gate sites (keeping `catalog_items`/donations, `promoters`, and `communication_campaigns` behind `advanced_sales_tools`):**
   - `LaunchCapabilities.event_supported?` (`launch_capabilities.rb:54-60`, which also feeds `Event#publish_checklist` at `event.rb:452`)
   - `LaunchCapabilities.required_for` organizer controllers (`launch_capabilities.rb:75-77`)
   - `LaunchCapabilities.required_for` order-creation params (`launch_capabilities.rb:86-89`)
   - `Commerce::OrderCreator#validate_launch_scope!` (`order_creator.rb:304-306`)
   - Frontend navigation & page gating (`eventWorkspaceNavigation.js` and `SalesToolsPage.jsx`)
   - Also verify `BoxOffice` behavior when an event has required registration questions (Team Registration is online self-serve; ensure staff box office either surfaces a clear error or skips/accepts registration answers cleanly without a 500).
2. **Organizer question management UX (`SalesToolsPage.jsx`):**
   - Wire existing `PATCH /api/v1/organizer/events/:event_id/registration_questions/:id` so organizers can edit prompt/required/options, reorder (`position` up/down), and deactivate/reactivate questions without deleting questions that already have responses.
   - Surface Registration Questions & Waivers directly in the Event Workspace navigation without requiring `advanced_sales_tools`.
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
     - Tickets issued (direct paid / free / pass child admissions), checked-in count, gross ticket sales, discounts, buyer refunds, buyer-paid HåfaPass fees, organizer-absorbed fees, processing fees (platform-covered vs organizer-paid), organizer proceeds, door cash retained, net platform payable, paid out, remaining owed, and settlement/payout status (`awaiting_completion`, `not_finalized`, `ready`, `paid`).
  2. **Subtotals by group:**
     - **Admissions (Daily + Season Pass + Championship Pass)**
     - **Team Registration**
     - **All Tournament Events Combined**
  3. **Channel breakdown:** Online (Stripe) vs Door Cash (`door_cash`) vs Free/Comp QR (ticket & check-in counts).
  4. **Ticket-type breakdown across the tournament:** Adult Daily, Student Daily, Free Alumni/Kids/Seniors, Adult Season Pass, Student Season Pass, Adult Championship Pass, Student Championship Pass, Team Registration (Early vs Late tier).
  5. **16% Revenue-Share Worksheet (configurable per `EventSeries` until FDMSAA confirms direction & base):**
     - Inputs stored on `event_series` (editable by org finance/admin, audited):
       - `revenue_share_bps`: default `1600` (16.00%)
       - `revenue_share_base` (every option starts from `Settlements::Calculator.call(event)` attributes; note that `organizer_proceeds_cents` already has `refunded_proceeds` subtracted in `calculator.rb:27,57`, so **no second refund subtraction** is performed):
         - `admissions_net_proceeds` (default): sum of `Settlements::Calculator` `organizer_proceeds_cents` across admissions events (`regular_night`, `championship_night`, `pass_sale`).
         - `admissions_gross`: sum of `Settlements::Calculator` `gross_cents - discount_cents` (pre-refund net sales face value) across admissions events.
         - `admissions_net_after_processing`: sum of `Settlements::Calculator` `(organizer_proceeds_cents - processing_fee_cents)` (series-netted, floored at 0) across admissions events.
         - `all_net_proceeds`: sum of `Settlements::Calculator` `organizer_proceeds_cents` across all events in the series (admissions + `registration` + `other`).
       - `revenue_share_includes_door_cash`: `true` (default). When `true`, `door_cash` proceeds remain in the base, and `door_cash_retained_cents` (derived from `Settlements::Calculator` cash custody items, matching `OrganizationFinanceSummary#door_cash_retained`) is shown separately next to the net check payable so cash already held by the organizer is never double-paid. When `false`, `door_cash_retained_cents` is excluded from the base.
       - `revenue_share_label` (e.g. `"Host Class (CO2017) — 16%"`) & `primary_share_label` (e.g. `"FDAA / FDMSAA — 84%"`)
     - Math: `Commerce::MoneyAllocator.call(base_cents, [revenue_share_bps, 10_000 - revenue_share_bps])` — guarantees `share_cents + remainder_cents == base_cents` with zero penny drift.
     - Displays both the 16% share AND the 84% remainder clearly so whichever direction FDMSAA confirms, no code rewrite is needed.
  6. **Payout closeout note (verified DB constraint):** `payouts` enforces `idx_payouts_unique_provider_id` (`UNIQUE(provider, provider_payout_id) WHERE provider_payout_id IS NOT NULL`, `schema.rb:1652`). Because payouts remain per-event, if Shimizu writes one physical check (e.g., Check #1042) settling multiple finalized tournament events, record each event payout's `provider_payout_id` as `CHK-1042-E<event_id>` and reference Check #1042 in `evidence.reference` and `evidence.reason`. For the 30-day post-finals chargeback holdback, use existing `BalanceAdjustment` (`kind: "reserve_hold"` negative amount, then `"reserve_release"` 30 days after finals, followed by re-finalizing the statement and recording the final check payout).

---

### 3.4 Gap 4: Load Prep for Championship Rush (Target: by Jun 10)

#### Bottlenecks verified in `05a81ddb`

1. **`EventsController#index` N+1 queries and zero caching (`events_controller.rb:249-314`):**
   - Per event, `event_json` runs separate uncached queries for `active_tickets.count`, `catalog_items.available`, `registration_questions.published`, `event_waivers.published`, `active_tickets.limit(10).pluck(:attendee_name)`, `event.ticket_types.includes(:pricing_tiers)` re-query (line 314), and `remaining_capacity` / `has_available_inventory?`. For 20 tournament events (`?organizer=fdaa`), one request runs 100+ SQL queries.
2. **`Rack::Attack` shared-IP limits + Postgres row contention (`rack_attack.rb:8-275`, `postgres_throttle_store.rb:9-26`):**
   - Guam cellular carriers (Docomo, GTA, IT&E) use carrier-grade NAT and The Jungle puts hundreds of fans on one Wi-Fi egress IP. Current limits will 429 legitimate fans during a 200-pass championship rush:
     - `req/ip`: `300 / 5 min` (60/min total across all fans on one IP)
     - `orders/ip`: `30 / 1 min`
     - `marketplace-landing/ip` (`/go/:code` from Hub): `60 / 1 min`
     - `marketplace-funnel/ip`: `60 / 1 min`
     - `users/ip`: `20 / 1 min`
     - `payment-resume/ip`: `20 / 1 min`
   - Furthermore, `PostgresThrottleStore` executes an `INSERT ... ON CONFLICT DO UPDATE` against one `runtime_throttle_buckets` row per IP on every request (including cached reads), creating hot-row write contention under a shared-NAT rush.
3. **Per-IP hold cap (`OrderCreator::DEFAULT_MAX_HELD_TICKETS_PER_IP = 60`):**
   - 30 buyers behind one NAT holding 2 championship passes hits 60 and blocks buyer #31.
4. **Production runtime (`render.yaml`):**
   - Single `0.5c-512mb` web service with embedded Solid Queue (3 web threads, 1 job thread, `DB_POOL=10`) and Neon auto-suspend/low min CU.

#### Concrete fixes (Slice 5 — code & staging k6; infra apply is Leon-gated in Section 7)

1. **N+1 elimination + server-only short-TTL cache on `GET /api/v1/events` & `GET /api/v1/events/:slug`:**
   - Preload `active_ticket_counts` in one `Ticket.where(event_id: ids).where.not(status: :cancelled).group(:event_id).count` query, preload `catalog_items`, `registration_questions`, `event_waivers`, reuse already-preloaded `event.ticket_types` (removing line 314's `.includes(:pricing_tiers).order(...)` re-query), batch capacity calculations, and skip `attendees_preview` when `show_attendees` is false.
   - Add bounded `ActiveSupport::Cache::MemoryStore` (`size: 32.megabytes`) in production (safe across Puma workers because TTL is 15s and checkout always reads live locked DB rows).
   - Cache **in server memory only** for unauthenticated (`@current_user.nil?`) requests, excluding `params[:preview] == "true"` and `params[:live_money_proof] == "true"` on `show`, with distinct keys:
     - List (`index`): `["public_events/v1/index", request_locale, SiteSetting.instance.updated_at.to_i, normalized_all_query_params_including_page_and_per_page]`
     - Detail (`show`): `["public_events/v1/show", params[:slug].to_s, request_locale, SiteSetting.instance.updated_at.to_i, normalized_query_params]` (using raw requested `params[:slug]` so `redirected_from` stays accurate)
   - Keep HTTP headers safe against browser auth-leakage (`Cache-Control: private, no-store`, `Vary: Accept-Language, Authorization`) so signed-in axios requests (`Authorization: Bearer`) never get a stale signed-out browser cache hit and buyers see live remaining inventory immediately after purchasing.
   - Add optional `?include_sold_out=true` when `organizer` or `series` filter is present (for the hub's "Sold Out" pass badge).
2. **Re-key / tune `Rack::Attack` limits for Guam CGNAT & venue Wi-Fi:**
   - Make every public IP ceiling ENV-tunable with CGNAT-safe defaults (high enough that 150 concurrent fans behind one carrier NAT × ~5 requests each = ~750–1,000 requests in 1 minute do not 429), while keeping strict per-email / per-user / per-credential throttles intact:
     - `RACK_ATTACK_REQ_PER_IP_5M`: default `3000` (was `300`; 600/min/IP)
     - `RACK_ATTACK_ORDERS_PER_IP_1M`: default `200` (was `30`; per-email stays `5/min`, plus `OrderCreator` enforces 1 active unpaid checkout per email + `max_per_buyer` on passes!)
     - `RACK_ATTACK_MARKETPLACE_LANDING_PER_IP_1M`: default `600` (was `60` — protects `/go/:code` hub rushes)
     - `RACK_ATTACK_MARKETPLACE_FUNNEL_PER_IP_1M`: default `600` (was `60`)
     - `RACK_ATTACK_USERS_SYNC_PER_IP_1M`: default `120` (was `20`)
     - `RACK_ATTACK_PAYMENT_RESUME_PER_IP_1M`: default `120` (was `20`)
   - Measure `PostgresThrottleStore` hot-row contention during the shared-NAT k6 staging test; if a single shared IP causes lock waits on `runtime_throttle_buckets`, shard hot read throttles (`req/ip`) into short-window in-process memory or per-worker counters while keeping checkout/auth/tax throttles durable in PostgreSQL.
   - Set `HAFAPASS_MAX_HELD_TICKETS_PER_IP=250` in Render for June–July (Leon-gated; already ENV-configurable in `order_creator.rb:582`).
3. **k6 championship-rush load test (`load_tests/fd_championship_rush.js`):**
   - Target staging (isolated `[LOAD TEST]` fixture with a 2-night Championship Pass capped at 200 units + 150–200 concurrent VUs).
   - Run **two** scenarios:
     1. **Free-pass saturation rush (150–200 VUs):** `GET /api/v1/events?organizer=<slug>` → `GET /api/v1/distribution_links/:code` → `GET /api/v1/events/:slug` → `POST /api/v1/orders` (free test pass fixture) — proves 0 oversell (exact 200 parent passes + 400 child tickets), clean `422` sold-out responses for remaining VUs, `p(95) <= 1500ms` checkout, `p(95) <= 300ms` cached `GET /events`, and 0 unexpected 5xx/429s under both distributed-IP and shared-NAT runs.
     2. **Paid hold-creation & expiry rehearsal (bounded staging Stripe test-mode / simulate run, e.g. 30–50 concurrent buyers):** exercises `InventoryHold` creation, Stripe `PaymentIntent` creation latency/timeouts, `CheckoutAttempt` recovery, and Solid Queue hold expiry so the actual paid rush path is measured too (not just free checkout!).
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
     - Revoked/refunded pass child ticket → rejected on sync and marked invalid in fresh manifest.

---

## 4. Risks & Mitigations

| Risk | Likelihood / Impact | Mitigation |
|---|---|---|
| **Cross-event lock-order deadlock** between pass checkout/refund/dispute/sync and night checkout/scanning | Medium / High | Pass checkout/issuance skips `ORG` and locks sorted `events` (`FOR NO KEY UPDATE`); pass refunds/disputes hold `ORG (FOR UPDATE)` and never lock night events; `sync_pass_holders` uses `ORG (FOR NO KEY UPDATE) → sorted events → sorted orders`. Must be proven before release by 6 latch-based PostgreSQL concurrency specs (`pass_locking_spec.rb`). |
| **Free-pass cancel, partial-use refund, or buyer-limit loophole on child tickets** | Medium / High | DB check constraint (`parent_ticket_id IS NULL OR order_item_id IS NULL`), `is_pass` flag, `release_inventory!` no-op on children, `enforce_buyer_limit!` filters `parent_ticket_id: nil`, `cancel_free_ticket!` cascades to children (or blocks if admitted), `FinancialReversalInventory` treats parent as admitted if any child was admitted (1 grouped `ReconciliationException`), unified `admission_allowed?` / `check_in!` gate. |
| **Storm mass-reschedule sends 6+ emails to every Season Pass holder** | Medium / Medium | Document storm runbook: postpone affected nights first, then batch schedule updates inside `EventChange::NOTICE_COALESCE_WINDOW` (10 min per night); use informational `pass_event_change` template (no broken Accept/Refund CTA). |
| **Championship rush throttled on Guam carrier NAT / Jungle Wi-Fi or Postgres throttle row contention** | High / High | Raise ENV-configurable IP ceilings (`req/ip` 3000/5m, `orders/ip` 200/m, `/go/:code` 600/m, `HAFAPASS_MAX_HELD_TICKETS_PER_IP=250`), eliminate `EventsController` N+1s + 15s server-memory cache (with safe browser headers), upgrade Render + Neon for June–July, prove with free + paid k6 staging runs including shared-NAT contention. |
| **Stripe holds/freezes funds partway through 15+ nights** | Low–Med / High | Accepted by Leon (Nov 22); hold final payout ~30 days post-finals via `reserve_hold` adjustment; door cash (`BoxOffice`) works offline from Stripe; zero-code daily-ticket fallback stays intact. |
| **Merge conflicts with local sibling worktrees** (`lock-order`, `admissions-recovery`, `refund-reconciliation`, `commerce-recovery`) | Medium / Medium | Defer whole-pass transfer cascade (avoiding `Ticket#with_entry_lock` churn); isolate pass logic in dedicated `Passes::*` services; merge `EventsController` slices sequentially (Slice 1 → 2B → 5). |
| **Multi-night passes slip past Jun 1** | Low / Medium | Zero-code fallback from plan §5: sell daily + championship tickets on HåfaPass and sell physical season passes at the door. |

---

## 5. Test & QA Plan

Every implementation slice follows `shimizu-pr-workflow` and `application-qa`:

1. **Automated backend tests (RSpec):**
   - Unit & request specs for `EventSeries`, `bulk_clone`, pass issuance (Stripe, free, box office cash, `PaymentRecovery`, `sync_pass_holders` capacity checks), unified `admission_allowed?` / `Ticket#check_in!` / `Admissions::ManifestBuilder` / `Admissions::Counts` / `Admissions::Reconciler` / `Admissions::DoorListPdf` / `AdmissionsController#search` with pass tickets, `enforce_buyer_limit!` with passes, all 6 capacity sites, pass refunds (unused, partially used with 1 grouped `ReconciliationException`, partial-order pending refund, full-order/admin, lost dispute, free-pass cancel cascade), child/parent transfer rejection, `pass_event_change` notifications & `EventChangeRefundEligibility` exclusion, single-night cancellation vs reschedule + Pass Event `ends_at` auto-extension, `CompletePastEventsJob` pass guard (ignoring draft nights), retention/upcoming anchoring to last included night, registration question edit/reorder + expanded CSV export, tournament series report + 16% / 84% `MoneyAllocator` cent-exactness, `Rack::Attack` ENV ceilings, and `EventsController` N+1 + server-cache isolation (authenticated vs unauthenticated, `slug` redirects, `preview`/`live_money_proof` bypass, locale `Vary`).
   - **Latch-based PostgreSQL concurrency specs** (`pass_locking_spec.rb`, modeling `ticket_locking_spec.rb`) proving zero deadlocks across all 6 concurrent races with short `lock_timeout`.
2. **Automated frontend tests (Vitest + ESLint + Impeccable):**
   - Pass configuration UI, `OrderConfirmationPage` & `MyTicketsPage` Pass Card ("Tonight's Ticket" + night schedule list + upcoming/past classification), `SalesToolsPage` registration question edit/reorder/toggle, `AttendeesPage` expanded registration export, Tournament Series Report & CSV download UI.
   - Run `IMPECCABLE_NO_TELEMETRY=1 npx impeccable@4.6.0 detect --json <changed UI paths>` on every frontend slice.
3. **Real browser QA (local & staging):**
   - End-to-end flows on desktop + mobile viewports (390px): buy a 3-night test pass → verify grouped Pass Card → scan Night 1 (admitted), re-scan Night 1 (conflict), scan Night 2 (admitted) → verify direct check-in rejects parent pass → reschedule Night 3 past original end → verify Pass Event `ends_at` extended & informational email delivery record → refund unused pass → verify all child tickets cancelled in manifest → test team registration checkout + expanded CSV export → verify tournament series report totals match per-event settlements to the exact cent.
4. **Staging load test (k6):**
   - Run `load_tests/fd_championship_rush.js` (both 150+ VU free-pass saturation + bounded paid PaymentIntent hold/expiry rehearsal, distributed-IP and shared-NAT) against isolated staging fixture before Jun 10; archive summary JSON and memory/DB/throttle telemetry.
5. **Physical 3-device offline gate drill (Leon + staff, by Jun 1):**
   - Execute `docs/EVENT_DAY_OPERATIONS.md` drill on 3 real phones at The Jungle covering daily, free, season pass, and championship pass tickets.

---

## 6. PR-Sized Implementation Slices & Schedule

All code slices are built and verified locally + on staging; production activation happens only when Leon is ready (Section 7). Slices touching `EventsController` (1, 2B, 5) merge sequentially.

| Slice | PR Scope | Est. Days | Review Gates | Acceptance Checks | Target Date |
|---|---|---|---|---|---|
| **Slice 0 (this PR)** | `docs/FD_TOURNEY_2027_READINESS.md` (verified state, design, hub contract, PR plan, activation runbook) | 0.5 | CodeRabbit + **cross-family review (Opus 5.5)** | Design approved; zero unresolved technical/locking objections. | Nov 22–24, 2026 |
| **Slice 1** | **Event Series + Bulk Night Clone:** `event_series` & `event_series_memberships` migrations/models/organizer CRUD, `clone_event` bugfix (`venue_id`/`fee_policy`/`buyer_fee_percent`/`transfers_enabled`), `POST .../bulk_clone`, public `GET /api/v1/events?series=<slug>` filter, organizer Series UI. | 1.5–2 | CodeRabbit + CI | Clone 17 nights in one call into a series; `?series=` & `?organizer=` work; zero regression in `EventsController`. | Dec 2026 – Feb 2027 (can start immediately) |
| **Slice 3** | **Team Registration Polish:** Promote `registration_questions` + `event_waivers` out of `advanced_sales_tools` into GA across all 5 gate sites (keeping donations/catalog gated), add edit/reorder/toggle UI in `SalesToolsPage.jsx`, add `expand_questions=true` per-question CSV export + clean scalar formatting in `OrganizerSalesExport` & `AttendeesPage.jsx`. | 1–2 | CodeRabbit + Impeccable + browser QA | Team registration works with `HAFAPASS_LAUNCH_SCOPE=general_admission` (no donations exposed); early/late `PricingTier` switches on schedule; expanded CSV has one clean column per question. | **By Apr 15, 2027** (can start in parallel with Slice 1) |
| **Slice 2A-1** | **Multi-Night Passes — Schema, Issuance, Capacity, Admissions & Lock Order:** `ticket_types.is_pass`, `ticket_type_included_events`, `tickets.parent_ticket_id` (partial unique index + check constraint), `Passes::Issuance` (Stripe, free, cash, `PaymentRecovery`, `sync_pass_holders` with capacity check), all 6 capacity sites, `enforce_buyer_limit!` fix, unified `admission_allowed?` / `Ticket#check_in!` / `ManifestBuilder` / `Counts` / `AdmissionsController#search` / `DoorListPdf`, child-cancel & transfer rejections, org/night stats counts, `docs/LOCKING.md` update + `pass_locking_spec.rb` (Races 1, 5, 6). | 2.5–3 | CodeRabbit + **mandatory cross-family review (Sol/Opus)** (money, admissions, locking) | All RSpec + concurrency specs pass; zero oversell; scanner manifest, direct check-in, door list PDF & offline sync work cleanly; `max_per_buyer` counts passes accurately. | Mar 2027 |
| **Slice 2A-2** | **Multi-Night Passes — Refund/Dispute Cascades, Storm Reschedules & Lifecycle:** `RefundCreator` + `FinancialReversalInventory` (partially used parent retention + 1 grouped `ReconciliationException`), `StripeWebhookProcessor` lost-dispute cascade, `cancel_free_ticket!` free-pass cascade, `Ticket#refund_pending?` parent check, `pass_event_change` email template + `EventChangeRefundEligibility` exclusion, single-night cancel handling, Pass Event `ends_at` auto-extension + `CompletePastEventsJob` guard (ignoring drafts), retention anchoring, `TicketEmailAttachments` cap handling, `pass_locking_spec.rb` (Races 2, 3, 4). | 2–2.5 | CodeRabbit + **mandatory cross-family review (Sol/Opus)** (money, refunds, disputes, locking) | All RSpec + refund/dispute concurrency specs pass with 0 cent drift and zero deadlocks; storm reschedule notifies pass holders with no broken refund CTA. | Apr 2027 |
| **Slice 2B** | **Multi-Night Passes — Organizer & Buyer UI:** Organizer pass-entitlement picker on `TicketTypeCRUD` + `sync_pass_holders` UI, additive `is_pass`/`included_events` metadata on public `EventsController`, buyer Pass Card ("Tonight's Ticket" + night schedule + last-night upcoming/past classification) in `OrderConfirmationPage`, `MyTicketsPage`, `TicketPage`, and `OrganizerSalesExport` pass-child `$0` display. | 2–3 | CodeRabbit + Impeccable + browser QA (desktop + 390px mobile) | Buyer buys Season Pass & 2-Night Championship Pass in browser QA, opens Tonight's QR, sees rescheduled night update, and organizer scans + exports door list cleanly. | By May 15, 2027 (**passes on sale by Jun 1**) |
| **Slice 4** | **Tournament-Wide Sales & 16% Revenue-Share Report:** `EventSeriesReport` service (backed by `Settlements::Calculator`), JSON + CSV endpoints, configurable 16%/84% share worksheet (`MoneyAllocator`), series closeout/payout checklist, Organizer Series Report UI. | 1.5–2 | CodeRabbit + **cross-family review** (financial reporting) + browser QA | Series totals reconcile to the exact cent with per-event `Settlements::Calculator` and `OrganizationFinanceSummary`; 16% + 84% sum exactly to base; CSV downloads cleanly with formula injection protection (`SpreadsheetExport`). | **By May 1, 2027** |
| **Slice 5** | **Load Prep, Caching & k6 Championship Rush:** Eliminate all `EventsController#index` N+1s, 15s server-only unauthenticated response cache (`Vary: Accept-Language, Authorization`, safe browser headers) + `?include_sold_out=true`, ENV-configurable CGNAT-safe `Rack::Attack` defaults, `load_tests/fd_championship_rush.js` (free saturation + paid hold/expiry scenarios), staging k6 run at 150+ VUs, and `render.tournament.yaml` reference template (not auto-applied). | 2–3 | CodeRabbit + **cross-family review** (throttling/caching security) + staging k6 evidence | `EventsController#index` SQL count drops from 100+ to <15; signed-in state never leaks via cache; staging k6 150+ VU run hits 0 oversell, 0 unexpected 429/5xx, p95 checkout ≤ 1500ms. | **By Jun 10, 2027** |

---

## 7. Production Activation Checklist (Leon-Gated — Run When Ready)

None of these steps are executed by agents. Run them only when Leon decides to activate production.

### Phase A: Baseline production & Mar 6, 2027 fundraiser pilot (zero code required)

1. **Keep HåfaPass unpaused:** Confirm `hafapass-api` (`srv-d6bsuq0gjchc73fu35hg`) stays active on Render ($7/mo) and `https://hafapass.shimizu-technology.com` + `/api/v1/config` report `production` and `live` mode (verify approvals in `docs/PRODUCTION_CUTOVER.md` §8: Policy Register, Resend production, Stripe live). Confirm which Render env var group (`hafapass-staging-runtime` in `render.yaml`) is attached to the live service before making changes.
2. **Create two production organizations** (Admin → Organizations):
   - **`CO2017`** (`slug: "co2017"`, e.g. `"FD Class of 2017"`): for class fundraisers; payout check payee = Class of 2017 Bank of Guam account.
   - **`FDAA`** (`slug: "fdaa"`, e.g. `"FD Alumni Association / FDMSAA"`): for 2027 tournament daily tickets, season/championship passes, and team registration; payout check payee per FDMSAA payout note.
3. **Verify both organizations & payout readiness:**
   - Approve organizer verification for both `CO2017` and `FDAA`.
   - Configure each org's `check` `ConnectedAccount` (payee name, mailing/delivery instructions), submit and approve Gate B payment readiness review, and enter W-9 / tax-exempt info (`OrganizerTaxInformation`) so payouts are not subject to 24% backup withholding.
   - Confirm `ADMIN_EMAILS`, `ADMISSION_MANIFEST_PRIVATE_KEY_PEM`, and `ACTIVE_RECORD_ENCRYPTION_*` are backed up securely.
4. **Create `fd-alumni-hub` distribution partner (Admin → Marketplace → Distribution Partners):**
   - Partner slug: `fd-alumni-hub` (`kind: partner` / `media`).
   - Create `/go/:code` `DistributionLink`s for Phase A fundraiser events (such as the Mar 6 Bryan Ho 5K/beer mile) once those events exist, and share codes with the **FD Alumni Hub 2027** lead. Tournament team-registration, pass-event, and night links are created in Phases B1 and B2 after those events are created.
5. **Run the Mar 6, 2027 Bryan Ho 5K/beer mile pilot under `CO2017`:**
   - Publish single-night tickets (~Feb 1).
   - Verify end-to-end live path: online Stripe charge → QR scan at check-in → event completion → statement finalization → check payout into the class's Bank of Guam account → admin payout confirmation with bank/check reference.

### Phase B1: Team Registration launch (by Apr 15, after Slices 1 & 3 deploy)

1. **Confirm FDMSAA registration & payout terms (through Vince / Jeramiah via Leon):**
   - Written one-page payout note: payee name, 5% + $1 buyer-paid fee, refund/storm policy, and ~30-day post-finals chargeback holdback.
   - Team registration fee bearer (`$420.16` early / `$520.16` late all-in or buyer-pays fees), early/late cutoff date, and required registration fields/waiver text.
2. **Create the 2027 Tournament Series & Team Registration event under `FDAA`:**
   - Create `EventSeries` (`slug: "fd-2027-alumni-basketball"`).
   - Create the Team Registration event (`role: registration`) with early/late `PricingTier`s, `max_per_order: 1`, registration questions, and waiver.
   - Create a `/go/:code` `DistributionLink` for Team Registration, share with the Hub lead, and open registration by **Apr 15**.

### Phase B2: Tournament Nights & Multi-Night Passes launch (by Jun 1, after Slices 2A-1, 2A-2, 2B & 4 deploy)

1. **Confirm remaining FDMSAA tournament details:**
   - Exact 2027 dates (tentative Jun 25 – Jul 16, storm buffer to late July).
   - 16% revenue-share direction and base (host class gets 16% vs FDAA keeps 16%; base option and door-cash inclusion) — save on the `EventSeries`.
   - 2027 Championship Pass cap (200 adult?) and free-group QR rules (alumni, kids, seniors, FD students).
   - Single-night cancellation policy for pass holders (if a regular night is cancelled outright instead of rescheduled, whether any discretionary partial credit applies).
2. **Set up nights & passes under the `FDAA` series:**
   - Bulk-clone the 15 regular nights (`role: regular_night`) and 2 championship nights (`role: championship_night`) with Adult, Student, and Free $0 ticket types and venue `FD Phoenix Center ("The Jungle")`.
   - Create the Season Pass event (linked to the 15 regular nights only) and Championship Pass event (linked to the 2 championship nights, capped per FDMSAA) with `max_per_buyer` configured to prevent scalping.
   - Create `/go/:code` `DistributionLink`s under the `fd-alumni-hub` partner for the Season Pass event, Championship Pass event, and daily/championship nights, and share the codes with the **FD Alumni Hub 2027** lead.
   - Run the 3-device offline gate drill on real phones at The Jungle.
   - Put Season Passes on sale by **Jun 1**; release Championship Passes ~2 weeks before finals (consider releasing in waves if demand spikes).

### Phase C: June–July load upgrade & August scale-down (by Jun 10 / Aug closeout)

1. **Before Championship Pass release (by Jun 10, Leon-gated):**
   - Verify staging k6 150+ VU run (free saturation + paid hold/expiry) passed on the exact release commit.
   - Upgrade Render `hafapass-api` to **Standard (`2 CPU / 2 GB`)**, switch `HAFAPASS_RUNTIME=solid_queue`, set `WEB_CONCURRENCY=2`, `RAILS_MAX_THREADS=5`, `DB_POOL=15`, `HAFAPASS_MAX_HELD_TICKETS_PER_IP=250`.
   - Start 1 dedicated Render Background Worker (`bundle exec bin/jobs`, `HAFAPASS_RUNTIME=solid_queue`, `0.5c-512mb`, `DB_POOL=10`, identical secrets/encryption keys/DB URLs). Drain embedded queue cleanly during cutover per `docs/SINGLE_SERVICE_RUNTIME.md`.
   - Raise Neon minimum compute (no scale-to-zero) for June–July.
   - Verify `/api/v1/readiness` confirms live worker/scheduler heartbeats and zero overdue jobs.
2. **Closeout (late July – August):**
   - Complete all nights, finalize statements, place 30-day chargeback `reserve_hold` balance adjustment on final proceeds, finalize updated statements, export final Tournament Series Report + 16% worksheet, write initial checks, and record/reconcile those payouts (`CHK-<num>-E<event_id>`).
   - 30 days post-finals: post `reserve_release` balance adjustment, finalize new statement versions, write the final check for the released reserve amount, record and reconcile those final payouts (`CHK-<num2>-E<event_id>`), finalize post-payout statements, and archive closed events.
   - Scale Render back down to single `0.5c-512mb` `HAFAPASS_RUNTIME=embedded` and lower Neon minimum compute.
