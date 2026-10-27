# Pre-pilot public pages

2026-10-27. Agent-executed affected-flow QA; base `c55601ada2423ff71ce362ba25a8560c18871d41` (`origin/main`, verified by fetch). Branch `codex/prepilot-public-pages`. Netlify deploys main automatically; this PR is held for Leon and must not merge.

## Product and acceptance brief

HåfaPass serves Guam ticket buyers on phones, organizers and admins. The first pilot has not happened. Public pages must explain the offer accurately and preserve the honest empty inventory state, search/featured/Next Up navigation, fee calculator, FAQs, hosting CTAs and every footer/policy link. Existing teal/coral tokens, Space Grotesk, Plus Jakarta Sans and button styles remain the brand. No backend, fee logic, policy text or neighboring buyer-flow components are in scope.

Sources: supplied current product brief; `docs/COPY_GLOSSARY.md`; `docs/STRIPE_PROCESSING_FEE_OPERATIONS.md`; `Event#publicly_visible?`, `#private_preview_eligible?`, `#organizer_sales_verified?`; `OrganizerProfile.verification_gate_enabled?`; `OrganizationMembership` roles; browser scanner manifest/preparation/offline code in `pages/dashboard/ScannerPage.jsx`; cash sales in `pages/dashboard/BoxOfficePage.jsx` and `Commerce::OrderCreator`; `EventCancellationRefunds` and `config/policies.yml` cancellation remedy. `/config` returns 5.0%, 100 cents, platform processing bearer and `within 3 business days after your event`. Policy payout method: check unless another method is approved and recorded. These source files remain unchanged.

Historical context: Brain Dump `system/full-picture-2026-10-12.md:219` identifies the Ambros pilot; its older launch gates are superseded by the supplied Oct 27 brief. Repository `AGENTS.md` is untracked in the main checkout and absent in this worktree; its main-checkout instructions were read. Public QA does not use Clerk credentials or read `.env`.

## Environment and fixtures

Rails `http://localhost:3062`, Vite `http://localhost:5232`, Node 22.22.3, Ruby 3.3.4. Throwaway database `hafapass_prepilot_b`; identity asserted with `SELECT current_database()` before fixtures. Empty DB first, then four explicitly named QA events, one featured, belonging to a QA organization/profile with active owner membership. No real customer data, payments, sends, or production changes. Screenshots show local fixtures, not real HåfaPass events.

T3 preview opened but `preview_snapshot` failed twice with `Preview automation snapshot timed out after 15000ms.` Switched to local Playwright Chromium 156.0.8078.4. Browser resize verifies responsive web layouts, not physical-phone gestures, native keyboard or installed PWA behavior. Signed-in Clerk journeys are out of scope.

## Required scenarios

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

`before/` and `after/` contain full-page PNGs for each state/viewport. No photos are passed off as customer events. Final execution, automated gates, review and cleanup follow below.


## Execution evidence and limits

P01: `empty-results.json`; P02–P04: `interaction-results.json`; P05: `policy-navigation-results.json` (18 keyboard activations with the correct policy heading awaited) plus credits in `interaction-results.json`; P06: both result files and delayed-inventory/pricing CLS regression cases in `e2e/prepilot-public-pages.spec.js`. Normal-motion FAQ and local Host CTA destination are checked separately in `motion-cta-results.json`. All six cases passed their required responsive web dimensions. No physical-phone, installed-PWA, paid checkout or real Clerk session was exercised. Guest/signed-in CTA return behavior remains covered by Host unit tests using mocked Clerk. Locally, the blank Clerk key leaves the CTA at `/dashboard`, displaying “Please sign in to access the dashboard.”

| Viewport | Empty Home CLS | Populated Home CLS | Host CLS |
| --- | ---: | ---: | ---: |
| 375×812 | 0.0222 | 0.0185 | 0.0368 |
| 768×1024 | 0.0176 | 0.0176 | 0.0293 |
| 1280×800 | 0.0141 | 0.0117 | 0.0305 |

CLS measurements use the production-facing live-mode appearance in the isolated DB, without any payment actions. Before screenshots include the local simulated-payment test banner; after screenshots use live-mode appearance. This fixture difference is not a product change. A simulated-payment banner can add about 0.065 of pre-existing shell shift on mobile; its component and the motion block are outside this PR. New photos have explicit intrinsic dimensions; the only eager photo is the Home hero.

Retests: the original desktop photo-to-featured swap produced about 0.42 CLS. Home now resolves inventory before selecting its hero and offers a Browse Events link during loading. The Host config placeholder originally moved content; it now reserves the pricing/payout space. Both fixes were measured again at all sizes. The first e2e run found old eyebrow/one-footer-disclosure assertions; those were updated while retaining inventory and every-policy coverage. New image assertions wait for decoding, and featured-heading assertions distinguish the hero from the repeated Next Up title. One unchanged editor draft file timed out under parallel validation load; all 13 tests passed in an isolated rerun. The final full suites are recorded below.

## Photographs

