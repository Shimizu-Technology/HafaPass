# Pre-pilot public pages

2026-10-27. Agent-executed affected-flow QA; base `c55601ada2423ff71ce362ba25a8560c18871d41` (`origin/main`, verified by fetch). Branch `codex/prepilot-public-pages`. Netlify deploys main automatically. The lead (Claude) owns the merge decision under Leon's standing authorization; implementation workers do not merge.

## Product and acceptance brief

HåfaPass serves Guam ticket buyers on phones, organizers and admins. The first pilot has not happened. Public pages must explain the offer accurately and preserve the honest empty inventory state, search/featured/Next Up navigation, fee calculator, FAQs, hosting CTAs and every footer/policy link. Existing teal/coral tokens, Space Grotesk, Plus Jakarta Sans and button styles remain the brand. No backend, fee logic, policy text or neighboring buyer-flow components are in scope.

Sources: supplied current product brief; `docs/COPY_GLOSSARY.md`; `docs/STRIPE_PROCESSING_FEE_OPERATIONS.md`; `Event#publicly_visible?`, `#private_preview_eligible?`, `#organizer_sales_verified?`; `OrganizerProfile.verification_gate_enabled?`; `OrganizationMembership` roles; browser scanner manifest/preparation/offline code in `pages/dashboard/ScannerPage.jsx`; cash sales in `pages/dashboard/BoxOfficePage.jsx` and `Commerce::OrderCreator`; `EventCancellationRefunds` and `config/policies.yml` cancellation remedy. `/config` returns 5.0%, 100 cents, platform processing bearer and `within 3 business days after your event`. Policy payout method: check unless another method is approved and recorded. These source files remain unchanged.

Historical context: Brain Dump `system/full-picture-2026-10-12.md:219` identifies the Ambros pilot; its older launch gates are superseded by the supplied Oct 27 brief. Repository `AGENTS.md` is untracked in the main checkout and absent in this worktree; its main-checkout instructions were read. Public QA does not use Clerk credentials or read `.env`.

## Environment and fixtures

Rails `http://localhost:3062`, Vite `http://localhost:5232`, Node 22.22.3, Ruby 3.3.4. Throwaway database `hafapass_prepilot_b`; identity asserted with `SELECT current_database()` before fixtures. Empty DB first, then four explicitly named QA events, one featured, belonging to a QA organization/profile with active owner membership. No real customer data, payments, sends, or production changes. Screenshots show local fixtures, not real HåfaPass events.

T3 preview opened but `preview_snapshot` failed twice with `Preview automation snapshot timed out after 15000ms.` Switched to local Playwright Chromium 156.0.8078.4. Browser resize verifies responsive web layouts, not physical-phone gestures, native keyboard or installed PWA behavior. Signed-in Clerk journeys are out of scope.

## Required scenarios (round 1)

Each case requires 375×812, 768×1024 and 1280×800 unless stated. All six cases were executed at every required viewport. Browser interactions used keyboard activation and real local API fixtures; automated e2e adds controlled failure and delayed-response fixtures.

| ID | Starting state and actions | Expected outcome | Status |
| --- | --- | --- | --- |
| P01 | Empty Home: load, inspect hero and empty state, follow hosting CTA | Honest coming-soon state; Guam photo; no category inventory claims; hosting route works | passed |
| P02 | Four QA events: inspect featured/Next Up; use search and category links | Featured and lists render; search/query/category navigation preserved | passed |
| P03 | Host: read pricing, compare $25/$59 examples; change calculator to $59, free, invalid and two tickets | Shared calculation agrees; validation/recovery and free state work | passed |
| P04 | Host: read verification/door/local-help copy; open FAQ by keyboard; follow support and CTA | Accurate claims/caveat, configured support contact and organizer destinations | passed |
| P05 | Footer: tab through links; expand mobile policies and photo credits | All existing links plus attribution/source/license links reachable with visible focus | passed |
| P06 | Home empty/populated + Host: inspect images, overflow, reduced motion, layout shifts | Reserved image dimensions, responsive sources, no overflow, CLS < 0.1 | passed |

## Evidence

`before/` retains the original baseline. `after/` now contains the round-2 screenshots listed below. The original JSON files retain round-1 execution results; `round2-results.json` is the current run. No photos are passed off as customer events.


## Round 1 execution evidence and limits

