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

### Round 1 browser gate blocker (historical)

This records the initial failed gate. Round 2 below expands ownership and records the fixes and retest.

Removing the global decorative body gradients exposes existing low-contrast text outside this worker’s file ownership. This is a gate failure, not a clean browser suite. Examples are `CoverImageUpload.jsx:130` (12px neutral-400 helper copy) and `AdminDashboardPage.jsx:229,260` (14px neutral-400 empty-state copy). Their measured contrast is roughly 2.4–2.5:1 against the light surfaces. Some verification-input checks also catch transient low contrast during a color transition.

A separate detached checkout at `c55601ad` ran the three affected suites: **29 passed** with the original global background; removing only the body gradient declarations produced **17 passed / 12 failed**, reproducing the persistent helper/empty-state failures. The original gradient causes Axe to skip checks it cannot resolve. This PR keeps the requested flat background and reports the uncovered contrast debt instead of modifying components outside the assigned scope. Parent action: assign those components for contrast fixes, rerun the full browser gate, and keep this PR unmerged until gates and review are resolved.

### Saved outcomes and cleanup

The agent verified completed orders directly in the isolated database: paid orders persisted at 2,000 cents subtotal + 200 cents fee = 2,200 cents total, with one issued ticket; free orders persisted at zero subtotal/fee/total with one issued ticket. The free-order checks also reloaded confirmation before opening the QR.

Rails 3061, Vite 5231, and the baseline Vite 5239 were stopped. The database was dropped and its absence independently checked in `pg_database`. The temporary baseline worktree was removed. Browser contexts close in `finally`; final lifecycle status reports **no active owned resources**. All task-owned runtime resources are cleaned. No runtime handoff is intended.


## Round 1 review handoff (superseded below)

The tested application source is committed as `0a94f4c74c7c64d0532944f2d548fe989a723ac0`; this evidence update changes documentation only. The Vite captures/builds used that same implementation tree with base revision metadata, before the code commit; they are local QA, not release verification.

PR: https://github.com/Shimizu-Technology/HafaPass/pull/162 — **do not merge**. At the one status snapshot, CodeRabbit was processing all 17 non-image files at the implementation commit and had no posted inline findings yet. Freeze contract, backend quality/security, repository hygiene, header/redirect checks and Netlify preview passed; RSpec, frontend and browser CI were still running. That snapshot is not final-head approval. CodeRabbit is a required branch-protection gate. As a delegated worker, this agent returns pending review/check state to the parent instead of watching or polling the PR.

Next: the parent should inspect CodeRabbit and final-head checks, handle material review findings, and assign the out-of-scope contrast fixes before claiming readiness. No reviewer finding has been dismissed or marked resolved without inspection. Real Clerk sign-in, native wake-lock hardware behavior, and physical-phone testing remain unverified. The held implementation branch/worktree are preserved; the temporary comparison worktree is gone.


## Round 2: contrast and review follow-up

Scope was expanded by the lead on October 27 to correct the contrast failures exposed by the flat background, including organizer/admin components. The existing app brief and buyer invariants above remain applicable at base `c55601ad`; fetch confirmed main unchanged. No backend, policies, fee calculations, Home, Host, Footer, or Discover files are changed in this round.

The agent executes affected-flow QA using isolated browser API fixtures, plus the full frontend gate. These fixtures simulate organizer/admin identity and saved responses; they do not exercise real Clerk authentication or a live database. No database is created in round 2. Required cases:

| ID | Starting state, actions, expected outcome | Coverage | Result |
| --- | --- | --- | --- |
| R2-1 | Synthetic organizer event: open editor, create flow, and ticket controls; helper/placeholder copy stays readable and existing save/keyboard behavior passes | Chromium 375 and desktop; full accessibility suite | Passed in both full browser runs |
| R2-2 | Synthetic admin: open dashboard with empty recent lists and verification/payout review; read empty states and complete existing approval/recovery flows | Chromium 375 and 1280 | Passed in both full browser runs |
| R2-3 | Organizer search: hold a refresh in its disabled state, complete the response, sample every rendered enabled frame; opacity must immediately be 1 and text remain neutral-700 | Reduced and normal motion | Passed in final full browser run |
| R2-5 | Admin custom search field without `.input`: inspect placeholder before/after focus; both must use readable neutral-600 | Normal and reduced motion | Passed in final full browser run |
| R2-4 | Authorized QR: dispatch unexpected wake-lock release while visible; retry once after 1 second, stop after a second release, cancel pending retry on unmount | Mock browser API unit tests | Passed; included in full serial unit result below |

