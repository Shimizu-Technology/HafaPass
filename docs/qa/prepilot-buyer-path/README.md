# Pre-pilot buyer path

Implementation and affected-flow QA, executed by the agent on October 27, 2026.
Base: `c55601ad` (`origin/main` verified with fetch before implementation).

## Context and acceptance

HåfaPass serves Guam buyers, often on phones and without an account, plus organizers and admins. The owner’s October 27 brief establishes production launch on October 21 and no public pilot event yet. The older Brain Dump `work/shimizu-tech/future-builds.md` describes the same ticketing/QR purpose but its May launch status is stale. Current implementation sources: `HomePage.jsx`, shared Tailwind/button tokens, `docs/PRODUCTION_CUTOVER.md`, `docs/TRANSLATIONS.md`, and the buyer pages. Web main auto-deploys on Netlify; the API is on Render. This PR is held for review and does not change production.

The buyer journey must retain guest access, all-in server prices, seat/waitlist/private-preview behavior, confirmation recovery, and immediate QR access while matching Home’s light surfaces and typography. Organizer artwork remains clean, with its focal point and 16:9 crop. The door ticket keeps a flat dark surround for contrast. Controls retain existing press feedback; card images no longer zoom. Reduced motion stops animated travel and retains short color/opacity feedback. A scannable ticket holds a screen wake lock when the browser allows it.

Policies, pricing calculations, fee rules, and backend code are untouched. English display labels identify the HåfaPass service fee; committed translations remain valid and no paid translation is run.

## Environment and fixtures

Local Rails 3061 and Vite 5231; isolated PostgreSQL database `hafapass_prepilot_a`, checked with `select current_database()` before fixture writes. Fixtures use an organization, owner membership, verified organizer, and published cover/no-cover/long-title/sold-out/free events. Payment mode is `simulate`; guest address is `prepilot-guest@example.invalid`. No real money or external email delivery. The cover upload URL is intercepted in Chromium with the repository’s `public/og-host.jpg` as synthetic artwork; crop/focal behavior uses the real component. This is a layout fixture, not an organizer’s actual artwork.

T3 preview snapshot timed out twice; browser QA uses local Chromium through Playwright. Captures are signed-out public/guest views with disposable synthetic order/QR data. Phone dimensions describe resized desktop Chromium, not physical-device validation. Clerk sign-in is unavailable because email verification cannot be completed here.

The initial borrowed `node_modules` link blocked font files in Vite. Those initial captures were superseded after installing this worktree’s locked dependencies; retained evidence uses loaded local fonts.

## Scenario ledger

| ID | Required scenario and expected outcome | Coverage | Result |
| --- | --- | --- | --- |
| B1 | Cover, no cover, and long title: read event details, select tickets, no horizontal overflow, preserve focal point | 375×812, 1280×800 | Passed |
| B2 | Sold-out event: no purchase quantity controls; waitlist remains available | 375×812, 1280×800 | Passed |
| B3 | Free event: select and complete guest order, zero total and usable ticket | 375×812, 1280×800 | Passed |
| B4 | Paid guest: select ticket, review $20.00 subtotal + $2.00 fee = $22.00; accept terms, simulate payment, confirm saved completed order and usable QR | 375×812, 1280×800 | Passed |
| B5 | Keyboard: visible focus, ticket selection, validation/recovery, accessible QR | 375×812, 1280×800 | Passed |
| B6 | Reduced motion: no card travel/pulse, short color transitions, immediately usable QR | 375×812, 1280×800 | Passed |
| B7 | Workspace header: public-site link remains one line, all maximum-role links fit | 1024, 1280, 1440 | Passed with synthetic maximum-role links and a 40px account-control stub; real Clerk session blocked |
| B8 | Wake lock: request, hide/release, visible/reacquire, unmount and pending-request cleanup, denial without QR failure | Unit tests with mocked browser API | Passed |

## Evidence

