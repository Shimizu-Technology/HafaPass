# Deploy update recovery QA

Agent-executed affected-flow QA, 2026-10-27. Base: `origin/main` at `66e4f6a0`. Implementation commit: `0ce141df` (final evidence-only commit follows).

HåfaPass serves event buyers and organizers, including door staff whose prepared scanner must continue without network access. The current project overview describes ticketing, offline admission, refunds, settlements and operational roles (Brain Dump: `work/shimizu-tech/company-positioning-and-project-review-2026-10-04.md`, HafaPass row). Verified implementation sources: `src/App.jsx`, `src/ServiceCheck.jsx`, `src/components/DraftNavigationProvider.jsx`, `src/utils/admissionStore.js`, `vite.config.js`, and `config/releaseMetadata.js` under `hafapass_frontend`.

The prior worker precached `index.html` and activated updates, while the injected registration script did not reload the already-rendered document. The fix retains the offline navigation shell and uses the virtual registration module's `onNeedReload` hook. The installed vite-plugin-pwa 1.3.0 supports overriding the reload callback; see [plugin source](https://github.com/vite-pwa/vite-plugin-pwa/blob/main/src/client/build/register.ts). A no-store `/release.json` check requests worker updates on startup, reconnect, foreground and every minute. Before scheduling a reload, the coordinator reads the revision embedded by the existing release-metadata plugin in the shell actually served by the active worker. This prevents reloading into A while B is deployed but not yet controlling the document.

Network-first was considered and not selected: keeping the prepared shell preserves offline deep-link startup without adding a second navigation cache or a network timeout. No worker unregistration, cache clearing, backend edits, pricing changes or design changes are part of this fix.

| Location/state | Behavior |
| --- | --- |
| `/`, `/events`, `/host`, `/discover`, `/collections`, `/about`, `/policies/*`, rendered public not-found | Reload automatically when the new worker's shell is available, unless input is unsaved |
| Event details and preview (quantity/seat selection and seat holds), unsubscribe | Defer even when hidden; reload after leaving for a safe route |
| Other nontransactional pages | Reload when hidden or on the next navigation after the update |
| Checkout, payments, orders/confirmation/recovery, ticket access/transfer | Defer even when hidden; reload after leaving for a safe route |
| Organizer, scanner, box office, admin/support, account/privacy, auth/invitation flows | Defer even when hidden; reload after leaving for a safe route |
| Registered unsaved draft or edited input/select/textarea/contenteditable | Defer; the existing draft navigation dialog still controls departure |
| Offline | Keep precached shell, `offline.html`, prepared manifests and pending IndexedDB scans |
| Same target revision already auto-reloaded in this tab session | Do not auto-reload again; denied session storage also defers |

Input tracking is conservative: submission is not treated as proof of a successful save. Unregistered controls stay protected until unmount. The existing pre-bundle chunk-error guard also consults the mounted application's reload policy.

## Acceptance ledger

All fixtures are synthetic and API responses are mocked. No real orders, payments, accounts, email or backend services are used. The production fixture replaces only the auth gate with a synthetic operator and seeds its scanner owner; no Clerk authentication is exercised. The two-build test uses actual production Vite builds and actual Chromium service workers on port 5234, with a visible test-only marker. A is revision `aaaa…` (40 characters), B is `bbbb…` (40 characters). The marker is injected only by `e2e-pwa/vite.config.js`.

| ID | Starting state, action and expected outcome | Result |
| --- | --- | --- |
| P01 | Install A on Home; deploy B; revisit once. B becomes visible without a second manual reload; revision guard is persisted | passed on committed implementation, Node 22.22.3 / Chromium |
| P02 | A checkout at 390px with a typed buyer name; activate B, including hidden-page event. Preserve document and input; navigate through the app to Home and see B | passed on committed implementation, Node 22.22.3 / Chromium |
| P03 | Prepare scanner on A; activate B without reloading its live document; go offline, reload, scan a valid synthetic ticket. Show admitted offline and one persisted pending scan | passed on committed implementation, Node 22.22.3 / Chromium |
| P04 | While offline, navigate directly to `/offline.html`; see its offline heading | passed on committed implementation, Node 22.22.3 / Chromium |
| P05 | Unit integration: deployed metadata B while worker still serves A; no premature reload. Protect registered drafts and defer checkout through safe navigation | passed in final full unit gate |
| P06 | Existing full Chromium suite, including scanner offline/sync and draft-departure journeys | passed: 152/152, zero failures; no flaky rerun needed |

Real iPhone Safari and installed-PWA behavior are not run: no connected phone is available. The 390px Chromium checkout run covers responsive browser behavior, not iOS lifecycle behavior. Production deployment is not performed; the lead owns merge and release verification.

## Repeatable production test

