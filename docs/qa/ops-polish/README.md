# Operational screen polish

## Brief and acceptance

2026-10-28; base `origin/main` = `3882764d`. HåfaPass sells event tickets in Guam. Organizers and door staff prepare scanners and admit guests; support staff look up orders and retry eligible messages; admins review operational queues. These screens stay light and calm. Fixes preserve authorization, scanner refusal/cache handling, delivery eligibility, and all pricing/policy behavior.

Sources: task brief; `src/pages/support/SupportPage.jsx`, `src/pages/dashboard/ScannerPage.jsx`, `src/pages/admin/adminOperations.js`, `src/App.jsx`, and the organizer base controller's exact 403 membership response (paths under `hafapass_frontend` except the controller). Brain Dump `work/shimizu-tech/company-positioning-and-project-review-2026-10-04.md` describes paid-launch/pilot gating; this work does not change those gates. Netlify deploys main; this PR must remain unmerged.

Acceptance: neutral legible shared disabled controls with no press scale/opacity transition; membership guidance with a real next step while other refusals stay red; no premature order results; truthful empty results; delivery actions and content reachable on phones; improve existing shared table sources only. No new motion.

## QA plan

Agent-executed affected-flow QA. Chromium at 375×812 and 1280×800. Fresh isolated Playwright contexts; synthetic API responses and signed manifests follow existing e2e contracts. Support's Clerk-only route gate is replaced only in the browser test, rendering the real page; production auth is unchanged and its unit suite runs. Signed-in Clerk, physical iPhone/Safari, live provider sends, and real payments are not covered.

| Case | Actions and expected outcome | Status |
| --- | --- | --- |
| OPS-1 Support initial | No orders heading, Search disabled and neutral, honest empty deliveries | Passed at both sizes; see final gate results below |
| OPS-2 Search | Enter query, submit, show no matching orders only on success; preserve query after error | Passed at both sizes; see final gate results below |
| OPS-3 Deliveries | Long recipient wraps; message/state/attempt/action visible; retry appears only for failed pre-provider messages; keyboard resend produces one mocked POST and queue status | Passed at both sizes; see final gate results below |
| OPS-4 Scanner membership | Exact membership 403 gives only heading, team guidance, workspace link and online status; no scanner tools. Unfiltered empty assignments get the same minimal state; arbitrary refusal stays red | Passed at both sizes; see final gate results below |
| OPS-5 Scanner assigned | Authorized preparation failure retains tools and a short device note; Device details opens; retry prepares a signed manifest; offline manual admission persists one queued scan | Passed at both sizes; see final gate results below |
| OPS-6 Disabled forms | Real PaymentForm with Stripe not ready, all five shared variants and Support submit; height/min-height ≥44px, padding and radius, full opacity, neutral colors, no hover/press feedback or opacity transition; enabled brand colors restore | Passed at both sizes; see final gate results below |
| OPS-7 Accessibility | Axe and no document overflow on changed fixture screens; full existing accessibility suite | Passed at both sizes; see final gate results below |
| OPS-8 Shared tables | Payout/dispute/refund shared helpers retain labels and wrap long content below md | Passed at both sizes; see final gate results below |

Before/after PNGs: `before/` and `after/`. Only synthetic fixture screens may be committed. Runtime: Vite 5237 with empty Clerk key and API URL targeting unused 3067 (all API requests mocked). Rails is unnecessary. No test database is created; any DB work would require confirming the exact `postgres://localhost/hafapass_ops_polish_test` target and dropping only that database.

## Changes and shared sources

