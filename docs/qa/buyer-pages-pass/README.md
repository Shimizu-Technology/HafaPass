# Buyer pages — the pass

2026-10-28 · Agent-executed affected-flow QA · Hold for the lead; do not merge.

## Product and acceptance

HåfaPass helps Guam buyers discover events, buy as guests, recover orders, and show tickets at the door. This PR extends the approved public design to discovery and buyer account pages with a short teal title band, light content, and ticket stock only for meaningful ticket/empty states. One clear primary action leads each state. No new entrance or decorative animation.

Sources: Leon's task and lead's design decision; current Home/Host/Ticket primitives from PR #164; Events/MyTickets/Saved/Collections, event actions and OrderRecovery code at fetched `origin/main` `3882764d`; Brain Dump `work/shimizu-tech/future-builds.md`, “HafaPass — Guam Event Ticketing Platform” (historical May 4 context). Supplied production inventory and pilot context are not independently verified. Main auto-deploys on Netlify; this branch must remain unmerged.

Required acceptance: confirmed empty inventory reuses Home's honest ticket; loading, outage and no-match stay distinct; all query filters/pagination/recovery survive; My tickets keeps tabs, installation help, account settings, transfer/status and order behavior; recovery copy names the actual reference + email flow; Saved describes existing Save, Follow and Remind me actions. Existing event → checkout → confirmation → display ticket behavior stays intact. No backend, pricing, policies, shared button CSS, workspace/admin/support/scanner changes.

## Environment and evidence plan

Isolated worktree `/Users/leonshimizu/.t3/worktrees/HafaPass/t3-1ff03b0c`, branch `codex/buyer-pages-pass`, based on fetched `3882764d`. Rails 3066, Vite 5236; throwaway PostgreSQL `hafapass_buyer_pages_test`, SQL identity checked before schema load and [fixtures.rb](fixtures.rb). Database and servers will be removed/stopped after QA; shared Postgres remains available.

Browser fixtures use the repo's existing no-Clerk development route behavior and intercepted synthetic API responses. My tickets/Saved coverage establishes rendering and interactions under those fixtures, not signed-in Clerk integration. No private buyer data or credentials in screenshots. Physical iPhone keyboard, rubber banding and installed-device safe areas remain untested. Chromium and WebKit at 375×812, 390×844, 1280×800 are the required visual dimensions; stress checks also cover 320px and 200% text.

## Required scenario ledger

| Case | Starting fixture → actions → expected outcome | Status |
| --- | --- | --- |
| B01 Empty inventory | Confirmed empty Events/Discover → hosting stub → Host; no search/filter controls or unclear home label | Passed within stated fixture/device limits |
| B02 Browse/filter | Populated Events → search/category/date/price/village + reload + pagination → preserved query and matching cards | Passed within stated fixture/device limits |
| B03 No-match/outage | Empty filtered response / failed API → clear/retry → restored catalog, preserved filter context | Passed within stated fixture/device limits |
| B04 Discovery | Curated collections → view all → collection pagination → event; empty collections with inventory remain distinct | Passed within stated fixture/device limits |
| B05 Tickets empty | Empty account fixture → recovery → reference/email form; Browse events → Events | Passed within stated fixture/device limits |
| B06 Tickets populated | Issued/used/blocked/transfer fixtures → compact pass + open ticket; tabs and keyboard + reload; install disclosure; account link | Passed within stated fixture/device limits |
| B07 Saved | Empty useful instructions; populated cards/organizer/reminder → correct destination; failed API → retry | Passed within stated fixture/device limits |
| B08 Consistency | Event → choose quantity → checkout; synthetic confirmation → ticket; correct header/theme/seams/sentence case | Passed within stated fixture/device limits |
| B09 Accessibility/craft | All matrix scenes → axe AA, no overflow, CLS <0.1 in Chromium; visible keyboard focus and ≥44px changed targets | Passed within stated fixture/device limits |
| B10 Worst case | Long/one-word/multilingual/missing venue/type/attendee/large list → 320px + 200% text; demo/worst toggle fixture | Passed within stated fixture/device limits |