From `hafapass_frontend`, use Node >=22.12 and run `npm run test:e2e:pwa`. Leave port 5234 free. The test builds A, starts `vite preview`, installs A in isolated browser contexts, stops preview, builds B, starts preview again at the same origin, and performs P01–P04. It saves Home B, preserved checkout, offline admission and offline-page screenshots plus a JSON evidence attachment in Playwright's `test-results` directory. Contexts, preview processes and temporary builds are removed in `finally`.

## Initial failures and retests

- An early configuration set `injectRegister: false`, which stopped vite-plugin-pwa from setting `skipWaiting` and `clientsClaim`. The fixture caught the missing initial control; configuration now uses `injectRegister: 'auto'`, with registration supplied by the virtual import.
- The production checkout/scanner fixtures initially lacked fee terms and production authentication. Corrected the synthetic fee fixture and added a test-only authenticated operator. Production guards and fee code are unchanged.
- `page.route(...).fulfill(...)` can answer while a context is offline. The offline phase now removes all API interceptions before disconnecting, so reloads and scans use the actual service worker cache and IndexedDB.
- A Node 22 full-unit run overlapping production builds had 13 failures across existing scanner suites (manifest UI/availability assertions). Both affected suites passed on retest: 72/72. The final full-unit run passed, as recorded below.

Rollout limit: a pre-fix document already open on a device cannot execute this coordinator until it loads the new bundle. No forced client navigation is added to the worker, because it cannot know whether an old tab has unsaved work. The two-build test establishes the automatic behavior once this coordinator is installed.

- The clean Node 22 full-unit retest found one existing race: `admissionStore.legacy.test.jsx` asserted an asynchronous journal download immediately after clicking. The test now waits for the download; journal application code is unchanged.

Final production rerun: `npm run test:e2e:pwa` passed (1/1, 36.1 seconds) against the committed implementation. P01–P04 all passed. The scanner admitted a ticket offline, then survived a second offline reload with the pending count still at one. See [Home B](home-build-b.png), [checkout retained](checkout-preserved.png), [persisted offline scan](offline-scanner.png), [offline page](offline-html.png), and [test output](deploy-playwright.txt).

The fixture builds are test outputs. The normal build command uses the canonical application Vite config and the production auth gate.

## Final local gate

Implementation `0ce141df7e5df3cef292d0e83a28e8451a65797e`; macOS arm64, Node 22.22.3, Chromium. The following commit adds only this QA evidence.

- `npm run lint`: passed.
- `VITE_CLERK_PUBLISHABLE_KEY='' VITE_PUBLIC_WEB_URL='' VITE_API_URL='' npm test`: 182 files passed, one skipped; 2,014 tests passed, three skipped, zero failures. [Output](units.txt).
- `npm run build:no-translate`: passed; 176 precache entries. Verified `skipWaiting`, `clientsClaim`, embedded revision and absence of the old injected `registerSW.js`.
- `PLAYWRIGHT_PORT=5234 npx playwright test --workers=2`: 152 passed, zero failures (3.0 minutes). [Result lines](browser.txt). This affected-flow suite needed no flaky rerun.
- `npm run test:e2e:pwa`: one passed (36.1 seconds); actual two-build deploy and offline acceptance described above.
- `scripts/check_hygiene.sh`: passed. `ruby scripts/check_release_freeze.rb`: passed, local freeze inactive.
- Impeccable advisory on changed component paths: `[]` (no findings).

P01–P06 are accepted within the stated Chromium/API-simulation coverage. Real iPhone/installed-PWA coverage remains not run. No production deployment was attempted.

Task-owned preview/Vite servers, test-browser processes and collaborative preview tab were stopped/closed. No Rails server, simulator or container was started. No runtime resource is handed off; the branch and worktree remain for the lead's PR review and merge.

## Review round 2 (2026-10-27)

Inherited the sourced orientation above and refreshed `App.jsx`, `EventDetailPage.jsx`, `SeatSelector.jsx`, `UnsubscribePage.jsx`, coordinator, worker configuration, and PR review against clean head `bd6435c9`. Fetch confirmed `origin/main` remains `66e4f6a0`; no rebase is needed. Scope remains frontend deploy recovery and test/CI diagnostics. No production auth, backend, pricing, fee or policy logic changes are planned.

Agent-executed affected-flow acceptance adds:

- P07 (required): select a ticket quantity on A at 390px, activate B and hide the page; retain the A document and quantity, and complete a simulated order using that selection. Event-detail and preview routes remain protected throughout selection/seat-hold work; safe departure still permits an update.
- P08 (required): build with null revision metadata, load a fresh browser context, verify worker control, disconnect transport and open `offline.html`. Register the offline shell while disabling revision-based reloads. An invalid authoritative build revision forces the same null-metadata path as an archive without Git.
- P09 (required, unit): stalled JSON and HTML response bodies abort after five seconds; a subsequent reconnect can check again.
- P10 (required, unit): unsubscribe routes remain protected even when hidden, navigated or marked not-found.

