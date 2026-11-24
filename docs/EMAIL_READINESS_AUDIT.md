# HafaPass email audit — 2026-11-24

Base: `964cbefa` (`origin/main`), isolated branch `fix/email-readiness`. Agent-executed API/service tests use local PostgreSQL database `hafapass_email_readiness_test`, with provider simulation or transport stubs. No real email, provider settings, production or staging data accessed. HafaPass serves buyers purchasing Guam event tickets, organizers managing their own events, and platform support/admins. Acceptance is consent-safe delivery, usable audience operations, reliable waitlist claims, and accurate send visibility. This audit does **not** establish overall launch readiness.

## Feature audit

API `app/` and `spec/` paths below are relative to `hafapass_api/`; JSX files are under `hafapass_frontend/src/`.

| Feature | Exists? | Works? | Evidence (repository-relative) | Gaps |
| --- | --- | --- | --- | --- |
| Account signup/email identity | Yes, Clerk | Local integration covered; external signup not exercised | auth wrapper Vitest; Clerk authenticator/request specs | Clerk verification mail and live configuration not verified |
| Platform newsletter / get event alerts | No dedicated subscription model or capture path found | Missing | models/controllers/routes and Footer reviewed | Needs explicit platform consent, capture, subscriber management and sending |
| Follow organizer | Yes | Relationship capture covered | `app/controllers/api/v1/me/organizer_follows_controller.rb`; marketplace specs | Saves user/organization relationship, not email opt-in; no organizer mailing UI/list/export |
| Remind me | Yes | Automated coverage | event reminder job/request specs; `EventDetailPage.jsx` | Requested event reminder, not newsletter consent |
| Waitlist join, status, cancel | Yes | Automated coverage | `spec/requests/api/v1/waitlist_spec.rb`, waitlist unsubscribe specs | No double opt-in; possession of signed management credential required for status |
| Waitlist notify, reserved offer, claim, expiry | Yes | Automated coverage; expired-email defect fixed | waitlist request/service specs; waitlist offer commerce specs; `waitlist_email_compliance_spec.rb` | No live mailbox test; delivery delays consume the 30-minute offer window |
| Order confirmation, PDF tickets, resend | Yes | Automated coverage | email service, ticket email attachments, fulfillment resender specs | Real provider acceptance/DKIM not tested |
| Transfers, refunds, event changes | Yes | Automated coverage | buyer truthful emails, email refund reconciliation, transfer and event-change specs | Provider mailboxes not exercised |
| Event attendee CRM/export | Yes | Automated coverage | `spec/requests/api/v1/organizer/sales_tools_spec.rb`; CRM controller | Attendee export is not a list of consented marketing recipients |
| Waitlist list/search/filter/CSV | Yes (search/export added here) | New request + frontend tests | organizer waitlist specs; `WaitlistPage.test.jsx` | Export is event-scoped; no combined platform audience screen; UI browser acceptance not run |
| Waitlist request provenance | Yes | API/export now exposes source/date | WaitlistController records requested_at, request_ip, user-agent; new export spec | Source is event_waitlist, not general marketing consent; no double opt-in |
| Checkout marketing consent | Yes, defaults false | Automated coverage | marketing unsubscribe specs; campaign sender specs | Choice stored on order with order timestamp; no separate consent wording/version ledger or double opt-in |
| Per-event attendee campaigns | Yes | Automated coverage | sales tools, campaign sender, campaign durability, dispatch specs | Audiences are attendee segments only; no general waitlist/follower/platform mailing |
| Compose → preview → self-test → send | Partial | Compose/schedule/send exists | `SalesToolsPage.jsx`, campaign controller | No dedicated rendered preview or test-send-to-self flow; needs implementation before broad email-base readiness |
| Queued sending/retries | Yes | Automated coverage | durable campaign outbox, dispatch, MessageDeliveryJob specs | Dispatcher iterates whole audience; no explicit global provider throughput limiter/bounded campaign batch dispatcher found |
| Send history and delivery counts | Partial → improved | Counts added from delivery statuses | new sales tools request spec; SalesTools UI | Queue completion is now labelled queued; no real mailbox proof; simulated counts must not be presented as provider delivery |
| Visible unsubscribe and signed token page | Yes | Automated coverage | marketing unsubscribe request specs; `UnsubscribePage.test.jsx` | Organizer-wide marketing opt-out; waitlist token offers event-only or organizer-wide stop |
| RFC 8058 one-click headers | Yes | Payload/request tests | waitlist email compliance, email service, unsubscribe specs | Actual DKIM signature inclusion and inbox provider requirements not verified |
| Marketing suppression / transactional exemption | Yes | Automated coverage | `MessageDelivery`, delivery job/provider specs, compliance specs | Hard invalid-address suppression intentionally also stops transactional mail; complaints stop promotional mail |
| Global preferences center | No | Missing | unsubscribe page/routes reviewed | No self-service platform/global preference center; existing organizer opt-outs and provider/global address suppression are distinct |
| Commercial footer / physical address | Yes | Automated coverage | `docs/EMAIL_COMPLIANCE.md`; waitlist compliance specs | Every organizer owner must supply and certify a real address; no fabricated legal address added |
| Bounce/complaint webhooks | Yes, signature verified | Automated provider callback fixtures | `spec/requests/resend_webhooks_spec.rb`, provider processor/job specs | Production webhook secret/event subscriptions and delivery must be verified by owner |
| Authorization/audit | Yes | Automated coverage; export tests added | organizer authorization, campaign revocation, waitlist export specs; AuditActions registry | Needs independent cross-family review; no browser role acceptance in this audit |

