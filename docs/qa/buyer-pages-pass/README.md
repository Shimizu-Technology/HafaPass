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
| B01 Empty inventory | Confirmed empty Events/Discover → hosting stub → Host; no search/filter controls or unclear home label | Passed in stated browser fixtures; final-head rerun pending |
| B02 Browse/filter | Populated Events → search/category/date/price/village + reload + pagination → preserved query and matching cards | Passed in stated browser fixtures; final-head rerun pending |
| B03 No-match/outage | Empty filtered response / failed API → clear/retry → restored catalog, preserved filter context | Passed in stated browser fixtures; final-head rerun pending |
| B04 Discovery | Curated collections → view all → collection pagination → event; empty collections with inventory remain distinct | Passed in stated browser fixtures; final-head rerun pending |
| B05 Tickets empty | Empty account fixture → recovery → reference/email form; Browse events → Events | Passed in stated browser fixtures; final-head rerun pending |
| B06 Tickets populated | Issued/used/blocked/transfer fixtures → compact pass + open ticket; tabs and keyboard + reload; install disclosure; account link | Passed in stated browser fixtures; final-head rerun pending |
| B07 Saved | Empty useful instructions; populated cards/organizer/reminder → correct destination; failed API → retry | Passed in stated browser fixtures; final-head rerun pending |
| B08 Consistency | Event → choose quantity → checkout; synthetic confirmation → ticket; correct header/theme/seams/sentence case | Passed in stated browser fixtures; final-head rerun pending |
| B09 Accessibility/craft | All matrix scenes → axe AA, no overflow, CLS <0.1 in Chromium; visible keyboard focus and ≥44px changed targets | Passed in stated browser fixtures; final-head rerun pending |
| B10 Worst case | Long/one-word/multilingual/missing venue/type/attendee/large list → 320px + 200% text; demo/worst toggle fixture | Passed in stated browser fixtures; final-head rerun pending |

Automated gates and design re-audit results will be recorded separately. Implementation source, final head, reviewer coverage and cleanup will be added after execution.

## Design re-audit and initial defects

Impeccable 4.6.0: no findings in 11 changed UI paths (`impeccable.json`). Taste scan: no eyebrow, gradient, glass or uppercase-label findings. Existing header dividers/sticky shadow and order/receipt table dividers remain deliberate; the unchanged account-preparation `min-h-screen` is outside this layout pass. The new tabs’ shadow was removed. Raw findings are in `taste-lint.json`; these advisory rules do not override the approved ticket seams or usable receipt rows.

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