Automated gates, reviewer coverage and cleanup are recorded below. The final PR head is an evidence-only descendant of the frozen source commit.

## Design re-audit and initial defects

Impeccable 4.6.0: no findings in the changed UI paths (`impeccable.json`). Taste scan: no eyebrow, gradient, glass or uppercase-label findings. Existing header dividers/sticky shadow and order/receipt table dividers remain deliberate; the unchanged account-preparation `min-h-screen` is outside this layout pass. The new tabs’ shadow was removed. Raw findings are in `taste-lint.json`; these advisory rules do not override the approved ticket seams or usable receipt rows.

Emil review:

| Before | After | Why |
| --- | --- | --- |
| Multiple entrance/stagger wrappers in My tickets | Immediate rendering; existing navigation motion only | Keep frequent account use calm; no new animation |
| Generic account card | Shared masked stock, inset controls and an explicit Open ticket action | Ticket meaning and visible focus without clipped outlines |
| Underlined tabs, overflow at 200% text | Two equal tracks with bounded width and 44px buttons | Arrow keys, reload and large text retain access |
| Loading-only Saved/collection and short confirmation loader | Stable title/content shell and reserved height | Reduce movement while API responses arrive |
| Temporary automatic-recovery line pushed content | Screen-reader progress message | Preserve progress feedback and stable ticket position |

No new motion or hover transforms. Existing reduced-motion behavior remains. Phone inputs stay at 16px; no zoom suppression. Physical-device touch, keyboard and safe-area behavior remain not run.

The first visual run found collection and automatic-recovery CLS above 0.1; both were fixed and affected scenes rerun. The stress run found tab overflow at 200% text; equal tracks fix it. The initial Playwright run had three failures in the new assertion that matched outgoing `.ticket` elements during navigation; the assertion now waits for the display QR. The first unit run began while copy assertions were being updated and is superseded. A subsequent run hit a scanner timing timeout under concurrent browser load; scanner code is untouched and the full units will rerun after browser QA settles.

Interim results: 84 browser/viewport scenes, zero axe A/AA violations, maximum measured Chromium CLS 0.03695; WebKit does not support the Layout Instability observer. 78 stress combinations passed, including 320px, 200% text and 1,000 tickets. Final short-band screenshots and all required gate outcomes will supersede these interim results below.

## Final source and visual acceptance

Visual/stress source: `8d1c695288fd141eb9a089f7a9d256effe6b04fe`. The later portal correction is `9a08ecc3` and English transfer-expiry correction is `58e76d5f`; both are described and retested below. Final full matrix rerun uses the shorter title-band copy and 44px public header controls; 84/84 scenes pass, zero axe violations, Chromium max CLS **0.0369458128**. WebKit CLS remains unavailable, not measured zero.

| Engine | 375×812 | 390×844 | 1280×800 |
| --- | --- | --- | --- |
| Chromium | Passed, all 14 scenes | Passed, all 14 scenes | Passed, all 14 scenes |
| WebKit | Passed, all 14 scenes | Passed, all 14 scenes | Passed, all 14 scenes |

Scenes: Events empty/populated/no-match; Discover empty/populated; individual collection; My tickets empty/populated; Saved empty/populated; event detail; checkout reached by choosing a ticket; synthetic guest confirmation; guest display ticket. PNGs and `after-results.json` are committed. Before PNGs come from `3882764d` and the same synthetic fixtures. Final title bands plus the header measure about 175px on the normal phone fixtures.

All six Saved interaction journeys (both engines × three widths) passed: Save, Follow and Remind me on the event → reload Saved → correct card, organizer and reminder destinations; a failed Saved request stays distinct from an empty list, and retry restores the saved fixture state. These establish the intercepted API contract, not live authentication, database persistence or email delivery. `journey-results.json` records the boundary.

