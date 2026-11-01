# Production audit 2026-11-01 — verified implementation plan

Companion to `production-audit-2026-11-01.md`. Every item below was re-verified against main `c45bacda` by a second review pass, with file:line evidence. Specs are implementation guidance. Re-check the code before changing it; line numbers drift.

## Global rules for every slice

- **Never change `hafapass_api/config/policies.yml`, PolicyRegistry templates or material terms.** Changing them voids production policy approval, and checkout returns 503 until an admin re-approves. If a fix seems to need policy text, stop and report it.
- No competitor names. No Hawaiian words ("aloha"). Don't invent Chamorro. Copy follows `docs/COPY_GLOSSARY.md` (sentence case).
- Keep money in integer cents. Keep append-only/audit patterns (`AuditLogger`, `with_audit_transaction`) for privileged actions.
- Match surrounding code style and comment density. Add focused specs and tests for every behavior change.
- After changing `hafapass_frontend/src/locales/en.json`, keep `en.metadata.json` in step the way existing keys do. Check `package.json` for a non-network translate/metadata script; do not call paid translation APIs.

## Lead decisions (already made; don't relitigate)

- **Event-change refunds.** Self-serve refunds are offered only when:
  - the change is `postponed`, or a `rescheduled` change where `starts_at` actually changed;
  - the order was created before `change.occurred_at`;
  - the ticket is still controlled by the order (not transferred away);
  - a published event's start time hasn't passed yet. Postponed with no new date has no deadline. Completed, archived or draft events are closed.

  Changes to `ends_at` or `doors_open_at` still notify buyers, with no self-serve refund. `cancelled` keeps its current automatic refund. Venue changes create a `venue_changed` change: notify buyers, no self-serve refund (the policy says "contact us").
- **No "notify me" email capture.** It would need policy text. The empty Home uses install-to-home-screen plus "find my tickets".
- **Product analytics, automatic 24 h holder reminders, backend image thumbnails/CDN:** deferred, reported to Leon as decisions.
- **Postgres `statement_timeout`:** set at the Neon role level (external). Do not use `database.yml` `variables:` (Neon pooler transaction mode).
- **Don't rename** the `hafapass_staging` DB, env group or bucket. Document instead.

---

## Slice A — Refunds, event changes, buyer emails (backend + OrderConfirmation UI)
Branch `fix/refunds-event-changes`.

1. **Refund eligibility (R3).**
   - New `app/services/event_change_refund_eligibility.rb`: `call(order:, change:, at: Time.current)` → `eligible`, `reason`, `deadline_at`, `tickets`. Rules per the lead decision above.
   - Use it in `orders_controller#event_change_response` (~l.323), in the `cancel_ticket` paid postponed branch (~l.248) against the latest `postponed` change, and in `RefundReconciliationActions#execute_buyer_request!`.
   - Return 422 with a clear message when not eligible. Accepting a change stays available to pre-change orders.
   - Add `refund_eligible` and `refund_deadline_at` to `OrderPresenter#latest_event_change_json`. `OrderConfirmationPage.jsx` shows the refund button only when `refund_eligible`, and shows the deadline in the event's timezone.
   - Specs: `spec/requests/api/v1/order_access_spec.rb` (bought after the change, after start, postponed, resumed then past start, cancelled, doors-only change), `spec/services/order_presenter_spec.rb`, `spec/requests/api/v1/refund_reconciliation_spec.rb`, `OrderConfirmationPage.test.jsx`.
2. **Transferred tickets (R4).**
   - Select tickets with `!ticket.transferred_away_from?(order)` (`ticket.rb:96`) before both `RefundCreator` and `cancel_free_ticket!` (the free path currently raises after the paid refund has gone through).
   - Same filter in `refund_reconciliation_actions.rb` (~l.140).
   - Defence in depth in `RefundCreator#lock_selected_tickets!`: reject transferred-away tickets unless the reason is an event cancellation (`event_cancel*`).
   - Note that `ticket.transferred?` status is never set anywhere.