## Changes

- Reject expired waitlist offers immediately before transport, even when the expiry sweep has not run. Regression tests cover expiry before execution and during payload preparation.
- Validate notify counts (1–50) and status filters. Negative counts previously reached SQL LIMIT; unknown statuses were not explicitly rejected.
- Add authenticated event-scoped waitlist search and streamed CSV with spreadsheet formula protection, request source/date, organizer unsubscribe state, and an audit action. CSV uses the same status/search filters; no claim/manage tokens or IPs exported.
- Add waitlist search/export controls and download failure handling; preserve organizer request context.
- Expose campaign delivery status counts and label recipient totals as queued instead of sent.

## Configuration / decisions for Leon

- Configure `RESEND_API_KEY`, a verified `MAILER_FROM_EMAIL`, `RESEND_WEBHOOK_SECRET`, `PUBLIC_API_URL`, and frontend public URL using the existing deployment process. No keys were read or copied here.
- Verify sending-domain DNS, SPF/DKIM/DMARC and signed List-Unsubscribe headers with a controlled mailbox test. Configure relevant delivered/bounced/complained callbacks and run the existing readiness/reconciliation checks. This audit did not inspect Resend or DNS settings.
- Each organizer must enter and certify its actual public marketing postal address in Organization settings. Missing certification blocks waitlist and campaign sends.
- Confirm consent wording/classification with counsel; decide whether double opt-in is required. Approve platform newsletter scope and a separate follower opt-in, preference center, preview/test-send, and provider rate limiting before calling the email base ready.

## Verification

Results are appended after the local runs. All real delivery remains untested by instruction. No frontend browser walkthrough or Safari/device acceptance executed. PostgreSQL was already running at baseline and is borrowed; leave it running, drop only the task database. No application servers or browser tabs started.

Do not merge before cross-family review and Leon's OK.

- Focused backend: 52 examples, 0 failures (`/tmp/hafapass-email-focused.log`).
- Frontend: lint passed; 211 Vitest files passed, 1 skipped; 2,386 tests passed, 3 skipped (`/tmp/hafapass-email-vitest.log`).
- Production frontend build passed (`npm run build:no-translate`). Advisory Impeccable scan returned `[]`.
- The first suites ran while changes were being completed: frontend loaded an old component while discovering the new tests; backend loaded its audit registry before the new action was registered. Those runs were not final validation. Full reruns use the completed code.
- Shared-guidance read-only check failed: this host is missing `~/.config/shimizu-technology/agent-context.json`. Canonical synced skill files were read directly. No shared guidance was changed.

- Final full RSpec: 4,045 examples, 0 failures (`/tmp/hafapass-email-rspec-final.log`), using the completed implementation.

- CI initially rejected one extra blank line in a new spec; corrected with RuboCop. Final local RuboCop: 1,064 files, no offenses; Brakeman: no warnings; dependency audit: no vulnerabilities. Final follow-up commit changes only spec whitespace and this audit, so full behavioral results above remain applicable. CI on the updated head is lead-owned and pending.
- Authorized PR creation triggered the repository's existing Netlify preview automation. Worker did not issue any deployment command or change hosting settings; production was not deployed.