P01: `empty-results.json`; P02–P04: `interaction-results.json`; P05: `policy-navigation-results.json` (18 keyboard activations with the correct policy heading awaited) plus credits in `interaction-results.json`; P06: both result files and delayed-inventory/pricing CLS regression cases in `e2e/prepilot-public-pages.spec.js`. Normal-motion FAQ and local Host CTA destination are checked separately in `motion-cta-results.json`. All six cases passed their required responsive web dimensions. No physical-phone, installed-PWA, paid checkout or real Clerk session was exercised. Guest/signed-in CTA return behavior remains covered by Host unit tests using mocked Clerk. Locally, the blank Clerk key leaves the CTA at `/dashboard`, displaying “Please sign in to access the dashboard.”

| Viewport | Empty Home CLS | Populated Home CLS | Host CLS |
| --- | ---: | ---: | ---: |
| 375×812 | 0.0222 | 0.0185 | 0.0368 |
| 768×1024 | 0.0176 | 0.0176 | 0.0293 |
| 1280×800 | 0.0141 | 0.0117 | 0.0305 |

CLS measurements use the production-facing live-mode appearance in the isolated DB, without any payment actions. Before screenshots include the local simulated-payment test banner; after screenshots use live-mode appearance. This fixture difference is not a product change. A simulated-payment banner can add about 0.065 of pre-existing shell shift on mobile; its component and the motion block are outside this PR. Photographs have explicit intrinsic dimensions; the only eager photo is the Home hero.

Retests: the original desktop photo-to-featured swap produced about 0.42 CLS. Home now resolves inventory before selecting its hero and offers a Browse Events link during loading. The Host config placeholder originally moved content; it now reserves the pricing/payout space. Both fixes were measured again at all sizes. The first e2e run found old eyebrow/one-footer-disclosure assertions; those were updated while retaining inventory and every-policy coverage. New image assertions wait for decoding, and featured-heading assertions distinguish the hero from the repeated Next Up title. One unchanged editor draft file timed out under parallel validation load; all 13 tests passed in an isolated rerun. The final full suites are recorded below.

## Photographs (final, round 2)

Both retained photographs have commercial-use CC BY licenses, rechecked on their Commons file pages on 2026-10-27. Full source titles, authors, licenses and links are stored in `src/config/photoCredits.js` and rendered under Footer → Photo credits. WebP conversion/resizing is disclosed. No cropping or color edits were made. None represents a HåfaPass customer/event. Sources were visually inspected for Guam location, military/religious use and close-up identifiable minors. Home uses the night market; Host uses the bay. The night-market caption describes only the scene. The sunset and all three of its WebP variants were removed in round 2.

| Photograph | Author | License | Commons source |
| --- | --- | --- | --- |
| Chamorro Village night market — “チャモロ・ナイトマーケット - panoramio.jpg” | Junpei Abe | CC BY 3.0 | https://commons.wikimedia.org/wiki/File:チャモロ・ナイトマーケット_-_panoramio.jpg |
| “Tumon Bay from Matapang Beach Park.jpg” | Daniel Ramirez | CC BY 2.0 | https://commons.wikimedia.org/wiki/File:Tumon_Bay_from_Matapang_Beach_Park.jpg |

Each photo has 480, 800 and 1280 px variants. Largest files: market 94 KB, bay 86 KB. Alt text and visible location captions live in `en.json`; other locales remain valid and use the existing English fallback for new keys. No paid translation was run.

## Scope held

Policy source/text and fee/pricing logic are untouched. Payout schedule interpolation and the existing FAQ timing are unchanged; the policy's check-payout method is stated without shortening its schedule. Competitors, endorsements, sales claims and customer imagery are omitted. `EventDetailPage`, `EventCard`, `CheckoutPage`, `TicketPage`, Navbar, the index.css motion block and ScrollReveal are untouched. Existing footer links and the approved mobile policy disclosure layout remain.


## Round 1 gates and review history

Tested application source: `2a2253cf9955ed7187a47aae8a2277bac95bdc5b`. Subsequent changes are evidence/handoff documentation only.

- `npm run lint`: passed.
- `VITE_CLERK_PUBLISHABLE_KEY='' VITE_PUBLIC_WEB_URL='' VITE_API_URL='' npm test -- --maxWorkers=1`: 179 files passed, 1 existing skipped; 1,966 tests passed, 3 existing skipped (251.50 s). The sequential final run passed after the parallel timing issue and loading-state test updates.
- `npm run build:no-translate`: passed.
- `GT_API_KEY='' GT_PROJECT_ID='' npm run build`: passed; translator explicitly reported that credentials were absent and committed locale files were used. No paid translation.
- `PLAYWRIGHT_PORT=5232 npm run test:e2e -- --workers=1`: all 142 passed (3.2 min), including six new responsive photography/keyboard/CLS cases and existing empty-inventory/footer-policy coverage.
- Impeccable 4.6.0 advisory: `[]` (committed JSON). All locale files parsed; `git diff --check` passed; excluded-source/pricing/policy diffs empty.