The stress fixture supplies a browser-only Demo / Worst case / Empty / One / 1,000 tickets control. Run `node scripts/qa/buyer-pages-stress.mjs` against Vite 5236 to reproduce. 78 combinations passed across both engines, 320px, 375px at 200% root text, and 1280px; no document overflow. Long event/type/venue/attendee text, multilingual text and emoji, one-letter and absent attendee, missing venue, high price, paused entry, empty/one/1,000-ticket lists were exercised. No dark/RTL theme is offered by this public UI. Fixture browser contexts close in `finally`.

| Worst case defect | Cause | Fix |
| --- | --- | --- |
| Tabs overflowed at 200% text | Content-sized tracks plus fixed padding exceeded the phone container | `MyTicketsPage.jsx`: two `minmax(0,1fr)` grid tracks, bounded control width, `min-w-0` buttons and smaller padding |

Required cases B01–B10 passed within the browser/fixture limits above; automated full-gate outcomes remain separate below. Physical iPhone and real Clerk remain not run.

## Review and hold

PR: https://github.com/Shimizu-Technology/HafaPass/pull/170. **Do not merge; the lead merges.** CodeRabbit reported its OSS limit (42 minutes until capacity at the first attempt). One explicit review request was posted at https://github.com/Shimizu-Technology/HafaPass/pull/170#issuecomment-6454711017. There are no completed CodeRabbit reviews or findings to resolve. The success-labelled CodeRabbit status is a skipped/rate-limited run, not a clean review. Required review remains pending. Two supplementary read-only source review rounds are described below; they do not replace required CodeRabbit review.

Shared files: Navbar only adds title-band route selection and public 44px targets; workspace markup is unchanged. Home delegates its existing empty message and hosting stub to `EmptyInventory` while keeping the ticket DOM identity through loading. English locale additions stay under `pass.buyer`, with two existing My tickets labels updated; translation fallback remains in place. `src/index.css`, backend, pricing and policies are untouched.

## Independent review correction

Supplementary round 1 reviewed `8d1c6952` and found a material mask interaction: the pending-transfer confirmation rendered inline under `.ticket-notch`. The fixed overlay could be clipped while trapping focus and locking scroll. `9a08ecc3` adds an opt-in `portalDialog` to shared `PendingTransfer`; only `BuyerTicketPass` opts in. `Dialog.jsx` and workspace/admin/scanner callers remain unchanged. This is the additional minimal shared-file edit.

New browser coverage at 375/390/1280 verifies the confirmation is outside `main` and the mask, fully visible, axe clean, traps/restores keyboard focus, closes with Escape/Keep transfer, preserves a 503 error with retry, then cancels and stays cancelled after reload. All 12 focused buyer tests pass. Screenshots: `after/{375,390,1280}-pending-transfer-dialog.png`. Reviewing the screenshot also caught a pre-existing duplicate “Guam time” in English transfer expiry; the formatter supplies the zone, so the label now appends only the formatted date. The new check prevents duplicate wording.

Before this correction, the serial complete gate passed 2022 unit tests (3 skipped) and all 161 Playwright tests. The earlier concurrent run timed out in the unchanged pilot-readiness test (160/161); the full serial rerun passed it. Reviewed-source complete gates are rerunning, including three new transfer scenarios (164 browser tests total). The PWA suite's two tests passed; the portal-only correction does not change the service worker, install flow, cache or PWA fixtures.

## Database cleanup limitation

Rails 3066 and Vite 5236 are stopped; the T3 QA tab and fixture browser contexts are closed. The shared PostgreSQL service is protected by the local machine profile. `DROP DATABASE hafapass_buyer_pages_test` waited more than eight minutes on PostgreSQL `CheckpointStart`, with zero connections to that database; another unrelated database drop was already waiting on the same service. The last completed checkpoint reported by `pg_control_checkpoint()` was 07:42 Guam time while the cleanup attempt was after 08:03. No shared service was stopped or restarted.