`before/` and `after/`: event states, checkout, confirmation, ticket at 375 and 1280. Before images use base UI; after images use this PR’s implementation. Only signed-out/public captures are committed. Authenticated workspace/My Tickets functionality is covered with synthetic browser fixtures and unit tests where available; no real Clerk acceptance is claimed.

## Validation and cleanup

- Lint: passed, zero warnings.
- `build:no-translate` and `build`: passed; the build explicitly skipped translation because GT credentials were absent. Locale JSON validation passed.
- Focused Ticket/Checkout/Confirmation unit tests: 112 passed, including all four new wake-lock cases.
- Full unit runs: first 1,967 passed / 1 failed / 3 skipped (journal export); second 1,966 passed / 2 failed / 3 skipped (draft-editor refresh). Both affected unmodified suites pass in isolation (11 and 13 tests). Final serial run (`npm test -- --maxWorkers=1`, with the three requested Vite variables cleared): **1,968 passed / 3 skipped / zero failures**, 179 passed files and one skipped file (266.28 seconds). The earlier failures did not recur after browser work stopped and the worker count was reduced.
- Final full browser run: 122 passed / 14 failed. All failures are contrast checks in organizer/admin screens. Buyer-only follow-up: 11 passed.
- Impeccable 4.6 advisory: `[]` (no findings).
- Real Clerk authentication and physical-device testing: not run, as described above. Provider payment and email are simulated, not delivered.

### Browser gate blocker

Removing the global decorative body gradients exposes existing low-contrast text outside this worker’s file ownership. This is a gate failure, not a clean browser suite. Examples are `CoverImageUpload.jsx:130` (12px neutral-400 helper copy) and `AdminDashboardPage.jsx:229,260` (14px neutral-400 empty-state copy). Their measured contrast is roughly 2.4–2.5:1 against the light surfaces. Some verification-input checks also catch transient low contrast during a color transition.

A separate detached checkout at `c55601ad` ran the three affected suites: **29 passed** with the original global background; removing only the body gradient declarations produced **17 passed / 12 failed**, reproducing the persistent helper/empty-state failures. The original gradient causes Axe to skip checks it cannot resolve. This PR keeps the requested flat background and reports the uncovered contrast debt instead of modifying components outside the assigned scope. Parent action: assign those components for contrast fixes, rerun the full browser gate, and keep this PR unmerged until gates and review are resolved.

### Saved outcomes and cleanup

The agent verified completed orders directly in the isolated database: paid orders persisted at 2,000 cents subtotal + 200 cents fee = 2,200 cents total, with one issued ticket; free orders persisted at zero subtotal/fee/total with one issued ticket. The free-order checks also reloaded confirmation before opening the QR.

Rails 3061, Vite 5231, and the baseline Vite 5239 were stopped. The database was dropped and its absence independently checked in `pg_database`. The temporary baseline worktree was removed. Browser contexts close in `finally`; final lifecycle status reports **no active owned resources**. All task-owned runtime resources are cleaned. No runtime handoff is intended.


## Review handoff

The tested application source is committed as `0a94f4c74c7c64d0532944f2d548fe989a723ac0`; this evidence update changes documentation only. The Vite captures/builds used that same implementation tree with base revision metadata, before the code commit; they are local QA, not release verification.

PR: https://github.com/Shimizu-Technology/HafaPass/pull/162 — **do not merge**. At the one status snapshot, CodeRabbit was processing all 17 non-image files at the implementation commit and had no posted inline findings yet. Freeze contract, backend quality/security, repository hygiene, header/redirect checks and Netlify preview passed; RSpec, frontend and browser CI were still running. That snapshot is not final-head approval. CodeRabbit is a required branch-protection gate. As a delegated worker, this agent returns pending review/check state to the parent instead of watching or polling the PR.

Next: the parent should inspect CodeRabbit and final-head checks, handle material review findings, and assign the out-of-scope contrast fixes before claiming readiness. No reviewer finding has been dismissed or marked resolved without inspection. Real Clerk sign-in, native wake-lock hardware behavior, and physical-phone testing remain unverified. The held implementation branch/worktree are preserved; the temporary comparison worktree is gone.