PR: https://github.com/Shimizu-Technology/HafaPass/pull/163 (linked to the T3 thread). **Do not merge.** Main was fetched again and remained `c55601ad` before submission. GitHub CI and Netlify preview were started by the PR; their final remote state must be rechecked by the parent.

CodeRabbit did not review the code. Its required check is a gate: the bot returned “Review limit reached” at 2026-10-27 03:30:42 UTC, with the next included review available in 57 minutes. Evidence: https://github.com/Shimizu-Technology/HafaPass/pull/163#issuecomment-6433041331. Earliest stated retry is approximately 04:27:42 UTC / 14:27:42 Guam time. No material findings or review threads exist to address yet. No skipped/success-labelled check is represented as completed review. The implementation sub-agent does not watch or poll the PR; the parent should request `@coderabbitai review` after capacity resets, inspect the final-head coverage, fix material findings (about two substantive rounds), reply/resolve with evidence, and continue to hold the PR.

### Current before/after comparison

| Before | After | Why |
| --- | --- | --- |
| Empty desktop hero without a visual | Captioned Guam night market | Shows Guam evening activity without inventing HåfaPass events |
| Repeated feature/card sections | Price/calculator with quick picks, publishing story, door preview and local-help photo | Lets organizers understand cost and operation in order |
| Uppercase footer group labels | Readable sentence-case labels plus credits disclosure | Preserves the approved links and layout while improving legibility/attribution |

Runtime cleanup is recorded below after exact resource teardown. Keep the held branch/worktree for review; no resource is intentionally handed off.


Round 1 cleanup completed: lifecycle session `01a17b50-889d-7c23-850e-918895b32315` reports no active owned resources. Exact owned Rails PID 29578 (3062), Vite PID 33236 (5232), Chromium PID 37645 and its browser-server parent were stopped. The task-created T3 preview tab was closed and released. The throwaway `hafapass_prepilot_b` database was dropped and its absence verified. Shared PostgreSQL/Redis, Docker containers, LM services, other agents' listeners and the baseline simulator were left available. No resource handoffs or unresolved ownership remain. Branch/worktree are retained for the held PR.


## Round 2 — acceptance and evidence (2026-10-27)

Inherited the sourced product brief above and refreshed the affected code, Brain Dump pilot context, `origin/main` and branch protection. Starting head `f86002bc`; fetched main remains `c55601ad`, so no rebase. This round keeps the public-page brand and all scope restrictions. The organizer compares prices in one calculator, and the buyer sees a real date in place of missing art. Static date tiles and immediate preset updates add no new motion.

Agent-executed affected-flow acceptance, required at 375×812, 768×1024 and 1280×800:

- R01: Empty Home uses the night market with decoded responsive image, intrinsic dimensions and eager/high priority; caption describes the scene; hosting navigation works.
- R02: Four QA events with no-art featured event and Next Up tiles; correct Guam dates, readable sentence-case label, no blank art frame, search/category/event navigation preserved. Real-art behavior remains covered by unit tests.
- R03: Keyboard-activate all three price presets, verify pressed state/input/results and changed loaded-rate unit coverage; manually enter another price, free, invalid, recover, and adjust quantity. No duplicate worked-example block.
- R04: Host verification/door/help, FAQ keyboard behavior, footer links/credits, responsive overflow, reduced/normal motion and CLS below 0.1.

All four round-2 cases passed at every required viewport. Application source: `f4467cede7ef71b6aa1d882a019603339d98fd08`. `round2-results.json` records execution and CLS; `capture-round2.mjs` reproduces the API-backed checks. Full gate results follow below. Fresh task-owned `hafapass_prepilot_b` was created after checking absence; `db:prepare` seeded defaults, then all application tables were truncated only after asserting the database identity. Four named QA fixtures were recreated using the committed runner. Rails 3062 and Vite 5232 belong to lifecycle session `01a17b6e-0682-7dc1-ae0d-3d29741e264d`; shared services stay running. T3 snapshot failed twice with `Preview automation snapshot timed out after 15000ms.`; local Playwright Chromium is the fallback. No real payments, sends, Clerk or physical-device acceptance is included.


