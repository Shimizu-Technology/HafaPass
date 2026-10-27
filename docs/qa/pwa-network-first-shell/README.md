# Network-first app shell QA

Agent-executed affected-flow QA, 2026-10-28. Base: `origin/main` at `7300a587788362bb75d0607bb6efbb8a16462490`. Branch: `codex/pwa-network-first-shell`. No backend, policy, pricing, fee or UI design changes.

HåfaPass serves event buyers, organizers and door staff. A prepared scanner must preserve its signed IndexedDB manifest and admission journal without network access. Sources: repository `README.md`; `src/ServiceCheck.jsx`, `src/utils/admissionStore.js`, `src/pages/TicketPage.jsx`, and the prior [deploy recovery QA](../pwa-update-on-deploy/README.md). The Brain Dump's `work/shimizu-tech/company-positioning-and-project-review-2026-10-04.md` confirms ticketing/offline admission and notes that a real paid pilot remains gated. This task does not change that release status.

The reported regular-iPhone symptom is consistent with the prior worker's precache navigation route. It can serve an old shell indefinitely until replacement installs. Production observations in the task brief are supplied evidence; this task does not claim to have reproduced the physical iPhone issue.

## Strategy and limits

A small vite-plugin-pwa `injectManifest` worker registers `request.mode === 'navigate'` with Workbox `NetworkFirst` before precache routes. Workbox's [generated template](https://github.com/GoogleChrome/workbox/blob/v7/packages/workbox-build/src/templates/sw-template.ts) registers `precacheAndRoute` first, so changing only `runtimeCaching` and `navigateFallback` would leave `/` and `/index.html` cache-first. The custom worker also uses the installed precache as `cachedResponseWillBeUsed`: installed Workbox 7.4.1 `NetworkFirst` waits beyond its timeout on a runtime-cache miss otherwise.

Network navigation has a three-second timeout. Offline, network failure, timeout and 5xx responses return the installed shell, with its matching precached assets. Network HTML is deliberately not runtime-cached: build C's shell must not become the offline fallback while only B's dependency graph is installed. Direct offline navigation to `offline.html` returns the standalone precached offline document. `/api`, `robots.txt`, `sitemap.xml` and `/assets/*` receive no shell fallback. `public/_redirects` is unchanged, including its missing-asset 404 rule.

Navigation preload is enabled with Workbox's feature detection. Its responses bypass `fetchDidSucceed`; the worker checks 5xx at `handlerWillRespond`, which covers both preload and ordinary fetches. `skipWaiting` and `clientsClaim` remain explicit. An already-installed old worker self-heals once the replacement successfully installs; this change cannot alter a worker which WebKit never downloads/installs. Worker activation never forces page navigation. PR #165's coordinator and safe-reload policy are unchanged; its ordinary non-navigation `/index.html` probe still reads the installed precache.

The precache follows the built dependency graph for the entry shell, scanner, box office, buyer transaction routes and not-found route. It includes their transitive imports, lazy dependencies, CSS, fonts, static images and `offline.html`. App-wide dynamic page/locale imports are excluded. Admin pages and non-English locale chunks remain network-loaded. English is in the main bundle.

Same-checkout normal production builds: **166 → 66 files; 2,894,059 → 1,826,418 bytes uncompressed; 974,229 → 655,575 bytes gzip** (each resource independently gzipped). This saves 60% of install requests and 33% of compressed bytes. The task's live-production count of 179 is a different build/configuration, not this reproducible baseline.

Buyer ticket JSON was not available after an offline reload before this change: the component fetches the API and private ticket caches are removed in `main.jsx`. The test preserves the rendered ticket across worker activation/disconnect, then verifies the existing offline reload/recovery behavior. No private API response caching or offline box-office sale capability is added.

## Required acceptance ledger

Fixtures use synthetic buyers/operators, a signed synthetic scanner manifest, HTTP API fixtures and simulated checkout. No real Clerk login, payment, email, account mutation or production data is exercised. The origin is stopped before offline checks, in addition to disconnecting the context. Browser contexts and server processes are isolated and cleaned.

