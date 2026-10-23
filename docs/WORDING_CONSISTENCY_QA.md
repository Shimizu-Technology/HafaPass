# Wording consistency acceptance

Task base: `1548e8f31f6dd5bae11f4f7330f8d2c77d9cc898`, 2026-10-23.
Branch: `codex/hafapass-wording-consistency`. One PR against main; do not merge.

## Product brief and boundaries

HåfaPass is a Guam event-ticket marketplace. Buyers discover events and use issued tickets at the door; organizers manage admission, promotions and proceeds; admins and support review launch evidence, finance and message delivery. Event activity follows the venue time zone, platform finance follows Guam time, and creating guest tickets does not check them in.

Sources: repository README, `docs/TRANSLATIONS.md`, current `eventTime.js`, organizer promo and guest-list controllers/models, `Event#publish_checklist`, CI workflow and main branch protection. Brain Dump `system/full-picture-2026-10-12.md` identifies HåfaPass as the active Guam product experiment and describes an Ambros pilot as a plan, not a verified live launch. PRs #147–149 are included in the base; preserve their state and context protections.

Acceptance is agent-executed affected-flow QA. Keep `config/policies.yml`, visual-polish-owned layouts, empty states, Clerk appearance and admin visual styling untouched. Do not merge or use production data. Local API/Vite: 3054/5224; disposable databases: `hafapass_wording`, `hafapass_wording_test`. Mobile/desktop coverage is desktop Chromium resized to 375 and 1280 CSS pixels; no physical-device claim.

## Required scenarios

| ID | Starting fixture and action | Required observable and saved outcome |
| --- | --- | --- |
| W1 | Public home at both widths; inspect metadata and footer | Canonical title/description, accurate tagline and company sign-off, readable layout |
| W2 | Seeded event card, detail and owned ticket at both widths | Venue times include Guam time; non-Guam/DST behavior covered by unit/email specs |
| W3 | Organizer promo tool at both widths | Create $5.00 → 500 cents; reopen and edit → correct cents; saved list and expiry retain event zone |
| W4 | Organizer guest list at both widths | Create complimentary tickets, show Tickets created and separate check-in instruction; issued tickets remain unchecked |
| W5 | Admin navigation and event launch reviews at both widths | Integrations & policies route unchanged; readable launch-review actions |
| W6 | Support console at both widths | Resend order tickets and Retry delivery wording; request confirmations describe queueing accurately |
| W7 | Render a changed order email | Event date/time includes Guam time; no actual outbound delivery |
| W8 | Full CI-equivalent local gate | RSpec, RuboCop, Brakeman, dependency audits, ESLint, Vitest/locale tests, build, Playwright, freeze and hygiene |

Execution results and evidence are recorded below before PR creation.

## Results

W1–W7 passed at 375 and 1280 CSS pixels on the local Rails/Vite stack. The browser used the repository's Clerk test instance and account; the password flow required new-device verification, so QA continued using Clerk's documented short-lived test-instance sign-in token. No production data or real payments were used.

- Home title and description matched the requested copy. Cards, event detail and ticket detail displayed `6:30 PM Guam time`. No document-level horizontal overflow appeared in the inspected buyer and support views.
- At each width, promo creation entered `5.00` and saved 500 cents; reopening retained `5.00`; editing to `7.25` saved 725 cents. The saved expiry was `2026-11-20T09:00:00Z`, displayed as `7:00 PM Guam time`. Unit/UI tests also cover sub-minute expiry preservation and retained recovery/context protections.
- At each width, the guest confirmation described complimentary ticket creation and separate check-in. Saved guest orders contained issued tickets with no check-in timestamp. Reserved local guest-email placeholders were cancelled by the delivery layer; no guest notification was delivered.
- Admin navigation retained `/admin/provider-readiness` and showed Integrations & policies. Event launch reviews showed all three revised preparation actions. Support showed Resend order tickets and Retry delivery; transport/queue outcomes are covered by existing and updated component tests. Runtime support inspection did not send a real message.
- The order email was rendered from `EmailService.prepare_delivery_payload`, without delivery, and visually checked at both widths. Its event time included Guam time. The default social JPEG was regenerated from its corrected SVG and visually checked.

Evidence is local and ignored by Git: `screenshots/wording/`. Files include `home-{375,1280}.png`, `footer-{375,1280}.png`, `event-detail-{375,1280}.png`, `ticket-{375,1280}.png`, `promo-create-{375,1280}.png`, `promo-edit-{375,1280}.png`, `guest-confirm-{375,1280}.png`, `guest-created-{375,1280}.png`, `launch-reviews-{375,1280}.png`, `admin-navigation-375.png`, `integrations-375.png`, `support-{375,1280}.png`, and `email-{375,1280}.png`.

## Item disposition

| Item | Result |
| --- | --- |
| 1 | New sign-off and context; faithful corrections in ja/ko/zh/zh-Hant/tl. Repo search found only proper-name Hafaloha references in seed data, its regression spec and historical credential notes; retained those names. |
| 2 | Default SEO, static title/description/social metadata, manifest and social image corrected. Search aliases retained in keywords and structured data. |
| 3 | Every repeated translation context corrected to include sports; translation documentation corrected too. |
| 4 | Discovery description corrected; ranking line emptied while preserving the locale key and the parallel owner's component. |
| 5 | Shared venue/platform date-time formatting and all email locale format placeholders updated. Waitlist, analytics, cash-return summaries, promo expiry and admin date-time summaries use it. |
| 6 | Requested admin/support terms corrected; readable formatting added to settlement/payout statuses, seating audit actions and setup statuses. Existing admin-label mappings from #148 retained. |
| 7 | Village or city / Tamuning; no invented Guam default. Schema has no village default or unconditional presence validation. Drafts may be blank; the existing publication checklist still requires the location. Existing saved locations are preserved. |
| 8 | Complimentary-ticket creation and separate check-in language implemented and exercised. |
| 9 | Dollar form, exact integer-cent conversion, readable display and editing implemented; create/edit and expiry round-trips covered. |
| 10 | COPY_GLOSSARY added; saved-event language and touched promo form labels made consistent. “Host an event” remains an accurate verb; no noun replacement or unrelated button-case churn. |