- `src/index.css`: primary, teal, danger, secondary and ghost disabled states use neutral-200/neutral-600 at full opacity. Label contrast is 6.15:1. Shared state colors change immediately to avoid temporary low contrast when a control becomes enabled, including reduced motion and page-level transition/opacity utilities. Disabled controls have no press scale or shadow.
- `src/components/PaymentForm.jsx`: the real checkout Pay button now uses `btn-primary`; Stripe readiness/submission conditions are unchanged. `src/pages/dashboard/RefundsPage.jsx` uses `btn-danger` instead of forced background overrides.
- `src/pages/dashboard/ScannerPage.jsx`: only the exact membership response gets team guidance and a link to the existing `/dashboard` route. The original refusal/cache handling still runs; arbitrary refusals remain red. Empty assignments, offline setup and the unprepared camera have concrete next steps.
- `src/pages/support/SupportPage.jsx`: order results appear after a successful search with explicit empty-order copy; delivery rows stack below md, retain labelled fields, wrap long recipients/provider IDs, and expose 44px retry targets. Retry eligibility is unchanged. Empty/loading/error delivery states do not show an empty table.
- Existing `foldTable` / `foldCell` / `foldRow` helpers in `src/pages/admin/adminOperations.js`: sentence-case 14px headers, 14px phone labels, wrapping and shrinkable content. Consumers are Support, disputes, both payout tables, and `RefundReconciliationQueue` used by admin refund issues and organizer refunds. The existing stacked layout remains. Page-local tables (including attendee/order/user tables) have no shared source and were left outside this focused pass.
- Sweep: shared workspace headers are not table headers; operational red policy holds and API failures describe real restrictions, so their severity remains. No other shared source was found using red errors for ordinary setup guidance.

Public Navbar and buyer page files, backend, pricing, fees, `policies.yml` and policy logic are untouched. No deployment is requested.

## Evidence

Every required Support/scanner/payment screen has a before/after PNG at both sizes. `admin-shared-table-{375,1280}.png` adds after-only evidence for the shared helper regression. Full-page images can be taller than the viewport; the viewport itself is 375×812 or 1280×800.

Before Support/scanner images were taken on base `3882764d` before implementation. The payment harness initially failed to load because the Vite React refresh preamble/default ReactDOM import were missing; its corrected baseline uses exact `git show 3882764d` copies of `src/index.css` and `src/components/PaymentForm.jsx` as temporary Vite modules. Those copies were removed. No signed-in/customer data is present.

To reproduce final screenshots from `hafapass_frontend` with a fixture-only Vite server on 5237:

```sh
PLAYWRIGHT_PORT=5237 OPS_POLISH_CAPTURE=1 npx playwright test e2e/ops-polish.spec.js --workers=2
```

The payment before capture additionally expects base copies at `src/ops-baseline.css` and `src/components/OpsBaselinePaymentForm.jsx`, then uses `OPS_POLISH_PHASE=before` and `--grep 'shared disabled variants'`. Remove those temporary modules afterward.

The first full browser gate caught the disabled-to-enabled color interpolation in an admin dialog; that defect was fixed in the shared transition rule. The legacy search regression now asserts neutral disabled colors rather than 50% opacity, and still samples enabled frames in both reduced-motion modes. The focused 16-case regression suite passed after the fix. The first unit run's two failures expected the old scanner message; those assertions were updated without changing their access/pending-scan checks.

The collaborative browser failed twice with `Preview automation snapshot timed out after 15000ms`; it was closed and evidence came from the repository Playwright workflow. This is browser fixture coverage, not physical iPhone or signed-in Clerk acceptance.

## Round 1 gate results

Source under test: `27922b3de5d7706fc72e206682188cd633f2fb40`; the follow-up commit only records QA/review status. Node 22.22.3 on Leon’s Mac.

- Lint: passed (`npm run lint`).
- Units: **2023 passed, 3 skipped**; **182 files passed, 1 skipped**. Command: `VITE_CLERK_PUBLISHABLE_KEY='' VITE_PUBLIC_WEB_URL='' VITE_API_URL='' npm test -- --maxWorkers=1 --testTimeout=15000`. The earlier full run passed 2021 tests but failed two old scanner-copy expectations; the next concurrent run was stopped after an old refund-class assertion and two timing failures. The assertions were corrected, and the final single-worker run avoided concurrent browser load; assertion timeouts were unchanged. Existing jsdom XHR warning output did not produce test failures.
- Build: passed (`npm run build:no-translate`), including service worker generation.
- Full Playwright: **162 passed, zero failures**, Chromium; no `event-day` retry needed. Includes the 10-case ops fixture file and the existing axe/keyboard suite.
- Changed-screen axe: **zero violations** on Support initial/no-results/deliveries, scanner no-membership/assigned, payment/button fixture and shared admin dispute table at both viewports.
- Impeccable 4.6.0 detect on all six changed production UI paths: passed, JSON `[]`.
- Runtime QA resources: Vite 5237, all browser workers, the collaborative tab and unit worker tree are cleaned. Final lifecycle status: no active owned resources. Rails and a database were never started/created. A read-only query of `pg_database` confirmed `hafapass_ops_polish_test` is absent; no database needed dropping.

