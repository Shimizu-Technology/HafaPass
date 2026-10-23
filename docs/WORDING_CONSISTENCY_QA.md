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