All meaningful light-surface `text-neutral-400` copy found in this pass uses `text-content-muted` (`#475569`, the neutral-600 role); decorative icons, dark-surface text, and disabled controls retain their existing colors. Shared input placeholders and the base default for custom input/textarea placeholders use the same readable role. An additional spot-check found that admin custom search fields bypass `.input`; the base default corrects their Tailwind preflight placeholder color too. Explicit dark-surface placeholder utilities remain applicable. At least 7.2:1 contrast is available against the existing white/surface backgrounds.

The transient report was not a verification-input text-color animation: round-1 failure HTML identifies the organizer **Search events** `.btn-secondary`. `OperationalSearch` disables it during loading. The global reduced-motion `!important` transition list included opacity and overrode the shared-button rule, so the enabled button remained faded during the 150 ms transition from 0.5 to 1. The reduced-motion control override now excludes opacity and text color; inputs transition only border/shadow. Other elements retain short opacity/color feedback. Existing axe rules and timing are unchanged. A controlled reproduction that reapplied the old transition list failed the new frame regression with enabled opacity `0.5` instead of `1`; the throwaway spec was removed.

Visual spot-checks: organizer editor and admin dashboard inspected at 375 and 1280. Helper/empty-state hierarchy and layout are readable with no new overflow. Synthetic signed-in captures remain only in `/tmp/hafapass-verification-{edit,admin}-{375,1280}.png`; none are committed. T3 preview snapshot failed twice with `Preview automation snapshot timed out after 15000ms.` and its owned tab was closed; local Playwright provided the browser evidence.

Initial round-2 full Playwright run: **136 passed / zero failures** (1.6 minutes). Final full Playwright gate including two frame-level regressions and custom-field placeholder assertions: **138 passed / zero failures** (1.8 minutes), on supported Node 22.22.3. The known offline-scanner flake did not occur. Lint, `build:no-translate`, and Impeccable 4.6 (`[]`) passed. Full serial unit run: **1,970 passed / 3 skipped / zero failures**, 179 passed files and one skipped file (220.14 seconds). It uses Node 22.22.3 with Vite auth/API/support/locale environment values cleared. The two added tests cover bounded unexpected-release retry and cancellation on QR unmount. Two jsdom XHR diagnostics were logged; Vitest exited 0.

CodeRabbit on the incoming head has four findings: validation evidence (material, addressed by final results), contrast (material, fixed), reduced-motion opacity (valid, fixed), and unexpected wake-lock release (valid, bounded retry added with two tests). Each finding is addressed in this round. Review replies/resolutions and the final-head required-check snapshot belong in the local handoff after pushing; final approval is not inferred from local tests. The lead owns monitoring and merge. Required checks are Backend / RSpec, Backend / Quality and security, Frontend / Test, build, and security, Browser / Service recovery smoke tests, Repository / Secret and debug hygiene, Release / Freeze contract, and CodeRabbit.


### Round 2 contrast changes

Line references are in the revised source. Each `text-neutral-400` below became `text-content-muted`; the shared placeholder uses `placeholder:text-content-muted`. Custom-field placeholders now override Tailwind preflight’s `#9ca3af` with the same readable role.

| File | Lines | Meaningful copy |
| --- | --- | --- |
| `src/components/CoverImageUpload.jsx` | 130 | Image-format/size helper |
| `src/components/EventCard.jsx` | 114 | Completed-event status |
| `src/components/PricingTiersCRUD.jsx` | 244, 280 | Empty tiers and sold count |
| `src/components/TicketTypeCRUD.jsx` | 286 | Sale date range |
| `src/pages/admin/AdminDashboardPage.jsx` | 229, 260 | Empty recent events/orders |
| `src/pages/admin/AdminEventsPage.jsx` | 249 | Empty event search |
| `src/pages/admin/AdminOrdersPage.jsx` | 144, 211, 222 | Ledger labels, empty entitlements, empty order search |
| `src/pages/dashboard/EventAnalyticsPage.jsx` | 236, 266, 414 | Total, check-in count, order timestamp |
| `src/index.css` | 32–35, 114 | Custom-field default and shared input placeholder |


