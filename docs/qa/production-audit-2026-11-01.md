# Production audit — 2026-11-01

Commit audited: main `c45bacda` (frontend live at the same revision). API live at `b462f4f1` (`hafapass-staging`, 35 commits behind main; only a SiteSetting default differs).
Method: static code review by three Claude review agents (payments/security, runtime/ops, frontend/styling), lead verification of the highest-risk claims, GET-only production probes, and a real-browser reproduction of the reload bug using two local production builds. Nothing was written to production.

## Verified by the lead

### R1. Extra page reloads after every deploy (High, reproduced)
`src/utils/releaseUpdate.js` `notice()` reloads whenever the controlling worker's shell revision differs from the running bundle, with no notion of which is newer.

- **Refresh right after a deploy:** the HTML arrives from the network (NetworkFirst, `max-age=0`) with the new revision. `ReleaseUpdateCoordinator.readShell()` then fetches `/index.html` through the *old* worker's precache, sees the old revision and calls `reload()`. Reproduced: one manual refresh gave two `GET /` requests 200 ms apart, with session key `hafapass_release_reload:<old revision>`. This happens before the browser even fetches the new `sw.js`, so it occurs on every first post-deploy load of a public page.
- **Public page left open during a deploy:** the 60 s poll reloads the visible page (public routes are always "safe"). Reproduced on Home: two unprompted reloads 200 ms apart, scroll position lost (400 → 0).
- **Fix:**
  - Only reload when the shell revision equals the latest `release.json` revision and differs from the running one. That way a newer page never "updates" itself to an older shell.
  - Never reload a visible page. Apply the update while the tab is hidden, or turn the next in-app navigation into a full page load.
  - Add a coordinator test for "page is B, worker shell is still A, release.json is B → no reload".

### R2. Header colour swap is instant by design (Low, design)
`src/index.css:217` `.app-nav, .app-nav * { transition-property: none !important; }` was added in d058ceeb. The reason: the earlier per-element transitions ran the text and the background at different speeds, which failed contrast mid-transition (`docs/qa/pass-direction/README.md:131`). The switch fires at `scrollY > 10` (`Navbar.jsx:32`), so on Home a white header sits over the still-dark hero (the second phone screenshot).
- **Recommendation:**
  - Keep the header teal while the dark hero or title band is under it, and switch when the light sheet reaches the header. Use an IntersectionObserver on a `data-header-theme="dark"` section, not a 10 px threshold.
  - Crossfade background, border, text and icons together, with one duration and easing (~200 ms, `ease-out`). The cleanest way is one white overlay layer whose opacity animates, with text colour on the same timing.
  - Reduced motion: keep the instant swap.
  - `theme-color` can't animate. Set it at the same moment.

### R3. Refund-on-event-change is broader than the policy (High, confirmed in code)
- `orders_controller.rb:323-370` lets any order on an event with any buyer-visible change (`rescheduled` is created by any schedule edit to a published event, `organizer/events_controller.rb:132`) request a full refund of all issued paid tickets.
- It never checks that the order predates the change, that the event hasn't ended, or that the window is still open. Unscanned no-shows can refund after the event, and buyers who bought after the change can refund on demand.
- The published policy promises a refund for postponement and only a "review" for other material changes (`config/policies.yml:142-144`).

### R4. The same path refunds tickets already transferred away (High, confirmed in code)
- An accepted transfer leaves the ticket `issued` and changes only the holder (`ticket_transfers/manager.rb:63`). `RefundCreator`'s guard checks `ticket.transferred?` status (`refund_creator.rb:278`), so it never fires.
- Free tickets are protected by `controls_ticket?`; paid tickets are not.
- **Fix (R3+R4):**
  - Require `order.created_at < change.occurred_at`.
  - Reject once the event has ended.
  - Filter tickets with `controls_ticket?`.
  - Set a response deadline (Leon/counsel decision).

### R5. CI will go red on the next PR (High, versions confirmed)
- rack 3.2.6 (`Gemfile.lock:277`) and follow-redirects 1.16.1 (`package-lock.json`) are flagged by `bundler-audit check --update` (`ci.yml:84`) and `npm run audit:prod` (`ci.yml:107`).
- Bump both before any event-week hotfix is needed.

## Reported by agents, not independently re-verified

### Payments / security
- M: Unpaid holds are created before card entry. With only 10 orders/min/IP, one IP can hold ~1,000 tickets (`order_creator.rb:129`, `rack_attack.rb:106`).
- M: A payment that succeeds after its hold expired is released with a ReconciliationException. There is no auto-refund or alert, and Stripe has already emailed a receipt (`order_lifecycle.rb:60-77`).
- M: Clerk JWKS is cached 1 h with no refetch on an unknown `kid`, and failed fetches aren't cached (10 s timeout per request) (`clerk_authenticator.rb`).
- M: The IP throttles include `/webhooks/stripe`, and order throttles are IP-only. Guam carrier CGNAT and venue Wi-Fi share IPs (`rack_attack.rb:63,105`). `req.ip` behind Render/Cloudflare is unverified.
- L:
  - Legacy `POST /check_in/:credential` isn't event-scoped.
  - Admins pass every buyer action.
  - Order recovery rotates guest tokens, so known reference + email can revoke links.
  - Uncached `accounts.retrieve_current` runs before every Stripe call.
  - Credentials appear in URL paths and edge logs.
  - No minimum net amount.
  - No `radar.early_fraud_warning` handling.