3. **Venue changes (H3).**
   - `organizer/events_controller.rb` `reschedule?` (~l.471) → `buyer_visible_change?`. Venue fields (`venue_id venue_name venue_address venue_city`) on a published/postponed event create `change_type: "venue_changed"` (add to `EventChange::TYPES`, with a migration if there is a DB check constraint). Require `change_reason` (API + `EditEventPage.jsx` UI) and send the change email.
   - Venue changes don't offer self-serve refunds.
4. **Change email content (M1), `email_service.rb` ~l.558.**
   - Show before/after date/time (`format_local_datetime`, event timezone) and venue from `before_data`/`after_data`, plus the escaped organizer reason. Use specific subjects ("New date for …", "Venue change for …", "… is postponed"). Move copy into the existing email locale mechanism if there is one.
   - Coalesce: delay delivery ~10 min and skip if a newer change exists for the event.
   - Also notify holders whose `holder_email` differs from the buyer (transferred tickets), with no duplicate sends.
   - Specs: Guam time and reason shown; two edits within 10 min → one email per recipient.
5. **Guest link lifetime (M2), `guest_order_access.rb`.**
   - `expires_at = [30.days.from_now, (event.ends_at || event.starts_at)&.+(7.days)].compact.max` (as shipped in `GuestOrderAccess.default_expires_at`, so an event with no end time still gets at least 30 days) for confirmation and event emails. Only ever extend `guest_access_expires_at` (take the max).
   - Spec: an order for an event 60 days out still opens on event day.
6. **Guest token out of query strings (L5).**
   - Email links (`email_service.rb` ~l.627, ~l.1134) put `guest_token` in the URL fragment (`#guest_token=`). The frontend (`OrderConfirmationPage.jsx` ~l.96) reads the fragment, still accepts the legacy query param, and strips both from the URL.
7. **Order recovery rotation (L3), `order_recovery_controller.rb:29`.**
   - Use `rotate: order.guest_access_revoked_at.present?` so recovery doesn't revoke the buyer's existing links. Specs: `order_recovery_spec.rb`, `guest_order_access_spec.rb`.
8. **Postponed/cancelled public page (M4).**
   - A show-only scope including `postponed` and `cancelled` (respecting policy hold and organizer verification gates). The API returns status with sales closed.
   - `EventDetailPage` shows a clear status banner ("Postponed — your tickets stay valid; check your email" / "Cancelled — refunds are automatic for card payments"), with no buy UI.
   - Keep these events out of discovery lists and the sitemap.
9. **Admin buyer actions (L2), `orders_controller.rb` ~l.454.**
   - The admin bypass applies only to `show` and `resend`. Add admin-denied cases to `order_access_spec.rb`, and check that support/admin tools don't depend on it (grep the frontend admin/support pages).

## Slice B — Checkout integrity and payments (backend + Checkout UI)
Branch `fix/checkout-integrity`.

1. **Promo by ID (N1, High).**
   - `order_creator.rb` ~l.588 must look codes up by the `promo_code` string (`event.promo_codes.find_by(code: normalized)`, using whatever normalization the existing validate endpoint uses). If an ID is also sent, it must match.
   - Add `promo_code` to `CHECKOUT_DIGEST_FIELDS`. Update `CheckoutPage.jsx` (~l.403) to send the code.
   - Specs in `orders_spec.rb`: guessing another code's ID fails.
2. **Hold griefing (M).**
   - Allow one active pending order per normalized email (or user) per event; same-key checkout recovery is unaffected.
   - Add an `orders.checkout_ip_digest` column (HMAC of `request.remote_ip` with a server secret) and cap active held tickets per digest per event (`HAFAPASS_MAX_HELD_TICKETS_PER_IP`, default 40).
   - Make `ticket_types.max_per_order` NOT NULL with default 10: backfill nulls in the migration and make it reversible.