### Round 2 findings addressed

1. Removed the duplicated worked examples. The calculator has $10/$25/$59 real buttons, keyboard activation and `aria-pressed` derived from the parsed input. Typed prices and quantity continue through the unchanged fee calculation. Unit coverage also uses a different API-supplied fee to catch hardcoded results.
2. Removed “Photo from 2011.” from the market caption; full attribution remains in Footer → Photo credits.
3. Moved the market to the Home hero, retained the bay on Host, and removed the sunset files, metadata and locale copy. Existing WebP source sets, dimensions and eager/high-priority Home loading remain.
4. Added shared `EventDateTile.jsx` with event-timezone formatting (Guam by default), weekday/day/month, display type, tabular numerals and a dashed ticket-stub seam. Missing/broken Home art uses the tile. The no-art featured card starts with date and text without a reserved image frame; real art retains its frame/backdrop behavior. Featured label is 14px sentence case. Tests cover Guam midnight/month/year rollover and no-art/broken-art featured navigation.

### Round 2 screenshot index

Refreshed `after/home-empty-{375,768,1280}.png`, `after/home-populated-{375,768,1280}.png` (all include the no-art featured card), `after/home-no-art-featured-{375,768,1280}.png`, `after/host-{375,768,1280}.png` and `after/footer-credits-{375,768,1280}.png`. Phone, tablet and desktop screenshots were visually inspected; all three sizes passed the interaction runner. The new explicit no-art filenames show the same populated fixture state.

| Viewport | Empty Home CLS | No-art populated Home CLS | Host CLS |
| --- | ---: | ---: | ---: |
| 375×812 | 0.0223 | 0.0223 | 0.0406 |
| 768×1024 | 0.0176 | 0.0147 | 0.0293 |
| 1280×800 | 0.0117 | 0.0117 | 0.0328 |

The default fixture's `starts_at` is stored in UTC; its tiles correctly show the following Guam calendar day. Independent expected dates in the browser runner use `Intl` with `Pacific/Guam`. The unit cases exercise exactly 23:59:59/00:00 Guam and the year boundary. There is no backend, policy, fee-function or excluded-component diff.

### Round 2 engineering gates

Final full unit rerun passed: 180 files passed, 1 existing skipped; 1,971 tests passed, 3 existing skipped (215.69 s), with `VITE_CLERK_PUBLISHABLE_KEY`, `VITE_PUBLIC_WEB_URL` and `VITE_API_URL` explicitly cleared. Full Playwright passed: 142/142, no failures or skips (3.3 min), including all six updated public-page cases. The first browser run loaded the old sunset assertion before it was corrected and reported 140 passed/2 stale-assertion failures; the final run started fresh from `f4467ced` and passed all 142. The known event-day retry was not needed. Lint, `build:no-translate`, the credentials-cleared normal build, Impeccable 4.6.0 (`[]`), locale parsing and `git diff --check` passed. First full unit run: 1,970 passed, one unchanged scanner-journal export timing failure, 3 skipped; the affected scanner file then passed all 11 tests in isolation. That source was not modified. The final complete run passed without changing that scanner source or test.


### Round 2 cleanup and remote review handoff

Owned resources were cleaned under session `01a17b6e-0682-7dc1-ae0d-3d29741e264d`: Rails PID 55772 (3062), Vite PID 55756 (5232), both full-suite browser runners and the Chromium processes started by `capture-round2.mjs`. The task-created T3 tab was closed and its record released. The helper reports no active owned resources. `hafapass_prepilot_b` was dropped after reasserting its identity, and an absence query returned no rows. No runtime resource is handed off; shared and baseline services remain available.

CodeRabbit had not reviewed the original head: its required success-labelled check was a rate-limit skip at 03:30:42 UTC, with capacity stated to return about 04:27:42 UTC / 14:27:42 Guam. This delegated implementation pass finishes before that reset and does not issue a premature duplicate request or start PR watching/polling. The lead must request `@coderabbitai review` once after the reset if review has not run, classify/fix material findings, reply to incorrect findings with evidence, resolve threads, and verify required CI against the final head. Required review remains a gate; local passes do not establish merge readiness. **Do not merge from this sub-agent.**

The final production build records source `f4467cede7ef71b6aa1d882a019603339d98fd08` in `dist/release.json`. Subsequent commits update QA documentation/evidence only.

## Round 3 review fixes and acceptance