### Runtime / ops
- H: One process (0.5 CPU, 3 Puma threads, 1 job thread). There are no Stripe/Resend/Postgres statement timeouts (gem defaults 30–80 s). Gate F load test and Gate G door rehearsal are still pending.
- H: No evidence of alert routing or uptime monitoring. Render's health check `/up` doesn't touch the DB. Exhausted outbox deliveries stop silently.
- H: Neon plan, PITR window and restore drill are undocumented. Solid Queue polling keeps compute awake (~180 CU-h/month), which would exceed a free-plan allowance.
- M:
  - The frontend auto-deploys ahead of the manual API deploy, and there is no defined order.
  - `render.yaml` drifted from the live service (branch, encryption env).
  - TIN encryption key custody is undocumented.
  - No bulk re-send after a Resend outage.
- L:
  - No migration safety tooling.
  - Ruby 3.3.4 base image running as root.
  - Readiness endpoint is public.
  - The audit trigger doesn't block TRUNCATE.
  - The production DB is still named `hafapass_staging`.
- Solid: durable Solid Queue jobs + recurring schedule, no Redis, no cold starts, Neon pooler, Sentry on both ends, UTC + per-event timezone, synchronous Stripe webhooks with retry, comprehensive CI, signed offline scanner manifests.

### Frontend / styling
- H: The door scanner has no Wake Lock, so the phone auto-locks and the camera dies (`ScannerPage.jsx`).
- H: Scan results are pale cards, and iOS has no vibration. Use a full-screen solid green/red flash plus an audio tone.
- H (feel): The empty Home is a dead end for buyers. "Host" is pitched twice and "soon" appears twice. Add a buyer action (notify me / install), a "How your pass works" strip, and a "Coming up" ticket once the pilot is announced.
- M:
  - The SEO canonical falls back to `/` on many pages.
  - Ticket/order/checkout pages aren't noindex.
  - Full-size cover uploads are reused at thumbnail sizes.
  - axios has no timeout.
  - Boot splash flashes light → dark on dark routes.
  - Stone/slate greys are mixed.
  - Placeholders read as filled values.
  - Stripe Elements are in the system font with off-token colours.
- L:
  - framer-motion is preloaded for one fade.
  - Fonts aren't preloaded.
  - Five different loading styles; spinners freeze under reduced motion.
  - Error screen is off-brand.
  - Stale tab titles.
  - Focus ring contrast is weak on dark backgrounds.
  - Coral button on mid-teal.
  - Token drift (shadows, radii, status colours).
  - `text-xs` used for buyer info.
  - Ticket QR ~190 px.
  - Small checkout back link.
  - Mixed title/sentence case.
- Solid: no `dangerouslySetInnerHTML`, safe return paths, no secrets in the bundle, security headers, per-route code splitting, iOS zoom guard, safe areas, ticket wake lock, skip link, route focus management, consistent motion easing.

## Outcome (2026-11-02)

Every item in `production-audit-2026-11-01-plan.md` was implemented except the lead-deferred decisions (product analytics, automatic holder reminders, server-side thumbnails) and the external/owner actions listed at the end of the plan. A second verification pass and independent reviews of each slice found more issues; they were fixed before merge. Notable ones:
- the promo-code-by-ID hole;
- archiving that stranded payouts;
- silent venue changes;
- a start time moved and then restored opening refunds;
- note-only reconciliation resolves stranding buyer money;
- caps that would have keyed on a proxy IP;
- held-QR re-scans at the door.

| PR | Scope | Merge commit |
|---|---|---|
| #173 | rack, follow-redirects, Ruby 3.3.13 (runner image), flaky receipt spec | bbe5960f |
| #180 | addressable advisory | af773940 |
| #174 | extra reloads after deploys (R1); header fade (R2) | 59d0cda0 |
| #178 → #179 → #181 | frontend platform, door experience, buyer polish (stacked) | 50c65192 |
| #182 → #183 → #184 → #185 | ops hardening, refunds and event changes, checkout integrity, settlement lifecycle (stacked) | eb5d14f9 |

Deployment verified 2026-11-02:
- **Revisions:** frontend `release.json` and API `/api/v1/health` both report `eb5d14f9`. Readiness is `ready`.
- **Migrations:** all seven new migrations ran in the Render pre-deploy step.
- **Logs:** no error-level lines after the deploy.
- **Client IP:** the `rack_attack_client_ip_source` log line shows the resolved client IP matches `CF-Connecting-IP` and `True-Client-IP`.
- **Headers:** Netlify serves noindex/referrer headers on private paths, immutable caching on assets, and a report-only CSP.
- **Browser:** the empty Home and the header behavior were checked in a browser at 390 px.

Still open for Leon (details in the plan's "External / Leon actions" and `docs/OPERATIONS_RUNBOOK.md`):
- **Real phones:** scanner tones with the silent switch on, wake lock over a long session, Apple Wallet download, landscape.
- **Monitoring:** Sentry alert rules for new issues and `operational-alert/*`; an uptime monitor on `/api/v1/readiness`; Render notifications.
- **Neon:** confirm the plan and PITR window and run the restore drill; apply the role-level `statement_timeout` and `idle_in_transaction_session_timeout`.
- **Stripe:** add `radar.early_fraud_warning.*` to the live and test webhook endpoints.
- **Secrets:** store the TIN encryption keys in a password manager with a second custodian.
- **Optional:** set `READINESS_TOKEN` on Render.
- **Resend:** triage the stale Resend webhook events in Admin → Operations.
- **Dependabot:** close #176/#177 (they carry risky major upgrades) and regroup.

Known residual: bulk re-send can stall if 2,000 or more suppressed recipients lead the failed queue. The response reports `capped`/`remaining` truthfully; a cursor would fix it.
