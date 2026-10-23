# Buyer truthful states — QA record

Context: 2026-10-23; base `677e46db`; branch `codex/hafapass-buyer-truthful-states`. One PR against main, held for lead merge.

HåfaPass serves buyers discovering Guam events, purchasing tickets, recovering guest orders, and presenting admission credentials. Rails 8 owns order, refund and admission state; Clerk owns account identity; Stripe owns card confirmation. Entry permission must come from `Ticket#admission_allowed?`, not the issued status alone. Failed reads must not imply an empty account or inventory. Guests need the existing order-access capability before opening ticket links. Payment uncertainty must lead to order-status recovery before another payment attempt.

Sources: repository README, `Ticket`, `OrderPresenter`, ticket controllers, buyer pages and `.github/workflows/ci.yml` at base; `docs/TRANSLATIONS.md` establishes English fallback and disabled non-English rollout. Brain Dump `work/shimizu-tech/company-positioning-and-project-review-2026-10-04.md` describes ticketing/admissions/refunds capabilities but predates current production; the task's live-mode context supersedes that historical launch note. Main protection requires six CI jobs and CodeRabbit; deployments are outside this held PR.

Agent-executed affected-flow acceptance: each listed audit item is verified in source before editing; cover admission denied/allowed, failed-read retry and genuine empty states, guest/account email links, resend ticket status, specific partial refund amounts, unknown payment outcomes, free checkout, transfer timestamps and conditional pricing disclosure. Preserve existing account/context isolation. Never use real-money actions or send live emails.

Required browser coverage: local API 3052 / Vite 5222 / isolated DB `hafapass_buyer_truth`; 375 and 1280 CSS-pixel widths for My Tickets, ticket states, Saved, Discover error/empty, account privacy request states, free checkout and outage. Render changed emails and inspect. Browser resizing covers responsive web only, not physical-device behavior. Failure injection may simulate unavailable reads; record simulation separately from persisted local fixtures.

## Source audit

- Items 1–7 and 13–24: confirmed in source. Venue/organizer/collection pages already distinguish failed loads and support retry, so retain those and add genuine empty messages. Leave `PrivatePreviewPage` name and ServiceCheck untouched to avoid the concurrent boot change.
- Items 8–12: backend worker verifies the email and refund paths, adds RSpec and supplies render artifacts; parent integrates and verifies.

## Execution

Pending: regression tests, complete local gate, responsive browser scenarios, email rendering, final review and cleanup. This record is updated as each phase runs; pending coverage is not acceptance.

## Implementation and audit decisions

All 24 items were addressed. Important qualifications:

- Item 7: `notified` is set before queuing. The API now exposes whether the current notification round has provider acceptance; only that state says “Availability email sent.” Otherwise it says “Availability notification requested.” No email management-link recovery exists, so browser-only lookup directs buyers to the browser used to join.
- Item 10: `Commerce::RefundCreator` already passed the refund ID. The bug was the email consumer using that ID only for event cancellations. It now requires the specific successful refund for every delivery. Legacy deliveries without that reference require reconciliation rather than guessing an amount.
- Item 15: public venue/organizer/collection errors already had retry and 404 handling, which were retained. Empty collections intentionally return 404, so that API visibility rule is unchanged. Returned empty grids now explain their state. When pagination metadata says other events exist, the page says “No events on this page” and offers the first page instead of claiming the whole listing is empty.
- Item 16: the component keeps its existing name. No changes to ServiceCheck, ClerkProviderWrapper, index.html, or boot gating belong to this PR.
- Item 21: real QA found that free live-mode checkout could fail an upfront Stripe-readiness check. Readiness is now checked after the total is calculated and only for a positive amount. Paid orders keep their readiness checks. A regression spec proves zero-dollar fulfillment without a payment intent.
- `config/policies.yml` is untouched. New and changed English meaning has translator context; stale changed translations are removed for English fallback. No translation service was called.

## Browser execution

Agent-executed local Rails API 3052 / Vite 5222 with a newly created, migrated and seeded `hafapass_buyer_truth` database. Clerk publishable/secret credentials were verified as test mode. Password authentication required MFA; a 60-second Clerk sign-in ticket for the same configured test user established the test session. No secrets were printed. Email delivery was simulated; no real Stripe or email actions were performed.

