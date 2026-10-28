# Production audit fixes

2026-10-29 · Agent-executed affected-flow QA · Hold for lead merge and manual Render deploy.

HåfaPass serves Guam event buyers, guest purchasers, organizers and door staff. Buyers must browse, buy without an account, recover orders, and present tickets. This patch refines PR #164's light ticket/pass direction: deep teal header, coral actions, Space Grotesk headings and Plus Jakarta Sans body. No new motion; mobile filter disclosure changes immediately and preserves query state.

Sources: lead's approved production audit and constraints; main `a1877f98d64a4ae2f2138ae87ae997b9541ff974`; `docs/qa/buyer-pages-pass/README.md`, `docs/qa/prepilot-buyer-path/README.md`; current Navbar/Layout/eventTime/Host/Clerk code; historical Brain Dump `work/shimizu-tech/future-builds.md` §13 and `company-positioning-and-project-review-2026-10-04.md` (pilot launch gates). Local main matches the supplied live release; production identity is supplied by the lead. Netlify auto-deploys main; Render is manual.

Acceptance: all ten approved items, without policy templates, fee/payment changes or production data updates. Keep Clerk's free-plan badge and support mailbox. Auth return paths, guest recovery, filter/reload state, multi-day and DST dates, saved ticket outcomes and scanner camera/payment permissions must remain correct. Both Netlify config passes must agree. PR stays unmerged.

Environment: isolated `/Users/leonshimizu/.t3/worktrees/HafaPass/t3-427f2a70`, `codex/audit-fixes`; Rails 3071, Vite 5241; synthetic PostgreSQL `hafapass_audit_fixes_test`. Browser matrix: Chromium/WebKit, 390×844, 1024×768, 1280×800. No-Clerk dev route behavior and intercepted synthetic APIs reuse the buyer-pages harness. Fixtures do not prove live Clerk, payment/provider delivery, or physical-device keyboard/gesture behavior. Baseline resources are borrowed/protected. Lifecycle session `01a184ba-b1db-7112-aa1c-f77b6baf563c` owns only resources it starts.

| Case | Fixture → action → expected observable outcome | Result |
| --- | --- | --- |
| A01 Auth | No-Clerk shell + component fixture → sign-in/up → correct SEO/theme, branded copy/inline links, return paths retained | passed within fixture/device limits |
| A02 Guest navigation | Signed out → Find my tickets / Sign up → recovery / sign-up; mobile keyboard close | passed within fixture/device limits |
| A03 Navigation fit | Signed out + organizer/admin fixture → 1024/1280 → breakpoint, one row, no overlap | passed within fixture/device limits |
| A04 Share/icons | Render OG/favicon → inspect → contrast, brand, dimensions, routes/precache | passed within fixture/device limits |
| A05 Footer | Company/support links → clear external destination, one support action and original mailbox | passed within fixture/device limits |
| A06 Payouts | Config → Host/fee/finance/payout method → by check + configured timing; fresh DB default updated | passed within fixture/device limits |
| A07 Headers | Both Netlify passes → security headers + preview no-referrer override | passed within fixture/device limits |
| A08 Buyer flow | Event → quantity → checkout → fixture confirmation/ticket → compact footer, fee once, zone once, neutral type | passed within fixture/device limits |
| A09 Filters | Mobile Events → disclose/select/reload/clear → active count, query/results retained; desktop unchanged | passed within fixture/device limits |
| A10 Empty inventory | Events/Discover → balanced pass/Host action; loading/error/no-match distinct | passed within fixture/device limits |
| A11 Live integrations | Live Clerk login/signup, payment/email, production payout setting/policy approval | not_run (lead/operator scope) |

Required affected-flow cases A01–A10 passed within the boundaries below; A11 remains not_run. Engineering gates and hosted review status are recorded separately.

## Implementation map