3. **Free ticket draining (N2).** Apply the per-IP-digest cap to free tickets issued per event too (`HAFAPASS_MAX_FREE_TICKETS_PER_IP`, default 20).
4. **Rate limits for orders, `rack_attack.rb` ~l.106.** Once caps 2–3 exist, raise `orders/ip` to 30/min and add an `orders/email` throttle. Keep existing specs green.
5. **Late payment after hold expiry (M).**
   - `order_lifecycle.rb` `expire!` (~l.152): retrieve the PaymentIntent first. If it succeeded, complete the order (normal fulfilment) when capacity remains.
   - In the late-capture branch (~l.69), enqueue `LateCaptureRefundJob`: `RefundCreator` via `refundable_late_capture?`, idempotency key `late-capture:payment:<id>`, a buyer email ("your payment was refunded because your hold expired"), `Sentry.capture_message`, and resolution of the exception with an audit note on success.
   - Include remaining late-capture exceptions in `RefundReconciliationQueue`.
   - Specs: `spec/services/commerce/order_lifecycle_spec.rb` plus a job spec.
6. **Minimum charge.** Raise `CheckoutError` before `Order.create!` when payment is required and the total is 1–49¢. Return the same message from promo validation. The UI shows it.
7. **Early fraud warnings.**
   - Handle `radar.early_fraud_warning.created/updated` in `stripe_webhook_processor.rb`: open `ReconciliationException` code `early_fraud_warning` (not in `RefundSafety::FINANCIAL_CODES`) and send a Sentry warning.
   - Admin action: cancel tickets + refund with reason `fraudulent`, audited (there may be an existing refund admin path to reuse).
   - Note in the PR that Leon must add these event types to the live and test webhook endpoints in Stripe.
8. **Stripe client.**
   - `config/initializers/stripe.rb`: `open_timeout = 5`, `read_timeout = 20`, `max_network_retries = 2`. Spec: `StripeClient` picks them up.
   - Cache the `accounts.retrieve_current` match in `stripe_service.rb` ~l.281 per (sha256(key), environment) for 10 minutes, caching only matches.
9. **Legacy `POST /check_in/:credential` (L1).** Remove the route, controller and `checkin/ip` throttle. Update specs that call it. Confirm the frontend never calls it.

## Slice C — Auth, rate limits, ops hardening (backend + config)
Branch `fix/ops-hardening`.

1. **Clerk JWKS, `clerk_authenticator.rb`.** Select the key by `kid`. On an unknown `kid`, refetch at most once per 5 minutes. Keep serving the last good JWKS for up to 24 h when a fetch fails, and cache the failure for 30 s. Guard with a mutex. Spec: `clerk_authenticator_spec.rb`.
2. **rack-attack.**
   - Exclude `/webhooks/stripe` and `/webhooks/resend` from `req/ip` and give them their own limit (600/min).
   - Exclude `GET /api/v1/tickets/:credential` from `req/ip` and throttle per credential.
   - Add a request spec using `spec/support/rack_attack_cache.rb`.
   - Log which IP source is used (document `req.ip` behind Render/Cloudflare).
3. **Timeouts.**
   - Resend: `HTTParty::Basement.default_timeout(10)` or a per-request timeout in the Resend client. Cover the synchronous `guest_privacy_requests_controller.rb:16` send.
   - Readiness reports `statement_timeout` (`SHOW statement_timeout`) as an informational, non-required field.
4. **Operational alerts.** `OperationalAlertJob` in `recurring.yml` every 5 min. It sends `Sentry.capture_message` with a stable fingerprint per signal when any of these is above 0:
   - exhausted message deliveries (failed, attempts ≥ 5, failed in 24 h)
   - failed payment webhooks
   - open reconciliation exceptions
   - Solid Queue failed executions in the last hour

   Repeat an alert only when a signal's count rises, or at most every 6 hours while it stays above 0 (as shipped, with state in `runtime_alert_states`). Specs for each.
5. **Bulk re-send.**
   - `POST /api/v1/support/message_deliveries/bulk_resend` with filters `status=failed`, `failed_after`, `failed_before`, `event_id`; cap 500. Apply per-row `retryable?` and suppression checks. Return `{queued, skipped:{reason:count}}` and write audit entries.
   - Add a button with a confirmation in the support console message-deliveries screen.
   - Request specs.