Each case below passed at **both 375×900 and 1280×900** CSS-pixel viewports (15 cases, 30 required viewport results):

| Case | Starting state, action and verified outcome |
| --- | --- |
| B01 My Tickets | Local issued/used/cancelled/postponed records; open account list; Valid only on admission-allowed tickets, Entry paused on postponed admission. |
| B02 Valid ticket | Open local issued ticket; entry QR visible and PDF action enabled. |
| B03 Used ticket | Open local checked-in ticket; actual used state, no authorization-recovery instruction. |
| B04 Cancelled ticket | Open local cancelled ticket; cancelled-entry explanation, no authorization-recovery instruction. |
| B05 Paused ticket | Open ticket for a postponed local event; Access paused, no active entry code. |
| B06 Ticket failure/retry | Inject HTTP 503 on ticket read; recovery actions visible; retry real API successfully. |
| B07 Saved | Inject one failed saved-list request; error instead of three false empty lists; retry actual empty local lists. |
| B08 Discover | Inject collection read failure; retry to genuine empty response; browse link present. |
| B09 Privacy history error | Inject failed history read; retry actual empty history; no empty message during failure. |
| B10 Free checkout | Select local free ticket in live mode, enter buyer details, accept terms and submit; confirmation and saved $0 order, no payment intent/card action. |
| B11 Outage | Inject failed health on a fresh scanner visit; service-unavailable page and single-suffix Connection unavailable title. |
| B12 Privacy loading | Hold the request, verify loading without “No requests yet,” then resolve an empty response. |
| B13 Venue empty | Local active venue with no events; accurate empty message and browse link. |
| B14 Organizer empty | Local organizer with only a completed past event; accurate no-upcoming-events message and browse link. |
| B15 Collection pagination | Local nonempty collection with page=99; page-specific empty message; first-page action restores its event. |

Public-page and history failures above are injected at the network boundary. Admission, free order creation, actual empty data and pagination recovery use the local API/database. These results cover responsive desktop web, not a physical phone, camera, native keyboard, wallet installation, or live card payment.

Browser evidence is retained locally under `.release-evidence/buyer-truthful-states/ui/` (30 primary screenshots and 8 supplemental screenshots). Original working copies are `/tmp/hafapass-buyer-truth-ui/` and its `supplemental/` directory. T3 preview opened but inspection twice timed out with `Preview automation snapshot timed out after 15000ms.`; Playwright was used for local-stack execution.

## Email execution

Rendered 14 synthetic messages at both widths: guest/account confirmations, guest/account mixed-status resends, capped PDF confirmation, two partial refunds, cancellation remainder, cash return, door-card refund, partial/completed privacy, and Korean fallback examples. No external requests. Visual inspection caught and fixed the added status column clipping the ticket link on mobile. Ticket type/attendee details now share one column; status and ticket link remain readable. No document-level overflow in any of the 28 renders.

Evidence: `.release-evidence/buyer-truthful-states/emails/`; original renders, screenshots and manifest at `/tmp/hafapass-buyer-truth-emails/`. These synthetic signed links become inert when the fixture database is dropped.

## Engineering checks and review

Code at `b59ad675` (rebased equivalent in this branch) passed **2,433 RSpec examples**, full RuboCop (**896 files**), Brakeman (**0 warnings**), Bundler Audit, and the hygiene/freeze scripts. Later pagination work changes frontend only. Frontend before main integration passed **1,750 Vitest tests**, ESLint, production build, production dependency audit (**0 vulnerabilities**) and **88 Playwright tests**. Impeccable advisory scan returned `[]`.

Independent review round 1 found two material waitlist issues (unsupported management-link guidance and premature “sent” label); both fixed with API/UI regression coverage. Round 2 reviewed the fixes and free checkout/payment/recovery interactions and found no material findings. No unavailable bot review is represented as approval.

Main advanced to `6c1c5b2b` with the separate first-load PR. This branch rebased cleanly onto it; backend content is unchanged by that rebase. Final integrated frontend and browser checks are recorded below after execution. PR is held for the lead; no merge or production deployment is authorized for this agent.
