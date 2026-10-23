# Visual polish acceptance — 2026-10-23

> The round-two record below supersedes the original zero-event and footer design acceptance. Earlier captures and results remain as history.

Base: `1548e8f3` (PRs #147–149 included). Branch: `codex/hafapass-visual-polish`. Hold; do not merge.

HåfaPass serves Guam event buyers, organizers running sales/admission, and platform administrators. Public inventory is eligibility-controlled; an empty search or failed API call must never claim the whole marketplace is empty. Clerk owns authentication, Rails owns roles/inventory, and existing commerce/verification restrictions remain authoritative. Sources: README, CLAUDE.md, Home/Events/Collections pages, Rails event/collection scopes, recent Git history; Brain Dump `work/shimizu-tech/company-positioning-and-project-review-2026-10-04.md` identifies paid launch/pilot closeout as gated. This change makes no launch or availability promise.

Experience: retain existing fonts, teal surfaces, red primary actions, and calm operational UI. No hero imagery or new motion. Confirmed empty inventory gets one clear host action; populated listings retain browsing. Footer keeps every existing text/link. Parallel wording scope is excluded. `hafapass_api/config/policies.yml` is excluded.

Agent-executed affected-flow QA plus the requested signed-in visual sweep. Fixtures are isolated in `hafapass_visual`; API 3055 / Vite 5225. Local Clerk test admin; no real payments, emails, or production writes. Required viewports: 375×812 and 1280×800. Physical phone keyboard/gestures/browser chrome remain not run unless a real phone becomes available.

| Case | Starting fixture and steps | Expected result | Status |
| --- | --- | --- | --- |
| V01 | Hide local public events; open Home, Events and Discover | Honest empty state, host CTA to /host, no empty category/filter browsing | Passed |
| V02 | Restore published events; browse/search/filter and Discover | Normal layout returns; no-match filters remain usable; collections-empty still permits browsing | Passed |
| V03 | Open sign-in/sign-up at 375; inspect Google, reveal-password and account switch | At least 44px hit areas; no horizontal overflow | Passed |
| V04 | Open footer; keyboard/touch policies and recovery links | Compact mobile footer, every link reachable, tidy desktop | Passed |
| V05 | Cold-load public/workspace routes and slow requests | Stable page shell/minimum content height; no obvious footer collapse | Passed |
| V06 | Local admin's organizer workspace: dashboard/profile, event overview/edit, tax/payout settings, finances, scanner, box office | No page overflow, clipped actions, small icon targets or illegible contrast; preserve input/context | Passed |
| V07 | Admin dashboard, organizer queue, payouts, settings | Same visual expectations; material workflow issues reported separately | Passed |

Evidence: `/tmp/hafapass-visual-polish/{before,after}`. Automated gates and execution results will be appended after verification. Owned resources must be stopped, browser tabs closed, and the database dropped before delivery.

## Execution and evidence

The final application source passed 1,783 Vitest tests (164 files), ESLint, the production build, production dependency audit (0 vulnerabilities), release-freeze contract (inactive), and secret/debug hygiene. Impeccable 4.6.0 returned `[]` for the changed UI paths. Node 22.22.3 and Ruby 3.3.4 were used. Backend implementation is unchanged; local RSpec/security checks were outside this frontend-only change. GitHub runs those required checks separately.

The full final 99-test Playwright suite passed, including axe, the existing missing-event CLS < 0.1 checks at 390/1280, and two Discover loading cases at the requested 375/1280 widths. The Discover cases compare settled footer positions before and after a delayed response and confirmed empty inventory. New empty-inventory browser cases cover Home, Events (including a filtered URL), Discover, normal browsing after inventory returns, no-match recovery, all six policy links by keyboard, no horizontal page overflow, and axe serious/critical violations.

Initial failures were retained in `/tmp/hafapass-visual-polish/`: a live local Clerk key contaminated unit fixtures; the final run explicitly clears the three local Vite deployment variables to match CI. The affected fake-locale expectation and two browser assertions were updated for the deliberate empty state. The search-draft recovery test now uses populated inventory, preserving its original shell/draft recovery purpose. The successful reruns supersede those failures.

Local Rails fixtures were seeded in `hafapass_visual`: ten events (nine published), organizations, orders and tickets. Events were temporarily made drafts for zero-inventory checks, then their saved statuses were restored. One seeded organization was placed in the verification queue for the populated admin check. No production records or policies were changed. The existing Clerk development test admin was used; password login reached new-device verification, so a short-lived Clerk sign-in ticket established the same existing account for the signed-in visual pass. No new Clerk user was created. No sales, refunds, tax certifications, payout approvals, or campaign sends were submitted.

All requested workspace screens were opened with the real API and Clerk session at both widths: dashboard/profile editor, event overview/edit, tax form, check/bank payout setup, finances, scanner, box office, admin dashboard, populated verification queue, event queue, payouts and settings. Twelve explicit interaction/geometry checks passed across the two widths: profile close, expanded tax form, bank-transfer form, populated verification queue, scroll containment, and featured-button hit area. Other named screens passed the visual/overflow pass; this is not acceptance of money movement, admission hardware, or real message delivery.

Measured outcomes:

- Clerk at 375: Google 261×44; password visibility 44×44; Sign up 46.3×44; Sign in 44×44.
- Footer at 375: 1,154.5px → 575.5px. At 1280: 609px → 414px. All existing footer strings and links remain.
- Admin event queue at 375: document width 700px → 375px. Its independently scrollable results retain all columns, with keyboard access and 44px featured/pagination controls.
- Profile close: 44×44. Editor reorder controls: at least 44×44. Short preview/clone/postpone and box-office input controls now meet the 44px height target.
- Admin dashboard small action text uses brand-700; the analytics recovery link and profile-upload action also use the darker token. The analytics recovery link changed from 20px to 44px high.
- Browser theme metadata follows the actual header: dark Home at the top, white on other routes and when Home's header turns white on scroll. Physical browser chrome remains unverified.

Public before/after PNGs are committed under `docs/qa/visual-polish/{before,after}` with names `{375,1280}-{home-empty,events-empty,discover-empty,sign-in,sign-up}.png`.

The full local matrix is `/tmp/hafapass-visual-polish/{before,after}`. For each width, paired captures include `dashboard`, `profile-editor`, `event-overview`, `event-edit`, `settings`, `finances`, `scanner`, `box-office`, `admin-dashboard`, `admin-queue`, `admin-payouts`, `admin-settings`, and `analytics-error`. Expanded `tax-form`, `payout-bank-form`, and `admin-verification-queue` captures are also saved after the pass. JSON beside captures records page width, headings and small controls; `journeys.json` records the twelve explicit checks. Protected captures stay local; the public evidence directory contains signed-out screens.

## Limits and follow-up

- No approved hero imagery was added; asset selection remains a follow-up.
- Real iOS/Android hardware, software keyboards, gestures, safe areas and installed-PWA/browser-chrome behavior were not run. The tested mobile dimension is a Chromium viewport, not a hardware sign-off.
- No larger redesign was attempted. Source follow-up: the existing profile editor is a custom overlay without dialog semantics, a focus trap or an Escape handler (`DashboardPage.jsx`, `EditProfileModal`). Its close control is now 44×44 and was exercised, but converting the overlay to the shared accessible dialog is separate behavior work. The visual/target pass does not claim that modal keyboard behavior is accepted.
- Hold the PR unmerged. CodeRabbit is a required repository check; pending, skipped or rate-limited review is not approval. The parent task owns CI/review continuation after the implementation sub-agent returns.

## Final local run

- `npm run lint`: passed.
- `VITE_CLERK_PUBLISHABLE_KEY='' VITE_PUBLIC_WEB_URL='' VITE_API_URL='' npm test`: 164 files / 1,783 tests passed.
- `VITE_API_URL='' VITE_PUBLIC_WEB_URL='' PLAYWRIGHT_PORT=5225 npm run test:e2e -- --workers=4`: all 99 passed, 54.9s. This final full run supersedes earlier assertion/fixture failures. The Discover geometry assertion reads after the committed classes reach a settled browser layout frame.
- `npm run build`: passed. `npm run audit:prod`: 0 vulnerabilities.
- `IMPECCABLE_NO_TELEMETRY=1 npx impeccable@4.6.0 detect --json <changed UI paths>`: `[]`.
- `ruby scripts/check_release_freeze.rb`: passed, local freeze inactive. `scripts/check_hygiene.sh`: passed.
- `git ls-remote origin refs/heads/main`: `1548e8f31f6dd5bae11f4f7330f8d2c77d9cc898`, matching the requested base.

The API on 3055 was stopped, Playwright closed its Vite server on 5225 and browser workers, the T3 preview tab was closed/released, and `hafapass_visual` was dropped. The lifecycle check reports no active owned resources. Shared Docker services, port 3011, and protected local services were left alone. The held branch/worktree remain for review; no deployment or merge was performed.

## Design review revision — round two, 2026-10-23

Starting head: `9bbe1452`. `origin/main` was verified at `1548e8f3`; the branch already contained it, so no merge was needed. The lead requested that Home retain the product explanation and hosting section, that standalone empty listings offer recovery, and that desktop policies remain visible. This revision keeps the original fonts, colors, hero copy, event eligibility, normal populated layout, and all wording owned by PR #150. Only the new `preInventory.description` changes to the buyer message explicitly requested by the lead. `hafapass_api/config/policies.yml` remains untouched.

Agent-executed affected-flow acceptance used Node 22.22.3, Ruby 3.3.4, Rails on 3055, Vite on 5225, and the newly created/seeded `hafapass_visual_r2` database. The existing Clerk development test account was mapped into the isolated fixture through the repo environment values. A short-lived sign-in ticket authenticated that existing account; no new Clerk user was created. No credentials were printed or committed. Synthetic event statuses were saved, temporarily changed to draft, and restored after each capture.

| Case | Starting condition and steps | Observable outcome | Result |
| --- | --- | --- | --- |
| R01 | Confirm zero public events; open Home at 375×812 and 1280×800 | Hero eyebrow, headline and subcopy remain; buyer empty panel replaces Next Up; search, hero Browse Events and category grid are absent; Planning an event and its Start Hosting action remain | Passed |
| R02 | Restore nine published local events; open Home at both widths | Normal featured/listing/search/category/hosting layout returns. Before/after screenshots above the footer have zero differing pixels at both widths | Passed |
| R03 | Confirm zero inventory; open Events, a filtered Events URL, and Discover; activate Back to event guide | Honest buyer message, Home recovery and secondary List your event link; no empty filters/categories; recovery displays the Home hero | Passed (real API captures plus browser interaction fixtures) |
| R04 | Open footer at 375, 768 and 1280; keyboard-open mobile disclosure and focus every policy link | Privacy Policy, Buyer Terms and Refunds are immediately visible; other policies are keyboard reachable on mobile; all six are visible without disclosure at ≥768; controls are ≥44px and page does not overflow | Passed |
| R05 | Review the earlier auth, organizer and admin screenshot matrix against its before set and inspect the original diff | Control size/contrast changes retain content and actions. Replaced the earlier desktop finances skeleton capture with settled signed-in finances at both widths; no page overflow | Passed for the visual scope; original operational limitations still apply |

Evidence is `docs/qa/visual-polish/r2/{before,after}` and `/tmp/hafapass-visual-r2/{before,after}`. Each set includes `{375,1280}-{home-empty,home-events,events-empty,discover-empty,footer}.png` and `375-footer-expanded.png`. The before set is the original PR head on the same local seeded stack. Signed-in finances captures stay local. The footer's old tagline and aloha text are expected; PR #150 owns those strings.

The round-two mobile footer is 619.5px collapsed / 715.5px expanded, versus 575.5px / 707.5px at the original PR head. The added 44px collapsed row keeps all three buyer policies immediately visible. Desktop remains 414px and now exposes all policies. The populated Home content above it is pixel-identical at both widths (ImageMagick AE=0; compared the first 4414px at 375 and 3274px at 1280).

The T3 preview opened but snapshot failed twice with `Preview automation snapshot timed out after 15000ms.` Browser verification therefore used repository Playwright with the real stack for public captures and settled Clerk finances, and routed fixtures for the repeatable automated journeys. Chromium widths do not establish physical-phone keyboard, gestures, safe-area or installed-PWA behavior.

Validation: ESLint, 164 Vitest files / 1,784 tests, production build, production dependency audit (0 vulnerabilities), release-freeze contract (inactive), and secret/debug hygiene passed. Impeccable 4.6.0 returned `[]`; the cached pinned CLI was used after npm's package lookup stalled. The first full browser run passed 99 and failed 3 stale expectations for the intentionally retained Home/footer; those assertions were corrected and the final full run passed all 102 tests in 48.4s, including axe and the new empty-state/footer cases. Initial failed logs are retained locally.

Do not merge. CodeRabbit is a required repository check; a rate-limited success-labelled result is not completed review. Final CI/review status and resource cleanup are recorded in the round-two handoff.

Round-two cleanup: the owned Rails API and all owned Vite/Playwright/browser processes were stopped or confirmed exited, the T3 tab was closed and released, `hafapass_visual_r2` was dropped, and copied env/auth files were removed. No runtime handoff; shared/protected services and the requested ports 3000/3088/3011 were left unchanged.
