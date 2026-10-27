# The pass — public design QA

2026-10-27 · Agent executed · PR intentionally held for Leon’s screenshot review.

## Product brief and acceptance

HåfaPass helps people find Guam events, buy tickets as guests, and show a QR at the door. Organizers publish events, choose who bears fees, and run admission in a phone browser. This work makes the public site welcoming and recognizable through the ticket in the name and mark. Deep island teal, white ticket stock, coral actions, Space Grotesk and Plus Jakarta Sans remain the brand.

Sources: Leon’s task and approved Direction A plus B’s cards (`/private/tmp/claude-501/hafapass-home-directions.html`, opened in Chromium); repository Home/Host/Events/Ticket pages; PR #162/#163 at base `883b8b819c6c6df20b0b6d847a0e17d1651bf050`; Brain Dump `work/shimizu-tech/future-builds.md`, “HafaPass — Guam Event Ticketing Platform” (historical context only, dated May 4); verified `origin/main`, branch protection, and current code. Main deploys through Netlify; this PR must not merge. Production’s zero inventory is supplied by Leon, not independently queried here.

Acceptance: functional Home controls use the existing Events query contract; confirmed empty inventory has no marketplace controls; loading/outage remain distinct; all-in prices, fee math, policies, guest checkout and QR/Wake Lock stay intact. Shared notches/tear lines, responsive cards, visible keyboard focus, reduced motion, Axe and CLS <0.1 are required. Backend, pricing/policy utilities, workspace and admin UI are out of scope.

Implementation source: `3c5648a4290cc8f9b841648191fa3f738fa372a5`. Subsequent evidence-only commits do not change the tested public source.

## Environment and fixtures

Isolated T3 worktree on `codex/pass-direction`, branched after `git fetch` from current `origin/main`. Before screenshots are from the base above. After screenshots are from the implementation source above.

Node 22.22.3; Vite 5233; Rails 3063; API origin `http://localhost:3063/api/v1`. Fresh worktree dependencies installed. npm omitted the native Rolldown optional binding; its exact 1.2.14 package was fetched from the npm registry into this worktree’s node_modules. No dependency manifest/lockfile changes.

Throwaway database `hafapass_pass_dir`: created and schema loaded, SQL identity confirmed before [fixtures.rb](fixtures.rb) ran, three synthetic public events. The real API returned them. The real browser journey is recorded in [real-flow.txt](real-flow.txt): search + village → one matching event → select quantity → guest checkout → reload; no purchase submitted.

Repeatable screenshot/Axe/motion/focus matrix uses intercepted synthetic public events/config and a guest display ticket. It includes paid/free, art/date tile, long titles and venue names. The art fixture uses HåfaPass’s own OG image. The QR is synthetic. No Clerk credentials or production data are captured. Signed-in Clerk QA and physical iPhone/iPad testing are unavailable. Browser emulation does not establish native keyboard, safe-area, installed-PWA or rubber-band behavior.

Commands from `hafapass_frontend`:

```sh
node scripts/qa/pass-direction.mjs
node scripts/qa/pass-direction-stress.mjs
node scripts/qa/pass-direction-real.mjs
```

The last command expects the owned fixture DB/server above. Browser scripts close their contexts and browser processes in `finally`.

## Required journey ledger