No complete item was skipped. Unused legacy home locale keys and parallel-owned zero-event copy/layouts were left unchanged. Policies and routes were not changed.

Local engineering gate results are recorded in the PR test plan. The tested working tree is the source committed on this branch; runtime release metadata still identified the base commit because the implementation was uncommitted during UI execution. The final head SHA is reported with the PR. UI coverage is scoped to the listed journeys, with no physical-mobile-device claim.

## Review fixes — 2026-10-23

Verified all 12 CodeRabbit comments against `745687ce580b44da2fecd5f4e264f24b2aa103de`. At the start of this round, `origin/main` was still `1548e8f31f6dd5bae11f4f7330f8d2c77d9cc898`; the task branch was one commit ahead and zero behind, so no integration merge was needed. The scope and product rules above still apply. No policy configuration or CHamoru text changed.

All 12 findings were valid and addressed:

1. Updated only the five supported locales' footer taglines and their GT postprocessing hashes. Retained the service's actual translation version IDs and download timestamps.
2. Renamed the expanded admin action group's accessible label to Launch review actions; updated its component assertion.
3. Added create-flow browser assertions for submitted blank `venue_city` and the blank field after navigation to the saved draft.
4. Corrected the edit-save fixture to return a blank city and asserted both the submitted and displayed blank value. The API has no unconditional Guam fallback.
5. Kept `redeem_guest` as the recovery operation ID and mapped its visible label to create guest tickets; tested paused writes and retained journal identity.
6. Changed the guest completion summary to tickets created; tested the summary and matching section heading.
7. Rendered composed checklist sentences directly. Only the raw payout enum passes through the readable-label helper. Regression cases preserve `eBay_Events` and `island_nights` exactly.
8. Reused one normalized event time zone for promo conversion, editing and display. Explicit null zones now use Pacific/Guam. Component and browser tests cover create/edit/reload and retained sub-minute expiry precision.
9. Enabled assigned seating in a component fixture and supplied two audit events to exercise both mapped and unknown underscore-action labels. No audit behavior changed.
10. Added support tests for the enabled Retry delivery action and both queued-success messages. These use simulated transport; no message was sent.
11. Added a direct platform formatter test with Japanese active and a fixed UTC instant crossing Guam midnight; output remains US English and Guam time.
12. Limited fixed discounts to 2,147,483,647 cents in the frontend and API. Request tests persist the maximum, reject overflowing creates/edits without changing saved data, and reject percentages above 100 or fractional points.

### Affected-flow acceptance

Executor: agent. Source: the review-fix commit containing this record. Browser: local Vite on port 5236, desktop Chromium at 390 and 1440 CSS pixels. Playwright owns isolated in-memory API fixtures and browser contexts; its existing no-Clerk test mode is used. This round does not repeat the prior live Clerk, physical-device, email-rendering or production checks.

- R1: At each width, open the promo form for an event with `timezone: null`; reject $21,474,836.48 without sending a write; correct to $5.00 and save with a Guam expiry; reopen, edit to $7.25 and another expiry; reload. Passed: fixtures retained 500/725 cents and the expected UTC instants, and the list/form used Guam time. Evidence: `e2e/wording-review.spec.js` and `/tmp/hafapass-150-playwright-final.log`. Database persistence of range boundaries is separately established by the Rails request specs against disposable `hafapass_150_review_test`.
- R2: At each width, load one pending and one completed guest; inspect the completion summary; start Create tickets, interrupt its response, then reload. Passed: create guest tickets wording remains visible, further writes stay disabled and `redeem_guest` stays in the recovery journal. Same browser evidence as R1; no claim that the interrupted write reached a real backend.
- R3: Create a draft without touching Village or city; verify the submitted fixture and saved editor field remain blank. Passed in the existing event-editor browser scenario. The component edit test also preserves the blank response while retaining a concurrent cover upload.

Required affected-flow cases: 3 passed, 0 failed, 0 blocked, 0 not run. Resized Chromium coverage does not establish physical-phone keyboard, gesture or installed-app behavior.

### Engineering verification

Final local gate passed: 2,445 RSpec examples, 165 Vitest files / 1,795 tests, all 99 Playwright scenarios, ESLint, production build, RuboCop (897 files), Brakeman, Bundler Audit, npm production audit, release-freeze check, repository hygiene and `git diff --check`. Logs are `/tmp/hafapass-150-{rspec,vitest,playwright-final,lint-final,build-direct,rubocop,brakeman,bundle-audit,npm-audit}.log`. The selected-path advisory Impeccable scan returned `[]`; its initial npx install stalled, so the identical cached 4.6.0 CLI completed the scan (`/tmp/hafapass-150-impeccable-cached.json`).

The first two-worker Playwright run had 98 passes and one unchanged offline-scanner timeout. Both scanner variants then passed twice in isolation. The full serial rerun passed all 99 scenarios; the original failure remains in `/tmp/hafapass-150-playwright.log`. No scanner source or timeout was changed. The final remote fetch still showed zero commits behind main.

The collaborative preview could not initialize automation (`Preview automation status timed out after 15000ms.`); its exact task-created idle tab was closed. Browser acceptance above was executed through the repository's Playwright suite.