Static JSX inventory found 212 disabled/aria-disabled controls with explicit shared button classes across 75 production files, including 27 legacy opacity utilities. The shared state selector overrides those utilities; no forced `!bg-*`/`!text-*` overrides remain on those controls after moving the refund confirm to `btn-danger`. Dynamic class names are covered by the shared CSS and runtime fixture checks rather than this static count.

CodeRabbit automatic review reached the OSS capacity limit (reported next capacity in about 41 minutes). One `@coderabbitai review` retry was requested in PR #171. At the review audit there were no review findings/threads; the success-labelled CodeRabbit status is a rate-limited skip, not a completed review. CodeRabbit is a required main-branch gate. The PR remains held, and further review handling belongs to the parent/continuing session once capacity is available.

No live deployment or signed-in Clerk/physical-iPhone acceptance is claimed. PR must remain unmerged.

## Round 2 review fixes

2026-10-28; implementation source `537edffcdcede94c44c7b7c159d8119f5a78863f`; fetched `origin/main` remains `3882764d`, so no rebase was needed. The app brief, deployment hold and coverage limits above still apply. This is agent-executed affected-flow QA with fresh synthetic browser fixtures at 375×812 and 1280×800.

1. **Shared buttons:** the new computed-style regression first failed at both widths with `.btn-teal` min-height `0`. A PostCSS/Tailwind compilation confirmed that the original source emitted no standalone `.btn-teal` rules: no production JSX currently contains that literal class, so Tailwind pruned its component definition. The global disabled override still colored the bare element. Safelisting the five shared semantic variants in `tailwind.config.js` retains their full `@apply` expansion and variant colors. The regression checks every disabled variant’s height, minimum height, padding, radius, colors and press state; it also checks enabled primary/teal/danger colors. The shared CSS itself remains unchanged from round 1.
2. **Scanner access:** the UI uses the existing exact membership refusal, scan-filtered assignment list and resolved selected event. Only a confirmed empty unfiltered list or the exact membership refusal, without a resolved assignment or ready grant, shows the minimal guidance state. Search filtering and offline-only restore do not imply no authority. The existing refusal, cache quarantine, journal retention, direct event resolution and offline verification pipelines are unchanged. Assigned users retain tools on setup failure and can retry verification. Device readiness gets a short staff explanation; expiry, export/recovery, account revocation and reset details sit inside Device details. Door-staff text does not name Clerk. Unnamed ready devices now say Device ready.
3. **Deliveries:** the endpoint queues the original failed message, and rejects ineligible retries (`MessageDelivery#retryable?` also enforces its provider replay window). The UI now offers Retry delivery only on failed rows without a provider ID; delivered, queued and provider-accepted failed rows have no retry action. Server eligibility enforcement is unchanged. Unit coverage checks those four states; browser coverage verifies one keyboard-triggered POST and queue confirmation.

The first focused browser run passed 9/10; its phone no-authority assertion mistakenly included the workspace menu button. Scoping the assertion to main content fixed the fixture. The corrected focused run passed 10/10 with zero axe violations. The collaborative browser again failed twice with `Preview automation snapshot timed out after 15000ms.` Its owned tab was closed; screenshots and interaction evidence use the repository Playwright workflow.

Refreshed evidence under `after/`, at **both 375 and 1280**:

- `disabled-payment-and-forms-{width}.png`
- `scanner-no-membership-{width}.png` (no authority)
- `scanner-authorized-unprepared-{width}.png` (assignment verified; synthetic preparation outage)
- `scanner-ready-{width}.png` and the existing `scanner-assigned-{width}.png` (verified signed manifest)
- `support-deliveries-{width}.png`