| Case | Start → actions → expected outcome | Result and evidence |
| --- | --- | --- |
| P01 Empty Home | Successful empty response → inspect ticket, sheet, hosting and footer → no search/select/category/card lists; hosting and policies reachable | Passed, all five dimensions in Chromium/WebKit. [390](after/390-home-empty.png), [1280](after/1280-home-empty.png). |
| P02 Populated Home | Mixed catalog → fill search, choose weekend and Hagåtña, submit → `/events` retains `search`, `date`, `village` | Passed in both engines; real API journey also passed. [390](after/390-home-populated.png), [1280](after/1280-home-populated.png). |
| P03 Pending/outage | Hold inventory / fail it → browse or retry without false emptiness; hosting and policy links remain available | Passed in units and full Playwright, including existing service recovery/draft preservation. |
| P04 Cards | Paid/free, art/no art, long titles → swipe on phone; focus and Enter → event detail with browsing return state | Passed, Chromium native touch events and keyboard in both engines. [Row/focus](after/chromium-390-event-card-row.png). Art errors recover to the date tile. |
| P05 Host calculator | Loaded 5% + $1 fixture → choose $59, enter zero, enter invalid price → $62.95 buyer total / $55.05 absorbed proceeds; free stays zero; validation shown | Passed in both engines. Existing units retain rounding, unknown-processing, changed-rate and unavailable-config coverage. [390](after/390-host.png), [1280](after/1280-host.png). |
| P06 Host help/FAQ | Keyboard opens FAQ → explanation visible; support CTA → configured mailto | Passed in both engines. CTAs, FAQ and local help retained. |
| P07 List/event/checkout | Open list → event → choose ticket → guest checkout; filter return and estimate retained | Passed in full Playwright and real Rails journey. Sparse event pages now retain the reserved loading height, avoiding footer movement. |
| P08 Display ticket | Synthetic guest access → QR and details → inspect white QR, shared seam, surround; existing Wake Lock tests | Passed in both engines. [390 ticket](after/390-ticket.png). Credential, download and Wake Lock behavior unchanged. |
| P09 Focus | Tab/focus ticket selects/input/button and cards → fully visible ring, Enter works | Passed Chromium/WebKit. Control rings are inset from masks; card outline is on the unmasked outer link. [Controls](after/chromium-390-controls-focus.png). |
| P10 Motion | Normal load → rise 12px + opacity, settle in 280ms with out-strong; reduced motion → opacity only, fully visible afterward | Passed in both engines via live browser animation keyframes/finished state. CSS supplies the motion; no animation script gates content. Existing scanner entrance removed. |
| P11 Worst case | Long compound title + emoji, long/missing venue, one-word title, free/high prices, 1,000 tickets; 375px and 200% text → no document overflow | Passed. [Stress evidence](stress.txt), [Home](after/375-home-worst-case.png), [Host](after/375-host-worst-case.png). Physical phone coverage remains not run. |

11 required cases passed in the stated browser environment. Physical-device dimensions and signed-in Clerk journeys are not run; no claim of full-app or physical-device acceptance.

## Visual matrix

Each cell covers Home empty, Home populated, Host, events list, event detail, and guest display ticket. Every cell includes screenshots, horizontal document-overflow checks and WCAG 2 A/AA Axe.

| Browser | 375×812 | 390×844 | 768×1024 | 1280×800 | 1440×900 |
| --- | --- | --- | --- | --- | --- |
| Chromium | Passed | Passed | Passed | Passed | Passed |
| WebKit 27.2 | Passed | Passed | Passed | Passed | Passed |

60 page/dimension checks. Chromium measures Layout Instability; WebKit does not expose that observer, so its zero values mean unsupported, not a measured zero. Exact results are in [after/results.json](after/results.json). Maximum measured Chromium CLS: **0.01875**, below 0.1; WebKit CLS measurement is unavailable.

## Design re-audit

- Impeccable: `IMPECCABLE_NO_TELEMETRY=1 npx impeccable@4.6.0 detect --json` on changed public JSX, CSS and HTML. [Raw result](impeccable.json): `[]`.
- Taste: cloned `Leonxlnx/taste-skill` to `/private/tmp/hafapass-pass-taste`, revision `12af471f627f866411b4bd785b19646d3672784c`; ran its `skills/taste-skill/scripts/lint.mjs` on those same paths. [Raw findings](taste-lint.json), classified below. This scan is not represented as clean.
- Emil review: authored motion is rare and short; native scrolling; no added `transition: all`; hover gated to fine pointers; press responds on pointer-down; masked controls retain focus; reduced motion retains a fade; no decorative animation loop.

| Before | After | Why |
| --- | --- | --- |
| Borrowed photos dominate Home/Host | Brand-owned ticket stock, scanner fragment, type and color | The product carries the visual direction without implying event/customer photography. |
| Separate featured hero and rows | Featured upcoming events lead one card section | One clear browsing path with native phone swiping. |
| Masks could clip link outlines | Unmasked outer card link; controls inset within stock | Full keyboard focus remains visible in Chromium and WebKit. |
| Card headers differed with/without art; high price capsules overlapped the date | Equal headers, date-tile fallback and prices in the information stub | Seams align; artwork, dates and all-in prices stay readable. |
| Mobile implicit grid squeezed cards | Native flex track, snap and desktop grid | Card width stays usable on phones. |
| Pending inventory moved lower content | Reserved ticket/sheet footprint and delayed planning block | CLS stays below the required limit. |
| 200% text overflowed public navigation/local ticket | Wrapping public header and breakable ticket content | Large text stays within the page; workspace header remains untouched. |