6. **Readiness detail.** Public `GET /api/v1/readiness` returns `{status, timestamp}` only, with the same 200/503. Full detail requires an `X-Readiness-Token` matching `ENV["READINESS_TOKEN"]` (`secure_compare`). Check that no frontend or admin code reads the detail; if admin does, give admin an authenticated route. Extend `health_spec.rb`.
7. **strong_migrations.**
   - Add `gem "strong_migrations"` (compatible current version).
   - Initializer: `start_after` = latest existing migration version, `lock_timeout = 10.seconds`, `statement_timeout = 1.hour`, `target_version = 16`.
   - Make sure existing migrations and the release-migrate path still run (`bin/release-migrate`).
8. **Audit TRUNCATE trigger.**
   - Statement-level `BEFORE TRUNCATE` on `audit_logs`. It raises unless `current_setting('hafapass.audit_truncate', true) = 'on'`.
   - `SyntheticDataPurge` sets it with `SET LOCAL`. Add to `AuditLogIntegrity::SQL` and a migration. Keep the purge specs green.
9. **render.yaml drift.**
   - `branch: hafapass-staging`.
   - Add `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `..._DETERMINISTIC_KEY`, `..._KEY_DERIVATION_SALT`, `MAILER_REPLY_TO`, `HAFAPASS_LAUNCH_CAPABILITIES`, `READINESS_TOKEN` (and Apple pass vars if referenced) as `sync: false`.
   - Extend `render_deployment_contract_spec.rb`.
10. **Dockerfile (Ruby is already 3.3.13 via PR #173).**
    - Multi-stage. The build stage has build-essential and libpq-dev, runs `bundle install`, then `bootsnap precompile --gemfile app/ lib/`.
    - The runtime stage has only `libpq5` and `curl` (plus whatever the current image installs that runtime needs: check). It runs `useradd -u 1000 rails`, creates `tmp/pids tmp/cache log storage` owned by rails, and switches with `USER 1000:1000`.
    - Keep the same CMD/entrypoint and preDeploy command compatibility.
    - The image can't be built locally (sandbox). Be conservative and explain each change in the commit message.
11. **Netlify.** In BOTH `netlify.toml` files, which must stay identical where they overlap:
    - `[[headers]] for="/assets/*"` `Cache-Control = "public, max-age=31536000, immutable"`.
    - `Access-Control-Allow-Origin = "https://js.stripe.com"` for `/assets/*.woff2` (Stripe Elements fonts).
    - `X-Robots-Tag = "noindex, nofollow"` and `Referrer-Policy = "no-referrer"` for `/tickets/*`, `/orders/*`, `/checkout/*`, `/ticket-transfers/*`, `/unsubscribe/*`, `/my-tickets`, `/saved`, `/admin*`, `/support*`, `/privacy*`, `/account/*`, `/*-invitations/*`, `/sign-in*`, `/sign-up*`.
    - A `Content-Security-Policy-Report-Only` allowing self, Stripe (js.stripe.com, api.stripe.com, hooks), Clerk (the production Clerk frontend API domain and `*.clerk.accounts.dev`, plus img.clerk.com), Sentry ingest, the API origin, S3 bucket images, and Google fonts only if used.
    - Mirror any header contract spec if one exists (`grep -r "netlify.toml" hafapass_frontend/src hafapass_frontend/e2e hafapass_api/spec scripts`).
12. **Docs.**
    - `docs/OPERATIONS_RUNBOOK.md`: deploy order (API first: fast-forward `hafapass-staging`, deploy on Render, wait for `/api/v1/health` to show the revision, then merge/publish the frontend; expand/contract API changes). Also cover the statement-timeout SQL for Neon, the external alert/uptime setup steps, the Neon PITR/restore drill steps, TIN key custody (location placeholder, never values), and the staging names explained.

## Slice D — Settlement lifecycle and admin operations (backend + organizer/admin UI)
Branch `fix/settlement-lifecycle`.

1. **Archive guard (H1).**
   - `EventLifecycle#validate_action!` rejects `:archive` unless the event is a draft, or its latest finalized statement matches the current `Settlements::Calculator` digest and nothing payable remains.
   - `EditEventPage.jsx` Archive opens a confirmation dialog explaining this. Optional admin-only `unarchive` back to the previous status.
   - Specs: refused when unfinalized, refused when stale, allowed after finalize.
2. **Reconciliation exceptions (H2).**
   - `GET /api/v1/admin/reconciliation_exceptions` (filters: open/resolved, code, organization).
   - `POST .../:id/resolve` with a required note, audited.
   - For the late-capture codes, a "Refund buyer" action calling the existing refund path. Coordinate the name with Slice B's `LateCaptureRefundJob`; if that isn't merged yet, implement against `RefundCreator#refundable_late_capture?` directly.
   - An admin UI page linked from the Operations card (replace the "give the local record number to the finance owner" copy).
   - Specs: resolving restores `available_cents`; a note is required.
3. **Auto-complete (M3).**
   - Hourly `CompletePastEventsJob` in `recurring.yml`: `EventLifecycle :complete` for published events with `ends_at <= now - 6h`, with a system actor, audited.
   - Fix the `FinancesPage.jsx` (~l.270) copy, and show a "Mark completed to finalize" prompt on analytics/finance when relevant.
   - Delete `lib/tasks/events.rake`'s `update_all` completion (L2), or route it through `EventLifecycle`.
4. **Annual tax CSV (L1).** `admin/annual_tax_reports_controller.rb` ~l.72 uses `SpreadsheetExport.safe_value`.

## Slice E — Door experience: scanner and ticket (frontend)
Branch `fix/door-experience`.

1. **`src/hooks/useScreenWakeLock(active)`.**
   - Extract it from `TicketPage.jsx` (~l.19–60), keeping its behavior and tests, and use it in `ScannerPage.jsx` while scanning (camera ready).
   - If unsupported, show a one-line tip to set Auto-Lock to Never while scanning.
2. **Scan result feedback.**
   - Full-screen overlay (`fixed inset-0 z-[60]`):
     - Admitted: `bg-emerald-600`, about 700 ms, auto-dismiss.
     - Refused: `bg-red-700`, until tapped.
     - Warning/needs attention: `bg-amber-500` with dark text, until tapped.
     - A 96 px white icon and a large message. Make sure Undo and the next scan still work afterwards. Respect reduced motion (no scale animations; opacity is fine).
   - Move `ResultPanel` below the video.
   - Audio: create the `AudioContext` on the "Start camera" tap. Admit is a short 880 Hz tone; refuse is two 220 Hz beeps. Set `navigator.audioSession.type = 'playback'` where available. Add a Sound toggle persisted in localStorage. Keep `navigator.vibrate` for Android.
3. **Landscape.** The video gets `max-h-[60dvh]` with no overflow in landscape.
4. **Ticket page.**
   - QR `size` 280 inside `w-full max-w-[17.5rem] h-auto`.
   - The error/offline branch (~l.337) renders on brand-950. When `!navigator.onLine`, say: "You're offline. Reconnect to show your ticket QR, or open it from Apple Wallet if you added it."
   - Buyer-facing `text-xs` → `text-sm` on venue/doors/instructions.
   - Wallet buttons: at least 44 px tall. Show Apple Wallet only on Apple platforms and Google Wallet only on Android/other (keep both where detection is unknown). Keep them hidden when the capability is off. Check the iOS blob download path; prefer navigating to a server URL for `.pkpass` if the API supports it, and leave it unchanged if not.
5. Tests for the hook, the overlay states, the sound toggle and the ticket offline state.

## Slice F — Frontend platform (frontend)
Branch `fix/frontend-platform`.

1. **SEO.**
   - `SEO.jsx` canonical defaults to `PUBLIC_WEB_URL + location.pathname` and is omitted when `noIndex`.
   - `noIndex` on TicketPage (add `<SEO>`), OrderConfirmation, OrderRecovery, Checkout (always), MyTickets, Saved, Unsubscribe, Privacy requests, transfers, invitations, sign-in/up, dashboard/admin/support.
   - Layout renders a route-derived default `<SEO title noIndex>` for workspace/admin/support paths so tab titles never go stale; pages override it.
   - Update `SEO.test.jsx`.
2. **axios.** `api/client.js`: `timeout: 20000`. Map `ECONNABORTED` to a friendly "Your connection is slow…" message where errors are surfaced. Order/payment POSTs get 45 s unless they already carry idempotency keys (check first).
3. **Boot splash.**
   - The header-theme plugin (`config/headerTheme.js`) also sets `--startup-page-color` (`#032827` for routes whose page top is dark: `/`, `/host`, `/tickets/*`, and the title-band routes if the page background is light below a dark band; choose what avoids a flash) and a white wordmark when dark.
   - The splash bar height is `calc(64px + env(safe-area-inset-top))`, and the wordmark uses the display font stack.
   - Keep the `header-startup-theme` and `first-load` e2e expectations green, or update them deliberately.
4. **framer-motion.** Replace `MotionConfig` (`main.jsx`) and the Layout route fade with CSS (`ticket-fade 150ms` keyed on path), so framer loads only on pages that import it. Keep reduced-motion behavior.
5. **Fonts.** Preload the two Latin variable woff2 files (Plus Jakarta Sans, Space Grotesk) via a build plugin or `index.html`, with `crossorigin`.
6. **Loading.**
   - Under reduced motion, `.animate-spin` uses an opacity pulse instead of freezing.
   - One translated `<PageLoading>` for whole-route loading (wordmark style), used by `ProtectedRoute`, `ClerkProviderWrapper`'s "Preparing your account…" (it must not hide the nav if avoidable) and admin/support route loaders. Translate the English-only aria-labels.
7. **ErrorFallback.** A brand-950 page, a white ticket card, `HafaPassMark`, "Try again" (primary), "Reload HåfaPass" (secondary) and a Home link. No blurred blobs or glass.
8. **Focus ring on dark.** A `.surface-dark` class (hero, title bands, Host dark sections, TicketPage, footer, dark nav state) sets `:focus-visible` outline `#53f5df`.
9. **Manifest/meta colors.** Replace off-palette `#0e7c7b` in `manifest.json`, `msapplication-TileColor` and the boot splash with brand tokens (`#032827` / `#0b6563`). Split icon purposes into separate `any` and `maskable` entries (maskable only if the artwork has a safe zone; otherwise `any` only).
10. **Cover upload downscale.** `CoverImageUpload.jsx` resizes in the browser before upload (`createImageBitmap` with `imageOrientation: 'from-image'`, canvas to WebP at 1600 px longest side, quality 0.82; fall back to the original if unsupported or larger). Keep server validation untouched. Also:
    - Hero image: `fetchpriority="high"`.
    - Checkout thumbnail: `loading="lazy" decoding="async"` with width/height.
11. **Small fixes.**
    - Remove `dark:` from `Skeleton.jsx`, and check other `dark:` variants that misfire under OS dark mode.
    - Add `@media print` rules (hide nav, footer and buttons; keep the ticket QR and details).
    - i18n the 9 hardcoded strings in `PrivacyRequestsPage.jsx`.

## Slice G — Buyer polish and copy (frontend)
Branch `fix/buyer-polish`.

1. **Empty Home.**
   - When there are no events, the hero ticket drops the hosting stub. Heading "The first events are on their way." Body "When organizers publish, you'll find them here. Buy in a minute and keep your tickets on your phone." Primary action: add to Home Screen (reuse `InstallAppHelp`). Secondary link: "Already bought a ticket? Find it" → `/orders/recover`.
   - Add a three-stub "How your pass works" strip on the light sheet: "Find an event — everything on Guam, in Guam time." / "Buy in a minute — pay by card; your tickets arrive by email, no account needed." / "Walk right in — show the QR on your phone at the door."
   - Pitch hosting only once (the planning ticket).
   - Remove the hero hosting stub whenever the planning ticket is shown.
   - The planning ticket surface moves to brand-950, or uses a white button (no coral on mid-teal).
   - If published-not-yet-on-sale events are returned by the list API, show them as "On sale {date}". Verify; skip if not.
2. **Empty Events gap.** Drop `.public-listing-min-height` when the inventory is empty.
3. **Greys.** Replace stone with neutral/surface: `bg-stone-50` → `bg-surface`, `/95` likewise, `border-stone-200/300` → `border-neutral-200/300`, `hover:bg-stone-200` → `hover:bg-neutral-200`. Confirm a `surface` token exists in `tailwind.config.js`; add one if not. Add a vitest guard that fails on `-stone-` in `src`.
4. **Placeholders.** Placeholder color neutral-500 (#64748b) in `index.css`. Prefix example placeholders with "e.g. " consistently.
5. **Stripe Elements (`StripeProvider.jsx`).**
   - `fonts: [{ family: 'Plus Jakarta Sans', src: url(<woff2 via ?url import>), weight: '200 800' }]`. Slice C adds the Netlify CORS header.
   - Variables: colorPrimary `#0b6563`, colorText `#0f172a`, colorTextSecondary `#475569`, colorDanger `#b91c1c`, colorTextPlaceholder `#64748b`, fontSizeBase `16px`.
6. **Checkout.**
   - Buyer-facing `text-xs` → `text-sm` (field errors, waiver, fee lines).
   - `text-emerald-600` → `emerald-700`.
   - "Back to event" links (~l.491, 525, 562): `min-h-11` tap target.
7. **Tokens.**
   - Add `success`/`warning`/`danger`/`info` color aliases (emerald/amber/red/sky) to tailwind and use them on buyer pages touched in this slice.
   - Replace stock `shadow-sm/md/lg/xl/2xl` on buyer pages with `soft`/`card`/`float`.
   - Delete unused animation tokens (fade-in, fade-up, shimmer, float, pulse-soft) only after grepping that they're unused.
8. **Sentence case.**
   - Buyer strings in `en.json` (list in the re-review: nav.myTickets, events.pastEvent/soldOut/ticketsAvailable, eventDetail.buyTickets, addToCalendar, allEvents (fix the leading space), browseEvents (fix the trailing space), the checkout labels, waitlist, common.retry, footer.forOrganizers, allAges, exploreByCategory, startHosting2, whosGoing, processingPayment, simulateMode/testMode, signUp, eventTitle, ticketPage instructions/myTicket, findYourOrder, createAnEvent).
   - Hardcoded organizer/admin strings in CreateEvent/EditEvent, PricingTiersCRUD, TicketTypeCRUD, BoxOffice, EventAnalytics, Dashboard, GuestList, Attendees, Waitlist, AdminDashboard, AdminEvents and AdminOrders.
   - Keep policy document names, event category names and Apple's "Add to Home Screen" as is.
   - Update the tests that assert old strings. Coordinate with Slice A's EditEventPage change by touching only labels.
9. **Edit Profile modal** (`DashboardPage.jsx` ~l.233) → shared `Dialog` (role, focus trap, Escape, focus return).
10. **Waitlist table on phones** (`WaitlistPage.jsx` ~l.265) → the existing `foldTable` helpers, so actions are reachable.
11. **iOS date/time inputs.** `input[type=datetime-local|date|time]` get `min-h-12`, plus `::-webkit-date-and-time-value { text-align: left }` in `index.css`.

## External / Leon actions (not code)
- Sentry alert rules (new issues + the OperationalAlertJob fingerprints) routed to Leon plus a backup.
- An uptime monitor on `/api/v1/readiness` (keyword `"status":"ready"`) and the frontend root.
- Render deploy-failed and health notifications.
- Neon: confirm a paid plan and PITR of 7 days or more; run the restore-to-branch drill; record the results in the runbook.
- Neon: `ALTER ROLE … SET statement_timeout='30s'` and `idle_in_transaction_session_timeout='60s'`.
- TIN encryption keys in a password manager with a second custodian.
- `READINESS_TOKEN` env var on Render.
- Stripe: add the `radar.early_fraud_warning.*` events to the live and test webhook endpoints.
- Triage the 14 stale Resend webhook events in Admin → Operations.
- S3 bucket versioning/lifecycle check.
- Close Dependabot PRs #158 and #167 (they don't fix the advisories and carry risky majors); add patch/minor + security grouping to `.github/dependabot.yml`.
- Gate F load test and Gate G door rehearsal on a real phone.