The first full browser run passed 160 cases but failed the two disabled-variant cases: Vite had retained the pre-safelist Tailwind configuration. The production CSS contained all three standalone teal rules; the running server contained none. After restarting only the owned Vite tree, a direct CSS check found the three rules on the fresh server. The complete suite was rerun from fresh contexts.

Round 2 gates on `537edffc`:

- Lint: passed (`npm run lint`).
- Build: passed (`npm run build:no-translate`), including service worker generation. The built CSS retains the teal component rules.
- Full Playwright: **162 passed, zero failures** on the fresh server; no `event-day` retry. All ten ops fixture cases passed, including hidden no-authority tools, assigned preparation recovery, offline saved admission, truthful delivery retry, and disabled dimensions/enabled colors.
- Axe: **zero violations**, including all affected fixture screens at both requested widths and the full existing accessibility/keyboard suite. No document overflow in the changed-screen fixtures. Eight affected-flow cases in the matrix above are accepted at both required viewport sizes.
- Impeccable 4.6.0: JSON **[]** across all six production UI files in the PR plus `tailwind.config.js`.
- Units: **2024 passed, 3 skipped; 182 files passed, 1 skipped**. Final command: `VITE_CLERK_PUBLISHABLE_KEY='' VITE_PUBLIC_WEB_URL='' VITE_API_URL='' npm test -- --testTimeout=15000`, using the configured two workers with no browser/server load. Existing jsdom XHR warnings did not fail tests. The first single-worker run was stopped after the new support fixture failed: its default router path was `/`, where SupportPage correctly renders nothing. Setting the fixture route to `/support` fixed it; all five SupportPage units then passed before the complete final run.

Cleanup: the owned collaborative tab, Playwright workers, Vite 5237 and unit worker trees are stopped. Lifecycle session `01a17f69-cbd7-7893-9e7b-34a5b7f2d5ea` reports no active owned resources. No Rails server or database was started. Borrowed/protected services are unchanged.

Logs: `/tmp/hafapass-ops-r2-{lint,units,build,playwright}.log` and `/tmp/hafapass-ops-r2-impeccable.json`. Initial failure logs remain separately named. Final GitHub review/check state is in the local handoff; CodeRabbit remains a required gate and is not claimed complete. The PR must remain unmerged. The round 1 results are historical and do not establish round 2 acceptance.

## Round 3 independent-review fixes

2026-10-28; implementation source `51ce4adf36b32f3c53004443439882c303bf2a84`. The clean starting head was `21a304d3`. Fetched and merged `origin/main` at `81abf68c` in `6ee0ea19` before implementation; that upstream change only adjusts a backend spec. This round adds no backend changes. The app brief and paid-launch/deployment hold above still apply. PR #171 must remain unmerged.

Agent-executed affected-flow acceptance uses the same fresh synthetic API fixtures, signed manifests and isolated Chromium contexts at 375×812 and 1280×800. The scanner fixture prepares an authorized device, goes offline, admits a ticket, reconnects into the exact membership refusal, exports the retained journal through the visible button, parses the downloaded file, and confirms the original queued action remains in IndexedDB. No Rails server, database, provider send or payment is needed. Signed-in Clerk, physical Safari/iPhone, assistive-technology testing and live services remain outside this acceptance.

1. **Refused scanner recovery:** the minimal no-authority screen mounts `SavedJournalExports` in recovery mode. Its existing inventory and export checks stay scoped to the current staff account and binding. A saved journal shows a warning to preserve browser data, use the original account and share the export privately with the manager. With no saved entries, the screen keeps only membership guidance and status. The refusal still withdraws event access; it does not restore scanning. `OperationalDiscovery.test.jsx` now checks the reachable warning/export after prepared-scanner membership refusal, alongside grant removal and journal retention. Export-component coverage also checks the recovery warning and exclusion of another account's journal.
2. **Accessible stacked tables:** `foldTable` visually hides the mobile header with Tailwind's `sr-only` technique and restores it at `md`, instead of `display:none`. The native table/header/row/cell elements remain. Every shared consumer has `scope="col"`: Support, disputes, payouts, balance adjustments, and the refund queue used by both admin and organizer pages. Browser assertions query each column header by role/name at both widths and verify the payout/refund rows and cells. Axe runs on every affected screen, including 375px. Support units also assert column-header roles and scope.
3. **Retry follow-up:** leave the current failed-without-provider-ID rule unchanged. `delivery_json` provides some dates but omits `provider_attempted_at` and the unknown-outcome marker; recipient suppression depends on delivery history beyond this row. These fields cannot reproduce `MessageDelivery#retryable?` and the controller's suppression check reliably. Follow-up: **server should expose a retry-eligibility flag + reason**. The server remains authoritative; this PR changes no backend behavior.