1. Auth: `src/config/clerkAppearance.js` centers the sentence/link row and keeps the inline link ≥44px; partial Clerk localization covers normal and combined flows. `ClerkProviderWrapper.jsx` supplies it. `SignInPage.jsx` / `SignUpPage.jsx` use SEO/noindex even when configuration is unavailable. `utils/headerTheme.js` also controls the generated pre-React header, including nested auth paths. Verified against installed Clerk React 5.61.9 and `@clerk/shared` LocalizationResource start keys; [Clerk localization reference](https://clerk.com/docs/guides/customizing-clerk/localization). Branding remains enabled.
2. Guest access: `Navbar.jsx` adds `/orders/recover` to the shared desktop/mobile link list and labels optional registration “Sign up.” English keys/metadata are in `locales/en.json` and `en.metadata.json`; other languages retain the existing English fallback.
3. Breakpoint: signed-out public nav uses `lg`; signed-in public nav retains `xl` for My Tickets/Saved/Scanner/Dashboard/Admin. Search opens without consuming the header's row width. Workspace header behavior is unchanged. Both roles/engines fit at 1280; 1024 uses the signed-in menu, with all links available.
4. Share assets: `public/og-default.svg`, `og-host.svg` contain outlined Space Grotesk/Plus Jakarta Sans glyphs from the bundled OFL fonts; JPGs remain 1200×630 at the existing URLs. `scripts/qa/audit-share-images.py` generates the vectors from repo root with Python FontTools/Brotli. Rendered with `/opt/homebrew/bin/rsvg-convert`, then `magick -quality 92`; no runtime fonts required. Both JPGs inspected.
5. Favicon: new SVG, 96px PNG and ICO (16/32/48) use the existing ticket mark. `index.html` links real paths and preserves apple/PWA icons. `_redirects` lists those assets before the SPA fallback. Existing injectManifest globs retain all three; `src/sw.js` excludes direct favicon navigations from HTML fallback. Offline navigations prove image responses, including ICO. SVG, PNG and ICO sizes inspected.
6. Footer: `Footer.jsx` identifies Shimizu Technology with an external-link icon and a screen-reader new-tab description; duplicate Contact removed. Configured support remains `shimizutechnology@gmail.com`.
7. Payouts: Host English hero/FAQ, `FeeTermsNote.jsx`, `dashboard/FinancesPage.jsx` and `PayoutMethodSection.jsx` say by check. `SiteSetting::DEFAULT_PAYOUT_SCHEDULE_TEXT` changes only future singleton creation to “within 3 to 5 business days after your event.” Existing rows and historical migration defaults remain untouched. Affected fixtures/assertions updated; policy templates/digests remain dynamic and unchanged.
8. Headers: root/frontend `netlify.toml` agree. `scripts/qa/audit-netlify.mjs` resolves modern + legacy passes with `@netlify/config` and uses Netlify CLI's own parser/`headersForPath` to verify effective public + preview headers. `netlify-config.json` records both. Camera code uses video only; no microphone/geolocation consumers found. CSP includes only `frame-ancestors`. [Netlify header reference](https://docs.netlify.com/manage/routing/headers/).
9. Buyer polish: `Layout.jsx` omits the marketing footer in checkout; existing in-flow legal links remain. `CheckoutPage.jsx` removes repeated per-line fee copy. `utils/eventTime.js` supplies zone-once ranges to Event detail/cards/checkout/confirmation/ticket, with multi-day end dates and differing DST labels preserved. Ticket type uses brand emphasis. `EventsPage.jsx` collapses only mobile selects behind an accessible counted disclosure; query state still drives requests/reload. Events/Discover confirmed-empty tickets are centered.
10. Scope: no edits to `config/policies.yml`, PolicyRegistry templates, pricing/fee calculations or payment behavior. No production data, setting, policy approval, deploy or merge performed.

## Visual and interaction evidence

`before/`: 84 scenes at baseline `a1877f98`; `after/`: 84 corresponding scenes plus 24 synthetic component/role contract scenes. Both engines × 390×844 / 1024×768 / 1280×800. Fourteen scenes per dimension: Home, Events empty/populated/filters-open, Discover empty, Event, Checkout, Confirmation, Ticket, Sign in, Sign up, Host, mobile menu, footer. Desktop “mobile menu” scenes intentionally show the full signed-out header. PNGs include full pages; footer cases capture the scrolled footer. All six engine/width contact sheets and representative full screenshots were inspected. Zero axe A/AA violations and no document overflow in 84/84 after scenes. Closed header height is 65px, matching boot shell. Measurements are in `after-{chromium,webkit}-results.json`; baseline files are separate.

Contract fixtures use real application modules/styles with a synthetic SDK adapter, visibly labelled in the screenshots. They verify localization text, ≥44px auth link rectangles, sentence alignment, return URLs and unchanged branding text; they **do not establish actual Clerk SDK rendering or authentication**. The no-key screenshots verify real unavailable behavior. Live Clerk sign-in/sign-up remains **not_run**, as do real payments/provider delivery and physical phone keyboard/gesture/PWA behavior. `contract-results.json`: 24/24 passed. Real WebKit guest/header/filter interactions: 3/3 passed, including keyboard menu close and query persistence across reload. Chromium counterparts are part of the full suite.

## Findings and limits

- **Existing out-of-scope material bug, not fixed:** on `/events`, submit the header search for `music`; Events' existing URL synchronization replaces the new query with its mounted filter state. The URL returns to `/events`. `out-of-scope-search.txt` preserves the failing observation. Header search from a different route is not implicated by this reproduction. The task explicitly forbids unrelated fixes; the lead should schedule a focused Events URL/state fix.
- The initial unit run began before the new auth SEO locale keys were added, so its already-loaded i18n resource returned the new key names. The fresh full run supersedes it. `unit-initial.txt` retains that failure.
- Initial PWA test treated ICO as octet-stream because the fixture server lacked an ICO MIME entry; Chromium correctly started a download. The fixture now serves image/x-icon and the full PWA rerun passes. `pwa-initial.txt` retains the failure.
- Initial WebKit interaction assertion used “Find your tickets” instead of the existing destination heading “Find your order”; corrected assertion passes. No recovery page copy changed.
- Impeccable 4.6.0 reports `[]` for all changed UI paths. Approved ticket seams, brand palette and existing footer/header separators retained. No new animation; disclosure is immediate. Live device feel and installed-app safe areas remain not_run.
- Local install required Node 22.22.3 and a fresh `npm ci --include=optional` to populate Rolldown's macOS binding; lockfile and dependencies are unchanged. FontTools/Brotli were installed only in `/tmp/hafapass-audit-fonts` for vector generation.


## Frozen source and local gates

Application source frozen in `0c6f517897073e08b8015c4ac511f5783d4737ad`; later commits add QA assertions/harnesses only. Final complete browser/build source is `33df619110953dfcf06ac22c966631f592abc498`. Build `dist/release.json` identifies that exact revision. Baseline screenshots use `a1877f98`; after screenshots use the frozen application changes. The final PR head may be an evidence-only descendant.

| Check | Result |
| --- | --- |
| ESLint (`npm run lint`) | passed, zero warnings |
| Frontend full units (`VITE_CLERK_PUBLISHABLE_KEY='' VITE_PUBLIC_WEB_URL='' VITE_API_URL='' npm test -- --maxWorkers=1`) | 2028 passed, 3 pre-existing skips; 182 files passed, 1 skipped |
| Production build (`npm run build`, same empty VITE variables) | passed; translation step safely used committed locales; revision `33df6191`; 69 precache entries including favicon SVG/ICO/PNG |
| Full Chromium Playwright (`PLAYWRIGHT_PORT=5241 npx playwright test --workers=1`) | 191/191 passed, one worker, stock timeouts, no retries/skips |
| WebKit guest/filter interactions | 3/3 passed, stock timeouts |
| Existing responsive discovery regressions | 4/4 passed at 320/390/768/1440 after updating the test to open the disclosure; original text-fit/reload checks retained |
| Production SW/PWA suite | 2/2 passed; includes direct offline SVG/PNG/ICO navigation, deploy update, protected scanner and offline shell |
| Backend affected RSpec | 40 examples, 0 failures |
| Backend complete RSpec | 3549 examples, 0 failures (16m38s); no concurrency rerun needed |
| Backend quality/security | RuboCop 978 files, zero offenses; Brakeman zero warnings/errors; bundler-audit zero vulnerabilities |
| Production npm dependency audit | zero vulnerabilities |
| Repository hygiene / freeze contract | passed; freeze inactive |
| Netlify config + effective headers | both passes passed, with Netlify CLI header matching; favicon redirects present in final build |
| Impeccable 4.6.0 | `[]`, no findings |
| Visual matrix / component contracts | 84/84 after scenes, zero axe violations/overflow; 24/24 contracts |
| Real Rails fixture journey | passed: 2 matching-title events in Hagåtña/Yigo → Home search + Hagåtña filter → exactly 1 matching card → quantity → guest checkout → reload retains checkout. No order/payment submitted. |

The initial complete Chromium suite finished 189/191; two older mobile discovery tests assumed selects were always visible. They now assert the collapsed first-card position, open Filters, preserve all original readability/layout checks, then reopen the four-active-filter disclosure after reload. The focused four-width run passes; the final entire suite passed 191/191 with one worker, unchanged default timeouts and no retries/skips. `playwright-initial.txt` retains the initial failures. The scanner flake named in the task did not occur in that run.

Reproduce the config check from repo root with `NETLIFY_CONFIG_MODULE` pointing to an installed `@netlify/config` module and `NETLIFY_HEADERS_MODULE` pointing to Netlify CLI's `dist/utils/headers.js`, then `node hafapass_frontend/scripts/qa/audit-netlify.mjs`. This run used config 24.3.0/headers-parser 9.0.2; it asserts effective headers for `/events` and `/events/qa/preview` without starting a deploy. Generated artwork: `uv run --with fonttools --with brotli python hafapass_frontend/scripts/qa/audit-share-images.py`, then rsvg-convert SVG→PNG and ImageMagick PNG→JPG. Runtime fonts are not involved.

## Resource disposition and lead handoff

The task's T3 preview tab was closed/released; every fixture browser context closes in `finally`. Rails 3071 stopped and PostgreSQL `hafapass_audit_fixes_test` was deleted (verified zero matching databases). Vite 5241 was stopped through the lifecycle helper. `resource-cleanup.txt` records final status; no intentional runtime handoffs. Shared Postgres/Redis, Docker services, model services and baseline browser/app resources were left unchanged. The isolated branch/worktree remain for lead review and merge.

No production release was performed. After review/CI, the lead merges the held PR, verifies Netlify headers/assets (including private preview no-referrer), deploys Render manually as needed, updates the existing production payout setting, and re-approves the policy register. A fresh default does not mutate an existing SiteSetting. Live Clerk auth and physical-device behavior still require operator verification. The existing header-search bug remains a separate task.

## Round 2 — lead review fixes

2026-10-29 · Agent-executed affected-flow QA. Starting worktree was clean at remote `fbd4ec4ba1f6eb746b3dd504790e73c455440dac`; base remains `main`. This round refreshes the app brief above using the current source and the lead's required findings. Brain Dump `work/shimizu-tech/future-builds.md` §13 still describes Guam event setup, ticket purchase/reservation and QR check-in. No backend changes, deployment or merge are authorized in this child.

Required acceptance: card date/time icons stay with their text at 320/390/1024/1280, including three-column grids; buyer selects retain labels, ≥44px height, 16px type, border/padding/chevron and keyboard focus in Chromium/WebKit; Events filters and admin filters survive reload; organizer select edits survive draft reload; checkout retains fee/legal content and reachable configured email/phone help, keeps “Guam time” together and fits at 320px. Fixtures reuse the isolated no-Clerk development shell and intercepted APIs. Authentication, physical iOS hardware, real payments and provider delivery remain not_run.

| Case | Starting fixture → action → required outcome | Round-2 result |
| --- | --- | --- |
| R2-01 Cards | Three published synthetic events → Home/Events/Discover at 320/390/1024/1280 → separate date/time rows, aligned icons, no overflow; three-up at 1024/1280 | passed |
| R2-02 Buyer selects | Home + Events → disclose/filter/focus/reload → consistent styled controls, selected labels fit, query state retained | passed |
| R2-03 Workspace selects | Synthetic admin refund queue + organizer create-event form → select/reload → status filter and age-restriction draft retained | passed |
| R2-04 Checkout | Synthetic event → quantity → checkout → configured support links, zone together, fee once, legal links retained, no marketing footer/overflow | passed |

Application and QA source frozen in `1c30f3626a7cd881aeb5dc0643ffe8c81f5bae66`; the production build's `dist/release.json` identifies that revision. Final ledger and image evidence will be a descendant. Final local gates passed; hosted CI and review of the new head remain lead gates. Round-1 history above is retained; its screenshots for changed scenes are superseded by the round-2 matrix.


Round-2 implementation:

1. `scripts/qa/audit-fixes-contracts.mjs` and `scripts/qa/audit-netlify.mjs` use `console.info`; tracked-file hygiene and freeze checks pass. The round-1 hygiene claim was stale once the QA scripts were tracked at `fbd4ec4b`; `round-2-hygiene.txt` supersedes it.
2. `src/components/EventCard.jsx` gives calendar/date and clock/range separate flex rows. Icons cannot shrink or wrap away from their text; long venue names also retain their map pin. Browser assertions check first-line alignment and the three-column grid.
3. `src/index.css` styles single-value `select.input` controls with `appearance: none`, a background SVG chevron, ≥44px height, 16px type and reserved chevron padding; existing borders, radius and focus ring remain. Multiple/size listboxes retain their existing treatment. Home removes duplicate chevrons and stacks the controls below `sm`; Events stacks filters below 400px so selected text fits. Discover has no selects; its cards receive the metadata fix. The shared rule also covers checkout registration and order-exchange selects. Custom admin controls outside `.input` are unchanged.
4. `src/pages/CheckoutPage.jsx` renders quiet configured email/phone help outside the checkout state branches, including unavailable/recovery/loading views. It uses the same `useSupportContact`/`mailto()`/`tel` data as Footer. Support remains `shimizutechnology@gmail.com`; the phone comes from config. `src/utils/eventTime.js` keeps the non-breaking space only in buyer time ranges, preserving standalone/operations timestamp strings. No fee math, payment behavior, policy templates or backend files changed.
5. CodeRabbit's `fbd4ec4b` review requested four changes. Hygiene and checkout support overlap the lead's findings. `audit-netlify.mjs` now checks all three favicon mappings' `from`, `to`, status and uniqueness in **both** resolved configurations. `formatPayoutSchedule` in `utils/feeTerms.js` is shared by FeeTermsNote, FinancesPage and PayoutMethodSection; it preserves existing terminal punctuation, adds a period when needed and omits punctuation-only schedules. Nine new cases include question marks, ellipses and empty values. Display formatting does not change stored settings or approved policy text. All four findings are accepted; there are no false-positive replies.

Retest history: the first unit run returned 2024 passed / 4 failed / 3 skipped after the overly broad non-breaking-space change affected a scanner text matcher and raw formatter expectations. The final implementation confines the space to `formatEventTimeRange`; the fresh frozen-source run supersedes that run. Initial admin fixture checks used an exact implicit-label locator that included option text; accessible combobox-name locators now pass. Initial marketplace tests assumed the two mobile selects shared a row; the tests now verify stacked alignment below 400px and retain their original text-fit, requested-filter and reload checks. Intermediate unit/matrix runs were stopped or superseded when the published review and final long-venue fix changed source; those partial runs do not establish acceptance.

The T3 preview opened, then snapshots failed twice with `Preview automation snapshot timed out after 15000ms.` Its task-owned tab was closed and released. The requested Playwright harness supplies the browser evidence. No live Clerk credentials or production records were used.


Final visual matrix: **56/56 scenes passed**, with zero axe A/AA violations and zero document overflow. Both engines × 320/390/1024/1280 cover Home, Events populated, Events filters open, Checkout, Discover populated, admin refund filters and organizer create-event selects. Measurements, focus-ring checks, label fit, date/time/location alignment, checkout zone rectangles and workspace reload outcomes are in `round-2-{chromium,webkit}-results.json`. Screenshots replace the 24 existing `after/{chromium,webkit}-{390,1024,1280}-{home,events-populated,filters-open,checkout}.png` files and add 32 scenes for 320px, populated Discover and workspace forms. Representative full WebKit and Chromium images were inspected, including 320px filters/Home/checkout, 390px checkout/workspace forms and the 1024/1280 three-up grid. Other round-1 screenshots remain historical evidence.

The 56 images establish layout and isolated interactions in browser engines; WebKit desktop emulation is not physical iOS Safari testing. The admin and organizer shots use the existing no-key dev shell plus intercepted synthetic APIs. No production filter, event, payout or customer record is changed.


Local final-source gates completed so far: ESLint (zero warnings), production build (69 precache entries), repository hygiene, inactive release-freeze contract, both Netlify config/header/favicon passes and Impeccable 4.6.0 (`[]`). The review-focused unit run passed 82/82; it includes scanner timestamp compatibility, finance rendering and the formatter edge cases. The completed frontend/browser counts are recorded below. Backend checks were not rerun because this round changes no backend files; round-1 backend evidence above remains historical.


| Final check at source `1c30f362` | Result / evidence |
| --- | --- |
| Frontend lint | passed, zero warnings; `round-2-lint-final.txt` |
| Frontend full units | **2037 passed, 3 pre-existing skips**; 182 files passed / 1 skipped; `round-2-unit-final.txt` |
| Production build | passed; release revision `1c30f3626a7cd881aeb5dc0643ffe8c81f5bae66`, 69 precache entries; `round-2-build-final.txt` |
| Full Chromium Playwright | **202/202 passed**, one worker, stock timeouts, no retries/skips; `round-2-playwright-final.txt` |
| Affected Chromium specs | **57/57 passed** at final source; audit-fixes, marketplace-growth, buyer-layout, buyer-pages-pass, buyer-phone-access and event-editor-validation; `round-2-affected-final.txt` |
| WebKit affected interactions | **14/14 passed**, including admin filter/organizer draft reload and checkout configuration failure; `round-2-webkit-final.txt` |
| Requested scanner rerun | **2/2 passed** in one rerun of both parameterized scanner/offline cases containing the assertion at `event-day.spec.js:80`; `round-2-event-day-rerun.txt`. No flake occurred in the full run. |
| Browser visual matrix | **56/56 passed**, zero axe violations/overflow; `round-2-{chromium,webkit}-results.json`, `round-2-visual-final.txt` |
| Hygiene / freeze | passed / inactive; `round-2-hygiene.txt`, `round-2-freeze.txt` |
| Netlify config / favicon contracts | both passes passed; `round-2-netlify.txt`, `netlify-config.json` |
| Impeccable 4.6.0 | `[]`, no findings across all changed UI paths; `round-2-impeccable-final.json` |

Required round-2 affected-flow acceptance: **4/4 cases passed** in the documented synthetic/browser boundaries. Live Clerk authentication, physical phone input/installed-app behavior, real payments/provider delivery and production setting/policy updates remain not_run. The pre-existing mounted Events header-search issue remains outside this round's scope.

CodeRabbit reviewed `fbd4ec4b` and requested four actionable changes; all four are addressed by this round. Final-head incremental review will be requested once after push; it is **pending**, not reviewed clean. No merge or deployment is performed. The lead must inspect hosted checks and final-head review before merging. Existing production payout timing and policy approval still need the lead's planned update.

Resource disposition: all task-owned Vite and browser runner resources were stopped or exited after verification; fixture contexts/browsers close in `finally`. The T3 tab was closed and released. `round-2-resource-cleanup.txt` records the final lifecycle state. No runtime handoff; borrowed/shared/protected services and data were left unchanged. Keep the named branch/worktree for the lead.