## Round 3: desktop purchasing beside the title

October 27, 2026. Incoming head `af8fb3db`; `git fetch origin` confirmed `origin/main` still at `c55601ad`, so no rebase was needed. The sourced app brief and buyer invariants above remain applicable. This round changes only EventDetailPage layout, a browser regression, and QA evidence. No backend, policy, pricing logic, or PR #163 files changed.

| Before | After | Why |
| --- | --- | --- |
| Full-width title and cover precede the desktop ticket grid; the round-1 1280 capture puts tickets below the first screen | One desktop grid: title/cover and details occupy two columns; the existing ticket panel spans both rows in the right column and sticks at 96px | Buyers can select tickets from the first screen |
| Desktop repeats a Choose tickets jump link | Link remains on mobile and is hidden at lg+ | The desktop panel is already visible |

Below 1024px the DOM order remains title → cover → tickets → details. Mobile Get tickets behavior is unchanged: it appears while both purchase targets are out of view, returns to and focuses tickets, and stays away from the footer. The new regression checks its return/focus behavior. The original failed desktop capture remains available at `af8fb3db:docs/qa/prepilot-buyer-path/after/1280-event-cover.png`.

The agent executed affected-flow QA in local Chromium with synthetic public API responses and repository artwork served as an approved upload. Vite 4173 used Node 22.22.3 with Clerk disabled for these public fixtures. No account authentication, provider payment, email delivery, or live database acceptance is claimed. No database was created. T3 Preview opened, but two snapshot attempts failed with `Preview automation snapshot timed out after 15000ms.`; the owned tab was closed before using local Playwright. Physical phone, native wake-lock, and real Clerk limitations remain as recorded above.

### Required fixture matrix

All 8 cases passed at all 4 dimensions (32 dimension results). The captured application source is the round-3 EventDetailPage change on `af8fb3db`; captures are local QA, not production release evidence.

| Case: starting fixture → action → expected visible outcome | 375×812 | 1024×768 | 1280×800 | 1440×900 |
| --- | --- | --- | --- | --- |
| Cover → read, increase quantity, buy → matching checkout opens; 16:9 artwork retains 35% 65% focal point | Pass | Pass | Pass | Pass |
| No cover → select ticket → checkout opens; panel remains top-right on desktop | Pass | Pass | Pass | Pass |
| Long title → read, select → wrapping stays inside column; desktop purchase row stays visible | Pass | Pass | Pass | Pass |
| Sold out → no quantity controls; enter name/email, join waitlist → position confirmation shown | Pass | Pass | Pass | Pass |
| Free → select → checkout opens with free admission | Pass | Pass | Pass | Pass |
| Assigned seats → keyboard-select exact seat, reserve → seat label preserved in checkout | Pass | Pass | Pass | Pass |
| Private preview → read banner and disabled ticket explanation → purchase remains disabled | Pass | Pass | Pass | Pass |
| Waitlist offer → read reservation/expiry, claim → checkout opens | Pass | Pass | Pass | Pass |

All dimensions have no document horizontal overflow. Assigned seating uses its existing wrapping row controls; every seat target remains at least 44×44px. At 1024px the outer column is 298.66px wide and at 1280px it is 341.34px. A 12-seat row, including an unavailable seat, remains usable through keyboard selection and reservation at both widths. No full-width seating exception or SeatSelector change is needed. Rows wrap as they already do on phones; this is not a spatial venue-plan renderer.

### Above-the-fold measurement

With scrollY=0 at 1280×800, the visible ticket card begins at y=96px. Its complete first admission row, including price and quantity controls, occupies y=161–321px. The desktop long-title and no-cover variants have the same first-row bounds. At 1024×768 and 1440×900 the first row also occupies y=161–321px. With a waitlist offer ahead of the card, the first row is y=371–531px, still visible. These are bounding-client-rect measurements after local fonts load; `round3-measurements.json` retains all state/viewport values. Its panel rectangle is the tall grid cell; the sticky child is the visible card container.

Refreshed `after/{375,1024,1280,1440}-event-{cover,no-cover,long-title,sold-out,free,seating,preview,offer}.png` are full-page public synthetic captures. `1280-event-cover-viewport.png` directly shows first-screen purchase availability; `1024-event-seating-viewport.png` shows the narrow seat controls. Checkout/confirmation/ticket captures from prior rounds are retained because their UI did not change here.

