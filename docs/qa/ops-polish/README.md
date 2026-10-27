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
| OPS-3 Deliveries | Long recipient wraps; message/state/attempt/action visible; only failed unsent message retry enabled; keyboard resend produces one mocked POST and queue status | Passed at both sizes; see final gate results below |
| OPS-4 Scanner membership | Exact membership 403 gives neutral guidance, workspace link, disabled camera; arbitrary refusal stays red | Passed at both sizes; see final gate results below |
| OPS-5 Scanner assigned | Device and signed manifest prepare; offline manual admission persists one queued scan | Passed at both sizes; see final gate results below |
| OPS-6 Disabled forms | Real PaymentForm with Stripe not ready, all five shared variants and Support submit; full opacity, neutral colors, no hover/press feedback or opacity transition | Passed at both sizes; see final gate results below |
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

## Final gate results

- Lint: passed (`npm run lint`).
- Units: final single-worker run in progress, with the required three Vite environment variables empty. The earlier full run passed 2021 tests but failed two old scanner-copy expectations; the next concurrent run was stopped after an old refund-class assertion and two timing failures. The class assertion is updated. The final run uses `--maxWorkers=1 --testTimeout=15000` to avoid the concurrent browser load; assertion timeouts are unchanged.
- Build: passed (`npm run build:no-translate`), including service worker generation.
- Full Playwright: **162 passed, zero failures**, Chromium; no `event-day` retry needed. Includes the 10-case ops fixture file and the existing axe/keyboard suite.
- Changed-screen axe: **zero violations** on Support initial/no-results/deliveries, scanner no-membership/assigned, payment/button fixture and shared admin dispute table at both viewports.
- Impeccable 4.6.0 detect on all six changed production UI paths: passed, JSON `[]`.
- Runtime QA resources: Vite 5237 and browser workers closed; collaborative tab closed. Final unit worker tree will be cleaned when it completes. Rails and a database were never started/created.

No live deployment or signed-in Clerk/physical-iPhone acceptance is claimed. PR must remain unmerged.
