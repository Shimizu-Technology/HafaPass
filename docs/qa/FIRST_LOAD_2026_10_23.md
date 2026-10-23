# First-load QA — October 23, 2026

Source: implementation commit `7d63c68cbad418ee30e354d65e4f4423bb1eb730`, based on `main` at `677e46db`. Agent-executed affected-flow QA, using Node 22.22.3 and Chromium on Leon’s Mac. The later evidence commit changes documentation only.

## Context and acceptance

HåfaPass serves public event buyers and organizers, plus event staff who rely on previously authorized offline admission data. Clerk establishes identity; database authorization and account-bound scanner storage control access. Sources: `docs/ROLES_AND_ROADMAP.md`, `ServiceCheck.jsx`, `ClerkProviderWrapper.jsx`, `scannerAccountBinding.js`, their existing regression tests, and the owner’s production frame audit. Brain Dump’s October 4 company project review also identifies admission/offline operations and paid-launch gates; this change makes no launch-readiness claim.

Required outcomes: immediate branded HTML paint; public browsing during pending health; one mounted app through unchanged Clerk identity; purge-before-route access on an account change; offline scanner access preserved during real outages; online scanner withheld until healthy; stable event-not-found layout; one default social image per platform; no remount-driven duplicate Home events fetch.

## Passed scenarios

- First signed-out visitor: before JavaScript, the HTML wordmark appears on the app background. Once mounted, Home keeps the same `.app-shell` node through delayed real Clerk readiness. One `/events` request and one overlapping boot `/config` request. No “Preparing your account…” screen or opacity replay.
- Unchanged signed-in scanner owner: component regression uses both Clerk readiness signals and asserts the identical DOM node survives, including no inserted preparation screen and no purge.
- Sign-out/account switch: existing owner to signed-out or another owner immediately removes routes and blocks on the deferred purge. Purge success permits the new owner; failure remains locked with retry. Existing interrupted-purge, storage-failure, stale completion and peer-tab withdrawal cases pass.
- Pending health: public browsing and a typed search survive failure, retry and recovery. The degraded banner appears; the app is retained. If no app has rendered, the full outage page remains available.
- Scanner health: online routes remain gated until health succeeds, including React Router’s trailing-slash and case variants. Previously authorized saved admission access still opens through API/Clerk outages. Account changes still withdraw it and clear queued/private admission data.
- Missing event: at 390×844 and 1280×800, route chunk loading, detail loading and the full missing-event screen keep the footer position stable. Measured CLS is 0.000 at both sizes, below 0.1.
- Social images: rendered Home and missing-event heads each have one `og:image` and one `twitter:image`, both the existing 1200×630 `og-default.jpg`. Helmet adopts/removes the marked static image tags. Existing preview-token and stale-shell recovery tests pass.

## Browser evidence

Local production builds were created with Vite and served with `vite preview --host 127.0.0.1 --port 5221 --strictPort`. API responses are isolated Playwright fixtures: health delayed 600 ms, config 700 ms, events/404 1200 ms. Clerk uses the existing local test publishable key and its real service; script responses containing `clerk` are delayed 2200 ms to reproduce late readiness. Cache is disabled, service workers blocked, CPU throttled 4×, and each case gets a fresh browser context. This is a controlled reproduction, not production latency benchmarking.

Screenshots are captured about every 100 ms, with actual capture times recorded. An init-script MutationObserver counts shell removals/replacements, a PerformanceObserver records layout shifts, and a request log records only API paths/methods/times. No tokens, auth responses, passwords, or customer fixtures are recorded.

Baseline `677e46db`: Home has one shell removal/replacement and two events requests at both sizes; boot config is requested three times. Mobile 404 CLS is 0.385655; desktop 404 CLS is 0.188835. Clerk finishes during every capture. Baseline captures run eight seconds.

Patched build: zero shell removals/replacements at both sizes, one Home events request, one boot config request, 404 CLS 0.000 at both sizes, no page errors or horizontal overflow. Captures run ten seconds, through settled content.

Raw evidence is local and ignored by Git:

- `.release-evidence/first-load/before/{390-home,390-404,1280-home,1280-404}/timeline.json` and timestamped PNGs
- `.release-evidence/first-load/after/{390-home,390-404,1280-home,1280-404}/timeline.json` and timestamped PNGs
- Reproduction script: `hafapass_frontend/scripts/first-load-audit.mjs`; run from the frontend directory with `node scripts/first-load-audit.mjs before` or `after` against the corresponding preview build. Build with `VITE_API_URL=http://127.0.0.1:3051/api/v1` and the configured public web URL. No local API process or database is required.

T3 preview snapshots twice returned `Preview automation snapshot timed out after 15000ms`; the mandated standalone Playwright audit and full browser suite both ran successfully. Mobile coverage is browser viewport emulation, not physical iOS/Android hardware. Signed-in identity changes use component/IndexedDB fixtures, not a live staff-account switch. Stripe transactions and backend changes are outside scope.

## Local gate

- ESLint: passed, zero warnings.
- Vitest: 161 files, 1,733 tests passed. Tests run with `VITE_CLERK_PUBLISHABLE_KEY=''`, matching CI’s absent local env; auth tests explicitly inject a test key. Existing jsdom network-error stderr occurs in the passing suite.
- `npm run build`: passed, including safe translation preparation and Vite/PWA output. Final build release metadata identifies `7d63c68c`.
- `PLAYWRIGHT_PORT=5224 npm run test:e2e -- --workers=2`: all 91 passed. The configurable strict port avoids concurrent tasks’ listeners; an occupied 5222 was left untouched.
- Production dependency audit: zero vulnerabilities.
- Release freeze: inactive; hygiene check passed.
- Impeccable 4.6.0 advisory scan of changed UI: no findings (`[]`).

Expectation changes are intentional: pending public health now renders the marketplace; a later health failure shows the existing degraded banner rather than discarding browsing state. Scanner-only gate assertions remain. Static HTML tests now expect a wordmark inside root and `og-default.jpg` instead of an empty root and square icon.

No backend files changed, including `hafapass_api/config/policies.yml`. Netlify deploys `main`; this branch remains unmerged for the lead. CI, CodeRabbit and merge readiness are reported in the PR/handoff rather than inferred from local tests.
