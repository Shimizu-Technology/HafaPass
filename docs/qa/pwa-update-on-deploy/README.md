# Deploy update recovery QA

Agent-executed affected-flow QA, 2026-10-27. Base: `origin/main` at `66e4f6a0`. Implementation commit: `0ce141df` (final evidence-only commit follows).

HåfaPass serves event buyers and organizers, including door staff whose prepared scanner must continue without network access. The current project overview describes ticketing, offline admission, refunds, settlements and operational roles (Brain Dump: `work/shimizu-tech/company-positioning-and-project-review-2026-10-04.md`, HafaPass row). Verified implementation sources: `src/App.jsx`, `src/ServiceCheck.jsx`, `src/components/DraftNavigationProvider.jsx`, `src/utils/admissionStore.js`, `vite.config.js`, and `config/releaseMetadata.js` under `hafapass_frontend`.

The prior worker precached `index.html` and activated updates, while the injected registration script did not reload the already-rendered document. The fix retains the offline navigation shell and uses the virtual registration module's `onNeedReload` hook. The installed vite-plugin-pwa 1.3.0 supports overriding the reload callback; see [plugin source](https://github.com/vite-pwa/vite-plugin-pwa/blob/main/src/client/build/register.ts). A no-store `/release.json` check requests worker updates on startup, reconnect, foreground and every minute. Before scheduling a reload, the coordinator reads the revision embedded by the existing release-metadata plugin in the shell actually served by the active worker. This prevents reloading into A while B is deployed but not yet controlling the document.

Network-first was considered and not selected: keeping the prepared shell preserves offline deep-link startup without adding a second navigation cache or a network timeout. No worker unregistration, cache clearing, backend edits, pricing changes or design changes are part of this fix.

| Location/state | Behavior |
| --- | --- |
| `/`, `/events`, `/host`, `/discover`, `/collections`, `/about`, `/policies/*`, rendered public not-found | Reload automatically when the new worker's shell is available, unless input is unsaved |
| Public detail and other nontransactional pages | Reload when hidden or on the next navigation after the update |
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