I cancelled only this task's blocked `dropdb` statement (verified backend PID 30193 and exact query/application name) so no cleanup process remains running. **The synthetic throwaway database record still exists, marked invalid for connections (`datconnlimit=-2`) by the interrupted drop.** Once the shared checkpoint issue clears, re-confirm the exact name then run `dropdb -h localhost hafapass_buyer_pages_test`. This is an unresolved cleanup item, not an accepted resource handoff. No private customer or production data was put in it.

Supplementary review round 2: no material findings at `9a08ecc3022795fe4ffdd69a6a37b21432a3eb59`; the prior mask P1 is resolved. Later changes are English expiry de-duplication plus its browser assertion (`58e76d5f67fea0c6bb55acb0312aae09c7147d66`), and the hidden results H2 plus heading-order checks (`91d503eb903be509ae75b49a78bc2cc7e9668981`). No third cosmetic review round was requested. CodeRabbit is still required and pending.

## Reviewed-source automated acceptance

| Gate | Result |
| --- | --- |
| `npm run lint` | Passed, zero warnings |
| `VITE_CLERK_PUBLISHABLE_KEY='' VITE_PUBLIC_WEB_URL='' VITE_API_URL='' npm test -- --maxWorkers=1` | Passed: 2022 tests, 3 pre-existing skips; 182 files passed, 1 skipped |
| `npm run build:no-translate` | Passed |
| `npx playwright test --config playwright.pwa.config.js` | Frozen source standalone: passed 2/2 with original strict timeouts |
| Full Chromium Playwright, 15s assertion / 60s test budgets | Passed: 164/164, no retries/skips; stock-timeout failures remain recorded |
| WebKit buyer interactions | Passed 12/12 at 375/390/1280, including portal confirmation, focus, failure/retry/cancel and reload |
| Impeccable 4.6.0, all changed source/test/QA paths | Passed, no findings (28 paths; `impeccable-all-changed.json`) |
| Taste, all changed source/test/QA paths | 21 supported files; 17 existing hairline, 1 existing sticky shadow, 1 unchanged preparation height finding; no eyebrow/gradient/glass/uppercase-label findings (`taste-all-changed.json`) |

WebKit's initial pointer-based test incorrectly assumed Safari focuses a clicked button. Focus restoration is now tested from real keyboard activation on every open; pointer actions still exercise the confirmation buttons, error response and retry. The 12-test WebKit rerun passes. The pre-existing shared `Dialog` implementation remains unchanged.

The database drop was retried once with a 30-second PostgreSQL statement timeout after the checkpoint timestamp advanced. It again timed out waiting for the shared checkpoint. The invalid pending-drop database record remains; no drop process or database connection is left running.

## Stock-timeout browser gate limitation

The final non-overlapping stock-timeout run finished **162/164 passed**, with two unchanged organizer-flow failures: `manual-payout-approval.spec.js:89` (the reloaded page was still the global dev route loader at the 5-second assertion limit) and `verification-gate.spec.js:105` (private preview/verification request timed out at 30 seconds). Those application files and tests are untouched. The prior 163/164 run failed an unrelated settings-dialog focus assertion, while the earlier 161-case complete suite passed before the three transfer regressions were added. These stock-timeout failures remain recorded and are not called green.

One bounded final local run uses `scripts/qa/buyer-pages-local.config.mjs`: the same complete suite, one worker, zero retries, no filtered/skipped cases, 15-second assertion waits and 60-second test budgets. This accommodates slow dev chunk loading on the shared workstation. It does not modify the repository's default or CI config, and its result must be reported separately from the stock-timeout runs. Required final-head CI and CodeRabbit still belong to the lead's hold decision.

## Heading-order correction and frozen source