Taste decisions: no decorative eyebrows, uppercase micro-labels, visible gradients, or monospace remain in the changed design. The four gradient matches are the explicitly required CSS alpha masks; they cut notches and draw no colored gradient. The two glass warnings are an existing single sticky event-buy bar (the rule permits one sticky bar) and the shared `.glass` definition, unused by the changed pages and retained for workspace consumers. Public header/search blur was removed. Hairlines, quiet shadows and outlined fields are functional form/calculator/status/navigation/footer treatments, allowed by this task; the shared button/field classes remain intact. Event category text is useful metadata, not a decorative eyebrow. `h-screen` warnings concern the unchanged Events minimum-height and the HTML boot fallback immediately followed by `100dvh`. Existing SEO title em dashes are separators, not added prose habits.

## Retest history

Initial screenshots exposed squeezed mobile columns and loading CLS; fixed with native flex scrolling, reserved space and the sparse-event minimum height. The extra 200% text pass exposed navigation/local-help intrinsic sizing; fixed and rerun. Initial unit failures from removed photo/featured assertions and extracted copy were updated to preserve the new functional contract. One full run hit an unrelated asynchronous legacy scan-export unit failure; it passed on focused rerun; the complete suite was rerun without browser contention. No scanner code was changed. A later full browser run timed out in `marketplace-growth.spec.js:196` while waiting after filter clearing (151/152 passed); this test had passed in three earlier full runs and passed its focused rerun in 1.5s. The complete suite was then rerun with two workers; the final result is recorded below. That rerun reached its last three workspace scenarios, then navigation itself timed out: the owned Vite process was stuck near 100% CPU and did not exit on SIGTERM. The exact owned PID was stopped and Vite restarted under Node 22; a complete fresh-server run followed with unchanged assertions. [Timeout log](initial-browser-timeouts.txt).

## Final automated gates and review

Final source `3c5648a4290cc8f9b841648191fa3f738fa372a5`:

- `npm run lint`: passed, zero warnings.
- `VITE_CLERK_PUBLISHABLE_KEY='' VITE_PUBLIC_WEB_URL='' VITE_API_URL='' npm test`: 180 files passed, 1 existing skipped file; 1,978 tests passed, 3 existing skips.
- `npm run build:no-translate`: passed.
- `PLAYWRIGHT_PORT=5233 npx playwright test --workers=4`: **152 passed, 0 failed (1.2m)** against the fresh Node 22 Vite server. No retries and no timeout overrides. The known event-day case passed without its special rerun.
- Matrix: **60 checks passed**, zero WCAG 2 A/AA Axe violations; Chromium max measured CLS **0.01875**. WebKit has no Layout Instability observer, as noted above.
- Real Rails guest journey, stress/max-price/200% text checks, and Impeccable/Taste/Emil re-audits completed as described above.

[Gate output summaries](gates.txt). PR #164: CodeRabbit automatic review started. The first remote hygiene check rejected the QA scripts’ result-printing calls; these were changed to standard output and `scripts/check_hygiene.sh` passed locally. This changes only QA reporting, not the tested public source. Remote checks continue on the updated head. PR stays unmerged. Backend, fee/pricing/policy logic and `hafapass_api/config/policies.yml` have no diff.

## Evidence credits

Only before screenshots retain the removed photos: Chamorro Village by Junpei Abe, CC BY 3.0 ([source](https://commons.wikimedia.org/wiki/File:チャモロ・ナイトマーケット_-_panoramio.jpg), [license](https://creativecommons.org/licenses/by/3.0/)); Tumon Bay by Daniel Ramirez, CC BY 2.0 ([source](https://commons.wikimedia.org/wiki/File:Tumon_Bay_from_Matapang_Beach_Park.jpg), [license](https://creativecommons.org/licenses/by/2.0/)). Prior app assets were resized/converted to WebP; QA evidence is a page screenshot. No borrowed photograph ships in the resulting UI.

## Cleanup

Completed: owned Vite 5233, Rails 3063 and mockup server 5234 stopped; preview tab closed; Playwright contexts/workers closed. The throwaway DB was dropped and `pg_database` confirms zero databases named `hafapass_pass_dir`. Lifecycle session `01a17c2b-3385-77a3-818d-5d27974ab67a` reports no active owned resources. No runtime handoffs. Baseline databases/Redis/Docker/home services were left running. The held branch/worktree remain for Leon’s review.