Refreshed against clean head `8e7a2105734fcd6cc294664577993e7f1d20022c`; fetched `origin/main` still `c55601ada2423ff71ce362ba25a8560c18871d41`, so no rebase was needed. The product, users, fee/policy invariants and exclusions in the sourced brief above remain applicable. This round changes Home's pending-request navigation and strengthens existing QA assertions. No backend, pricing logic, excluded buyer components or motion files changed.

CodeRabbit's four findings on `8e7a2105`:

- Focus assertion — material acceptance-coverage gap. The recorder now rejects `box-shadow: none`; the regular browser suite also checks focused presets have a non-`none` shadow.
- FAQ keyboard assertion — material acceptance-coverage gap. Both recorder and browser suite require the parent `details` to have `open` after Enter, in addition to checking its preparation caveat.
- Featured-event identity — nonblocking defensive improvement. The existing loading branch already unmounts the previous card on a content-language refetch. The key now includes both event ID and artwork URL. A regression test uses the content-language hook fixture, fails the first image, leaves the refetch pending, then supplies a different event with the same approved URL and checks that its image and destination render.
- Pending Home navigation — material acceptance defect. Loading now retains Start Hosting and the complete Footer while postponing the hero choice. Unit coverage checks the unresolved request, hosting link and six policy destinations.

Agent-executed affected-flow acceptance uses local Vite on port 5233 with Playwright Chromium and isolated route fixtures (`/health`, `/config`, pending/empty/featured `/events`). It does not start Rails, change a database, use Clerk, make payments or send messages. Required responsive dimensions are 375×812, 768×1024 and 1280×800. These are browser viewports; physical phones and installed PWA behavior are not run. The T3 tab was attempted, but snapshot failed twice with `Preview automation snapshot timed out after 15000ms.`; it was closed before the Playwright fallback.

| ID | Starting fixture, action and expected observable outcome | Result |
| --- | --- | --- |
| R3-01 | Events request stays pending: no empty-inventory claim; browsing and hosting remain reachable; keyboard-open mobile policy disclosure; six visible policy links; keyboard hosting navigation reaches Host; Privacy link changes route; no horizontal overflow | passed (focused browser run) |
| R3-02 | Host with known 5% + $1 fixture: focus and Enter on $59; non-`none` focus shadow; selected state and $62.95/$55.05 results; Enter on door FAQ actually opens its caveat | passed (focused browser run) |
| R3-03 | Delayed empty/featured inventory and config: retained photo/no-art date tile behavior and CLS below 0.1 at each required viewport | passed (focused browser run) |

The first focused browser attempts exposed ambiguous selectors in the new pending test (the shell has another status region and Footer has another Browse Events link). The full run also exposed that the nested footer has no `contentinfo` landmark role. The locators now target the loading message, secondary browsing action and `footer` element. All nine affected-flow browser cases then passed (22.4 s). Existing photo/focus/FAQ/CLS checks passed in those attempts; the complete final run below determines acceptance. The historical round-2 recorder was syntax-checked and strengthened; its real-API fixture capture is not repeated this round.

Final local gate results and remote review/check state are recorded in the round-3 handoff after execution. Impeccable 4.6.0 reported `[]` for all five changed UI implementation paths (`round3-impeccable.json`).

Round-3 local gates passed on the final implementation tree:

- `npm run lint`: passed after the final test-locator correction.
- `VITE_CLERK_PUBLISHABLE_KEY='' VITE_PUBLIC_WEB_URL='' VITE_API_URL='' npm test -- --maxWorkers=1`: 180 files passed, 1 existing skipped; 1,972 tests passed, 3 existing skipped (266.03 s).
- `npm run build:no-translate`: passed. No translation command or paid translation ran.
- Final `PLAYWRIGHT_PORT=5233 npm run test:e2e -- --workers=1`: 145 passed, 0 failures/skips (3.3 min). All three pending-navigation cases and all six photo/focus/FAQ/CLS cases passed. The known `event-day.spec.js:80` retry was not needed. The earlier full attempt had 142 passes and three new-test locator failures; this fresh complete run supersedes it.
- Impeccable 4.6.0: `[]`; recorder syntax and `git diff --check` passed. Policy/backend/pricing/excluded-component diffs against `origin/main` remain empty.

R3-01 through R3-03 passed all required viewport dimensions in both the corrected focused run and final full browser run. No required acceptance blocker remains locally. Remote required checks and CodeRabbit coverage must be evaluated against the pushed head, not the previous head's green checks. The lead owns that readiness and merge decision.