| ID | Starting conditions, action and observable/saved outcome | Status |
| --- | --- | --- |
| N01 | Install legacy A (`createHandlerBoundToURL` navigation); deploy B; one revisit reaches B without cache clear and persists the revision reload guard | passed: Chromium and WebKit |
| N02 | Freeze B's worker response; deploy C; first document responses at `/`, `/index.html`, and `/events?first-navigation=C` contain C while the non-navigation precache probe still returns B | passed: Chromium and WebKit |
| N03 | Never-visited URL stalls before headers; receive B shell in about three seconds. Connection failure and 503 also fall back | passed: Chromium and WebKit |
| N04 | API, robots, sitemap and missing hashed-asset navigations receive no shell; missing asset remains 404 | passed: Chromium and WebKit |
| N05 | Activate B while A holds a checkout draft, hidden quantity selection, ticket and live scanner. Preserve documents/input; complete simulated order with selected line item; safe departure allows B | passed: Chromium and WebKit |
| N06 | Prepare scanner on A; with B installed and C deployed, disconnect and reload. Admit offline; journal pending count remains one after another offline reload | passed: Chromium and WebKit |
| N07 | Direct offline `offline.html` works, including a null-revision production build | passed: Chromium and WebKit |
| N08 | Rendered buyer ticket survives disconnect; offline reload loads B's retained buyer chunk and shows existing API recovery state | passed: Chromium and WebKit |
| N09 | Existing full Chromium affected-flow suite including event-day sync/reconnect and draft journeys | passed: 152/152, zero failures; no flaky rerun |

Desktop and 390px browser coverage is agent-executed. The full deploy suite passed in Chromium and WebKit (2/2 each). A physical iPhone and installed-iOS-PWA run are not available here; Leon owns those device checks.

## Initial failures

- The first fixture asserted a ticket code the page does not display. Changed it to verify the actual event heading and a valid synthetic entry credential.
- An overlapping full/PWA run deleted the PWA trace directory during cleanup. PWA now uses `test-results-pwa`, with matching CI artifact upload and ignore rules. Its server cleanup runs even if context cleanup throws.
- A real navigation-preload 503 bypassed the initial `fetchDidSucceed` hook. The delivery hook fixes it and the fault test remains.
- The standalone fixture initially omitted text/XML MIME types, so navigating to `robots.txt` triggered a download. Corrected the fixture MIME map.

The WebKit fixture initially failed because its worker-owned API fetches bypassed Playwright routing. API fixtures now use the real HTTP server for both engines. Both deploy tests pass without API request interception.

## Final engineering gates

Implementation source: `b60910160743bb7fb45d2827ef654c906865767c`; the following commit records evidence only. macOS arm64, Node 22.22.3, Playwright 1.64.1. API/auth/payment fixtures are synthetic. The normal build retains the real production auth gate.

- `npm run lint`: passed.
- `VITE_CLERK_PUBLISHABLE_KEY='' VITE_PUBLIC_WEB_URL='' VITE_API_URL='' npm test`: 182 files passed, one skipped; 2,022 tests passed, three skipped; zero failures (115.09s).
- `npm run build:no-translate`: passed; 66 precache entries, 1,783.61 KiB raw. [Exact manifest and before/after measurements](precache.json). Verified explicit worker activation/claim, network-first routing before precache, and retained scanner/box-office/buyer chunks.
- `PLAYWRIGHT_PORT=5238 VITE_CLERK_PUBLISHABLE_KEY='' npx playwright test --workers=2`: 152 passed, zero failures (1.9m). No flaky rerun needed. [Output](browser.txt).
- Production Chromium deploy suite: 2 passed, zero failures. [Output](pwa-chromium.txt).
- `PWA_BROWSER=webkit npm run test:e2e:pwa`: 2 passed, zero failures (33.9s). Includes legacy upgrade, C's first response, fault/timeout fallback, protected checkout/ticket/scanner documents, offline journal persistence and standalone offline page. [Output](pwa-webkit.txt).
- `scripts/check_hygiene.sh`, `ruby scripts/check_release_freeze.rb` and diff whitespace checks: passed; freeze inactive.

N01–N09 are accepted within this browser/fixture scope. Real iPhone Safari/Chrome and installed-iOS-PWA acceptance remain not run. No production deployment or merge was performed.

PR: [#168](https://github.com/Shimizu-Technology/HafaPass/pull/168). CodeRabbit is a required check and initially returned an OSS rate-limit message, with no review findings. One manual review request will be sent after this evidence push; required review remains pending, not clean.

All task-owned Vite/fixture servers and test-browser processes were stopped. Lifecycle session `01a17dad-430b-71f0-8b78-e2173ce216f8` reports no active owned resources. No simulator, container or collaborative browser tab was started. No runtime handoff. Preserve the named branch/worktree and open PR for the parent; DO NOT MERGE.