An explicit `heading-order` audit (outside the AA-tag subset) found that populated Events and individual Collections inherited an H1 → EventCard H3 skip. `91d503eb903be509ae75b49a78bc2cc7e9668981` adds an invisible H2 “Event results” before those grids. The visible design and screenshots are unchanged. The header/scroll regression now also waits for cards and checks both the H2 and axe heading order.

After this correction: 41 affected unit tests pass; all 12 buyer interaction tests pass in each engine across the three dimensions, including heading order, mask-safe transfer confirmation and keyboard focus. Lint/build pass. Impeccable rerun: no findings over 28 changed source/test/QA paths; Taste's same existing 19 findings, no prohibited label/gradient/glass/eyebrow patterns. The earlier full suite with 15-second assertion waits completed 164/164, zero retries/skips. The full unit/browser/PWA gates completed on this frozen source as recorded below; subsequent commits contain evidence only.

## Frozen-source gate results

At `91d503eb903be509ae75b49a78bc2cc7e9668981`: full units **2022 passed, 3 skipped** (182 passed files, one skipped); full Chromium suite **164/164 passed**, zero retries/skips, using the documented local timing config. The 41 affected unit tests and 12 buyer tests in each engine also pass after the heading fix. The repository/CI config is unchanged. Stock-timeout runs are not represented as green.

The simultaneous PWA rerun was 1/2: its deliberate `/timeout-never-visited` navigation exceeded the original 15-second navigation timeout during other QA. The standalone rerun passed **2/2 in 1.9 minutes**, with the original strict 9-second fallback expectation and original config. `pwa.txt` records the final standalone pass; `concurrent-pwa-timeout.txt` preserves the earlier failure.

## Final resource check

Lifecycle cleanup completed: no active owned resources. No listeners remain on task ports 3066, 5236, 4173, 5238 or 5234. The invalid synthetic database row remains (`hafapass_buyer_pages_test`, `datconnlimit=-2`), with zero connections and zero active DROP statements. This unresolved data cleanup is in [HANDOFF.md](HANDOFF.md). The held worktree and branch are preserved for the lead. Backend/pricing/policies untouched. Final-head CI and CodeRabbit are pending, not awaited by this delegated child.


## PR #170 follow-up — round 2 (2026-10-28)