Rerun P01–P06 and all requested engineering gates. Fixtures remain isolated and simulated; physical iPhone/installed-PWA coverage remains not run. Execution results follow below.


The first round-2 PWA run passed P08 but failed the new selection-to-checkout continuation: B's worker had removed A's precache, so A's lazy CheckoutPage/feeTerms URLs returned 404. The protected document correctly did not reload, but could not continue. [Failure output](round2-deploy-first-attempt.txt). The build now groups the buyer transaction pages into one lazy chunk, loading checkout, confirmation and ticket dependencies before selection begins. This retains the current task's modules in the document without retaining old worker caches indefinitely. Home does not preload the transaction chunk; opening a buyer transaction loads more code together (123.38 kB, 32.18 kB gzip in the verified build). The deploy test now completes a simulated order and verifies the retained line item after B activation.

### Finding dispositions

All eight findings are valid; none was dismissed as incorrect.

- `r4388759091` — Major / data integrity: protect event detail/preview before the generic hidden/navigation allowances. The regression test also required loading the buyer transaction pages through one lazy module to preserve continuation after worker cache cleanup.
- `r4388759103` — Major / availability: register the worker even with null revision metadata, suppress unconditional reloads, and disable revision polling in that case. Verified with a real production build and offline page.
- `r4388759070` — Minor / stability: keep JSON/text body consumption inside the five-second abort window; unit tests verify recovery from both stalled bodies.
- `r4388759083` — Minor / functional: protect unsubscribe root/token routes from hidden/navigation reloads.
- `r4388759007` — Minor / fixture security: clear the inherited Sentry upload token in every fixture build.
- `r4388759044` — Trivial / test reliability: wait two seconds for deferred callbacks before negative assertions, both after activation and after hiding.
- `r4388759058` — Trivial / diagnostics: generate a separate PWA HTML report, upload it on CI failure and ignore generated report JavaScript in Git/ESLint.
- Review summary `.github/workflows/ci.yml:129` — Major / CI supply chain (review marked unverified): pin both upload-artifact references to upstream v7 commit `cf430e030ddbb5b0abf93d22962f4752f3646cd9`, verified through the GitHub tag API. Other action dependencies are outside this finding's scope.

### Round-2 final local gate

Implementation commit: `54cae6baee1bafb0517180b9a073e43e40fd7b7a`. macOS arm64, Node 22.22.3, Chromium. The evidence-only commit follows. These runs use the same implementation source; PWA fixture revisions deliberately override the commit to exercise A, B and null identities.

- Lint: passed. [Output](round2-lint.txt).
- Required blank-env `npm test`: 182 files passed, one skipped; 2,022 tests passed, three skipped, zero failures (179.34s). [Output](round2-units.txt).
- `npm run build:no-translate`: passed; 166 precache entries. Transaction module is lazy, 123.38 kB / 32.18 kB gzip; generated Home HTML has no transaction preload. `skipWaiting` and `clientsClaim` remain enabled. [Output](round2-build.txt).
- `PLAYWRIGHT_PORT=5234 npx playwright test --workers=2`: 152 passed, zero failures (1.9m). No flaky rerun needed. This was rerun after the transaction module change. [Output](round2-browser.txt).
- Hygiene, inactive release-freeze contract, CI YAML parsing and diff whitespace checks: passed.
- Impeccable advisory on App and coordinator: `[]`. [Output](round2-impeccable.json).
- Final committed-source `npm run test:e2e:pwa`: 2 passed, zero failures (33.5s). [Output](round2-deploy-playwright.txt). P01–P04 and P07–P08 passed: Home reached B automatically; the hidden 390px selection retained A and completed a simulated order with exactly one selected ticket; the separate checkout retained its typed buyer until safe departure; the prepared scanner admitted offline and retained one pending scan after another offline reload; offline.html worked, including the null-revision build.
- P05 and P09–P10 passed in the full unit gate; P06 passed in the full Chromium gate. All required P01–P10 cases are accepted within the stated simulated-API/Chromium scope.

Round-2 visible evidence: [Home B](round2-home-build-b.png), [selection retained on A](round2-selection-preserved.png), [checkout retained](round2-checkout-preserved.png), [offline scan persisted](round2-offline-scanner.png), [offline page](round2-offline-html.png). Real iPhone Safari and installed-PWA coverage remain not run; no production deployment was attempted.

All task-owned Vite/preview/test-browser processes were cleaned after each phase. Lifecycle session `01a17d61-2b08-7543-b0ec-1a02b7e79813` reports no active owned resources. No Rails server, simulator, container or collaborative preview tab was started. No runtime handoff. Preserve the branch/worktree for the lead; DO NOT MERGE from this implementation task.