### Round 3 gates and ownership

- Final lint: passed, zero warnings.
- Full units with `VITE_CLERK_PUBLISHABLE_KEY`, `VITE_API_URL`, `VITE_SUPPORT_EMAIL`, and `VITE_ENABLED_LOCALES` explicitly cleared: **1,970 passed, 3 skipped, zero failures**; 179 files passed and one skipped; 325.64 seconds on Node 22.22.3. A jsdom XHR diagnostic was logged; the command exited 0.
- `build:no-translate`: passed; no translation command ran.
- Full Playwright: **142 passed / zero failures** in the initial and final runs (1.2 and 1.3 minutes). Final run includes the four new responsive/artwork regressions and explicit mobile sticky-bar return/focus check. The known `event-day.spec.js:80` flake did not occur.
- Impeccable 4.6 on changed UI path `src/pages/EventDetailPage.jsx`: `[]`, no findings. No hooks or packages installed in the repository.
- Fixture walkthrough: **32/32 dimension results passed**, with keyboard seat selection/reservation and successful simulated waitlist responses; no persistent database writes.

PR #162 remains held for the lead. Required CI and final-head CodeRabbit review are external gates; their final observed states are recorded in the handoff. The existing four round-2 CodeRabbit threads are resolved and acknowledged. A success-labelled skipped/rate-limited CodeRabbit check does not establish a completed review. No merge is authorized for this implementation agent.

## Merge integration — executor round 3

October 27, 2026. PR #163 merged as `6c335797a937f552e57592a3bcccb1b1d3aa36fa`. Production `/release.json` serves that exact revision and the entry bundle changed from `index-DB00_jOD.js` to `index-9q0nvAUr.js`. Signed-out Chromium verified Home's loaded Chamorro Village night-market photo, honest empty state, and expandable Photo credits; Host's `5% + $1.00 per paid ticket` and working $10/$25/$59 presets; and `/events` with its empty inventory. This check did not create production data.

The buyer branch rebased cleanly onto that main commit. `git range-diff` confirms all five original commits retained their patches; there were no locale or shared-test conflicts. The combined English locale retains both the public-page/photo copy and the buyer service-fee labels. The sourced context and buyer invariants above remain applicable.

Source commit `ba207ca01a97183f0a281dd0e7d5a03aa8d3045b` replaces EventCard's ticket SVG with the shared EventDateTile and removes the blank artwork frame when there is no approved cover. Approved artwork retains its frame and focal point. Three unit cases cover missing/rejected artwork and approved artwork. Existing shared tile tests cover Guam midnight and event timezones. Local tests/build/captures ran against the identical source tree before this commit; Vite's revision metadata was `3bc2093a`, so these are local acceptance artifacts rather than release evidence.

The agent executed the affected list journey with synthetic API responses, Clerk disabled, and a no-cover event with $20 admission plus a $2 service fee. At 375×812 and 1280×812, the card displays the shared date tile and $22 all-in price, has no horizontal overflow, opens through keyboard Enter, and returns to the preserved `Guam` search. Both dimensions passed. Screenshots are local only: `/tmp/hafapass-round3-no-cover-events-375.png` and `/tmp/hafapass-round3-no-cover-events-1280.png`; results are `/tmp/hafapass-round3-list-results.json`.

Integration gates on Node 22.22.3:

- Lint: passed, zero warnings.
- Full serial units: **1,981 passed, 3 skipped, zero failures**; 180 files passed and one skipped, 272.32 seconds. Requested auth/public-web/API variables plus support/locale overrides were cleared; `npm test -- --maxWorkers=1` was used. A jsdom XHR diagnostic was logged; Vitest exited 0.
- `build:no-translate`: passed; no translation ran.
- Full Playwright: **151 passed, zero failures** (2.0 minutes); no flaky-test rerun was needed.
- Impeccable 4.6.0: `[]` across all changed UI source paths; no package or hooks installed in the repository.

T3 Preview failed twice with `Preview automation snapshot timed out after 15000ms.`; the owned tab was closed and local Chromium supplied the evidence. Physical-device behavior and real Clerk authentication remain untested. All owned Chromium processes and Vite 5243 were cleaned; no database was created. PR #162 remains held for the lead's final CI/review decision. The executor requests CodeRabbit once after pushing and does not merge this PR.