Agent-executed affected-flow QA. Started from clean `f297b9161d3b6262295c7609373dbf44992d7b6f` in the existing named worktree; fetched and rebased onto `origin/main` `81abf68c` (PR #169, backend spec only). The product brief and B01–B10 acceptance above remain applicable. This follow-up changes only guest/account recovery guidance, the startup header theme, and QA assertions. No backend or fee/pricing/policy/shared-button/workspace changes. The PR remains held for the lead; do not merge.

Required affected acceptance:

- R21: Empty Tickets and Orders explain guest reference + checkout email recovery and signing in to the purchasing account. Follow the explicitly labelled guest link to the reference/email form; Browse events still works. Chromium at 375/390/1280; synthetic empty account fixtures, no real Clerk or email delivery.
- R22: At DOMContentLoaded, with external JavaScript modules blocked, the browser theme and startup header strip are teal for Home/Host/Events/Discover/Collections/My tickets/Saved/ticket display and white for event detail and workspace routes. Mounted Navbar retains its scroll behavior. One route predicate generates the inline script and drives Navbar.
- R23: The populated Events screenshot requires an event card; the stress fixtures assert actual buyer-pass counts, excluding the empty ticket. Run the populated visual scene and all 78 stress combinations.

The old `hafapass_buyer_pages_test` database was already absent at preflight. These checks use intercepted synthetic API fixtures and need no new database. Shared `hafapass_api_test` is borrowed and untouched. No real authentication, provider delivery or physical-device acceptance is claimed.


Production changes are frozen at `77ceb8fb6b4a9f9153e69490f18a5b40d2442cee`; `b315bf42` only aligns two existing cold-load expectations with the corrected behavior. The final complete browser gate runs that combined source. The first follow-up run was 174/176 because `first-load.spec.js` still expected white on Events and Discover; its log is preserved in `round2-playwright-initial.txt`. The assertions now expect teal. The 12 new DOMContentLoaded tests already passed in that first run and also pass in the complete rerun.

| Follow-up gate | Result and evidence |
| --- | --- |
| Lint | Passed, zero warnings (`round2-lint.txt`) |
| Units with all three requested VITE variables empty | 2022 passed, 3 pre-existing skips, 182 files passed / 1 skipped; default worker config (`round2-units.txt`) |
| `npm run build:no-translate` | Passed; generated shell contains the shared route predicate and no unresolved startup token (`round2-build.txt`) |
| Full Chromium Playwright | **176/176 passed**, stock timeout config, one worker, zero retries or skips (`round2-playwright.txt`) |
| Standalone PWA | **2/2 passed**, original timeout config (`round2-pwa.txt`) |
| Targeted visual/axe | **8/8 passed**, Chromium + WebKit at 390/1280; populated Events and empty My tickets; zero AA axe violations, no overflow; max Chromium CLS 0.03127236412203057, WebKit CLS unavailable (`round2-visual-axe.txt`, `targeted-after-results.json`) |
| Impeccable 4.6.0 | No findings over all 33 changed frontend/source/test/QA paths (`round2-impeccable.json`) |

The organizer payout persistence and private-preview/verification cases passed with stock timeouts in both full follow-up runs. Their conditional clean `origin/main` comparison was **not needed and not run**. No wider timing allowance was used for these follow-up gates.

R21 passed in Chromium at 375/390/1280: both empty tabs show the guest/account distinction; the guest link opens reference + email fields, and Browse events still opens Events. R22 passed: startup colors are captured at DOMContentLoaded with all external scripts replaced by empty modules, before Navbar exists; the shell header strip and theme meta agree on all 12 route cases. Mounted/scroll checks pass at all three widths. The broad accessibility journey suite also passes as part of the complete Chromium run.

Refreshed, visually inspected empty My tickets screenshots: `after/390-my-tickets-empty.png`, `after/1280-my-tickets-empty.png`, `after/webkit-390-my-tickets-empty.png`, `after/webkit-1280-my-tickets-empty.png`. Existing unrelated screenshots retain their earlier source/evidence history.


R23 passed: the populated Events scene required visible event cards in both engines at 390/1280. All **78 stress combinations passed**, including buyer-pass counts for every My tickets variant; Empty = 0, One = 1 and 1,000 tickets = 1,000 in both engines at 320px, 375px / 200% text, and 1280px (`round2-stress.txt`, `stress-results.json`). The empty-state stock is excluded from the buyer-pass count. All **12 WebKit buyer interaction scenarios passed** with stock timeouts (`round2-webkit.txt`), including recovery, keyboard tabs, saved state on reload, scroll theme, and transfer-dialog retry/cancellation. R21–R23 are accepted within the documented synthetic/browser limits. Real Clerk/email delivery and physical devices remain not run.

Cleanup: task-owned Vite 5236 stopped; PWA fixture servers, test browsers and the T3 preview tab are closed. Lifecycle status has no active owned resources and no intentional runtime handoff (`round2-cleanup.txt`). No new database was created. TCP verification lists only borrowed `hafapass_api_development` and `hafapass_api_test`; `hafapass_buyer_pages_test` is absent (`round2-databases.txt`). Shared PostgreSQL and other sessions were left running.

The two CodeRabbit findings are fixed in `77ceb8fb`: populated-scene readiness and buyer-pass count assertions. The implementation agent replies/resolves those threads with this push and requests `@coderabbitai review` once. Final-head hosted checks and fresh review coverage remain for the lead to inspect; neither the old green checks nor the earlier rate-limited status establish approval of this new head. The PR is held and must not be merged by this agent.