Acceptance: OPS-1 through OPS-8 were rerun at both required sizes and passed. OPS-8 now includes accessible column headers across all six rendered table screens (Support, disputes, payouts, adjustments, admin refunds, organizer refunds). New required OPS-9, refused scanner with saved scans, passed at both sizes: scanning tools absent, warning/export reachable, downloaded journal contains the admission, original queue retained. Nine affected-flow cases accepted; physical-device and signed-in coverage limits above remain.

The focused browser run passed **12/12**. Screenshots were refreshed and visually inspected. New evidence under `after/`: `scanner-refused-saved-scans-{375,1280}.png`, `payouts-table-{375,1280}.png`, `adjustments-table-{375,1280}.png`, `admin-refund-table-{375,1280}.png`, and `organizer-refund-table-{375,1280}.png`. Existing Support, scanner, disabled-form and dispute captures were refreshed by the same run. Screenshot data is synthetic.

The collaborative preview tab opened, but two snapshot attempts failed with `Preview automation snapshot timed out after 15000ms.` It was closed; repository Playwright supplied the interaction and screenshot evidence. An initial launch used the shell's Node 22.0.0; both owned unit/server trees were stopped and restarted under Node **22.22.3** before the reported gates. No interrupted run is counted as a pass.

Round 3 local gates on the implementation source above:

- Lint: passed (`npm run lint`).
- Build: passed (`npm run build:no-translate`), including service-worker generation.
- Full Playwright: **164 passed, zero failures**, Chromium, 2.9 minutes. No flaky-spec rerun was needed. This includes the 12 operational fixture tests and the existing axe/keyboard suite.
- PWA: **2 passed**, Chromium, 1.5 minutes. Verified production service-worker upgrades and offline work preservation.
- Axe: zero violations on all changed fixture screens at both required widths; every shared table consumer is included at 375px. No document overflow on these screens.
- Impeccable 4.6.0: JSON `[]` across all 11 production UI/config paths changed by this PR, including the earlier button/payment changes.
- Units: **2024 passed, 3 skipped; 182 files passed, 1 skipped**, zero failures, 144.39 seconds. Final command: `VITE_CLERK_PUBLISHABLE_KEY='' VITE_PUBLIC_WEB_URL='' VITE_API_URL='' npm test` (configured maxWorkers=2), after browser cleanup. The first complete run had 2023 passed, 1 failed and 3 skipped. The failure was the existing account-transition test's wait for saved scanner readiness at `ServiceCheck.accountTransition.test.jsx:59` while browser/PWA gates were running. That file passed 6/6 in an isolated rerun, and the complete suite then passed without source or timeout changes. The initial failure remains in `/tmp/hafapass-ops-r3-units.log`. Existing jsdom XHR warnings did not fail the final run.

Logs: `/tmp/hafapass-ops-r3-{lint,build,focused,playwright,pwa,units,units-final,account-transition}.log`, `/tmp/hafapass-ops-r3-impeccable.json`. CodeRabbit is a required main-branch check; a success-labelled skip does not establish a completed review. The final pushed head, round 3 review request/response and CI snapshot are recorded in the local round 3 handoff and returned to the lead. This implementation child does not monitor CI or merge the PR.

Cleanup: lifecycle session `01a17f9a-2255-7a53-b531-72492f633e5f` reports no active owned resources. Owned Vite 5237, browser/unit/PWA worker trees, PWA fixture servers and the collaborative preview tab are closed/stopped. No Rails server or database was created, so there is no throwaway database to drop. No runtime handoffs or unresolved ownership. Borrowed/protected services remain unchanged.
