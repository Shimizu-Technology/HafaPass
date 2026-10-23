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