All three are commercial-use CC BY photographs. Full source titles, authors, licenses and links are stored in `src/config/photoCredits.js` and rendered under Footer → Photo credits. WebP conversion/resizing is disclosed. No cropping or color edits were made. None represents a HåfaPass customer/event. Sources were visually inspected for Guam location, military/religious use and close-up identifiable minors. The night-market caption states its 2011 date.

| Photograph | Author | License | Commons source |
| --- | --- | --- | --- |
| Tumon sunset — “Sunset from the hotel's balcony. (49271977241).jpg” | Daniel Ramirez | CC BY 2.0 | https://commons.wikimedia.org/wiki/File:Sunset_from_the_hotel%27s_balcony._(49271977241).jpg |
| Chamorro Village night market — “チャモロ・ナイトマーケット - panoramio.jpg” | Junpei Abe | CC BY 3.0 | https://commons.wikimedia.org/wiki/File:チャモロ・ナイトマーケット_-_panoramio.jpg |
| “Tumon Bay from Matapang Beach Park.jpg” | Daniel Ramirez | CC BY 2.0 | https://commons.wikimedia.org/wiki/File:Tumon_Bay_from_Matapang_Beach_Park.jpg |

Each photo has 480, 800 and 1280 px variants. Largest files: sunset 39 KB, market 94 KB, bay 86 KB. Alt text and visible location captions live in `en.json`; other locales remain valid and use the existing English fallback for new keys. No paid translation was run.

## Scope held

Policy source/text and fee/pricing logic are untouched. Payout schedule interpolation and the existing FAQ timing are unchanged; the policy's check-payout method is stated without shortening its schedule. Competitors, endorsements, sales claims and customer imagery are omitted. `EventDetailPage`, `EventCard`, `CheckoutPage`, `TicketPage`, Navbar, the index.css motion block and ScrollReveal are untouched. Existing footer links and the approved mobile policy disclosure layout remain.


## Final gates and review handoff

Tested application source: `2a2253cf9955ed7187a47aae8a2277bac95bdc5b`. Subsequent changes are evidence/handoff documentation only.

- `npm run lint`: passed.
- `VITE_CLERK_PUBLISHABLE_KEY='' VITE_PUBLIC_WEB_URL='' VITE_API_URL='' npm test -- --maxWorkers=1`: 179 files passed, 1 existing skipped; 1,966 tests passed, 3 existing skipped (251.50 s). The sequential final run passed after the parallel timing issue and loading-state test updates.
- `npm run build:no-translate`: passed.
- `GT_API_KEY='' GT_PROJECT_ID='' npm run build`: passed; translator explicitly reported that credentials were absent and committed locale files were used. No paid translation.
- `PLAYWRIGHT_PORT=5232 npm run test:e2e -- --workers=1`: all 142 passed (3.2 min), including six new responsive photography/keyboard/CLS cases and existing empty-inventory/footer-policy coverage.
- Impeccable 4.6.0 advisory: `[]` (committed JSON). All locale files parsed; `git diff --check` passed; excluded-source/pricing/policy diffs empty.

PR: https://github.com/Shimizu-Technology/HafaPass/pull/163 (linked to the T3 thread). **Do not merge.** Main was fetched again and remained `c55601ad` before submission. GitHub CI and Netlify preview were started by the PR; their final remote state must be rechecked by the parent.

CodeRabbit did not review the code. Its required check is a gate: the bot returned “Review limit reached” at 2026-10-27 03:30:42 UTC, with the next included review available in 57 minutes. Evidence: https://github.com/Shimizu-Technology/HafaPass/pull/163#issuecomment-6433041331. Earliest stated retry is approximately 04:27:42 UTC / 14:27:42 Guam time. No material findings or review threads exist to address yet. No skipped/success-labelled check is represented as completed review. The implementation sub-agent does not watch or poll the PR; the parent should request `@coderabbitai review` after capacity resets, inspect the final-head coverage, fix material findings (about two substantive rounds), reply/resolve with evidence, and continue to hold the PR.

| Before | After | Why |
| --- | --- | --- |
| Empty desktop hero without a visual | Captioned Guam sunset | Gives the public page a real local setting without inventing events |
| Repeated feature/card sections | Price/calculator, worked examples, publishing story, door preview and local-help photo | Lets organizers understand cost and operation in order |
| Uppercase footer group labels | Readable sentence-case labels plus credits disclosure | Preserves the approved links and layout while improving legibility/attribution |

Runtime cleanup is recorded below after exact resource teardown. Keep the held branch/worktree for review; no resource is intentionally handed off.


Cleanup completed: lifecycle session `01a17b50-889d-7c23-850e-918895b32315` reports no active owned resources. Exact owned Rails PID 29578 (3062), Vite PID 33236 (5232), Chromium PID 37645 and its browser-server parent were stopped. The task-created T3 preview tab was closed and released. The throwaway `hafapass_prepilot_b` database was dropped and its absence verified. Shared PostgreSQL/Redis, Docker containers, LM services, other agents' listeners and the baseline simulator were left available. No resource handoffs or unresolved ownership remain. Branch/worktree are retained for the held PR.
