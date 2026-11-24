# Local captured-mail acceptance — 2026-11-24

Agent executed on the Mac mini in the `fix/email-readiness` worktree. Vite + Rails test environment used an isolated `hafapass_email_base_demo` PostgreSQL database. Temporary `/tmp` server bootstrap supplied a synthetic admin identity and a verified-address fixture; **this is not Clerk login acceptance**. `EmailService.configured?` was forced false. No Resend requests, real emails, production/staging records, or provider settings were used. The conspicuous TEST FIXTURE postal address is demonstration data only, not a suggested address for configuration.

| Required scenario | Result | Saved evidence |
| --- | --- | --- |
| Footer signup without an account | Passed; generic accepted notice, pending subscriber, consent ledger | `01-footer-subscribed.png` |
| Captured confirmation, signed-link confirmation | Passed; pending → confirmed | `01-confirmation-email.html`, `02-confirmed.png` |
| Admin sees confirmed subscriber and eligible count | Passed; 1 eligible | `03-admin-audience.png` |
| Compose and rendered desktop/mobile preview | Passed; escaped email with both widths | `04-compose-preview.png`, `04-test-preview.png` |
| Verified self-test isolated from campaign stats | Passed with synthetic verified identity; TEST recipient admin@example.test | `04-test-email.html` |
| Audience send and required footer | Passed; one simulated delivery to demo-alerts@example.test | `05-audience-email.html`, `05-captured-email.png`, `05-captured-email-mobile.png` |
| Preferences and unsubscribe all | Passed; platform unchecked, durable global suppression | `06-preferences.png`, `07-unsubscribed.png` |
| Next send excludes subscriber | Passed; 0 eligible, next mailing queued with zero audience deliveries | `08-next-send-excluded.png`, `08-admin-mobile.png` |

The initial Send now browser attempt exposed use of the scheduled adapter even for an immediately due job; implementation was corrected. That first campaign was retried through its local API after resetting only the synthetic draft. A second complete compose → preview → self-test → Send now journey ran through the UI and queued zero audience deliveries after opt-out. Saved database assertions: first mailing `queued`, one audience delivery; second mailing `queued`, zero audience deliveries. Provider “sent” here means **simulated**, never an inbox or delivered receipt.

Desktop Chromium at 1280×800 and resized Chromium at 375×812 were inspected; admin list and captured email had no horizontal document overflow. Real phone keyboards, Safari/WebKit, real Clerk authentication, organizer browser journeys, external provider webhooks/DKIM and future-clock scheduling in a running queue were not exercised. RSpec covers role scoping, consent, preference state, scheduling, webhook suppression, provider contract and retries; Vitest covers signup, preferences, compose/preview/self-test/send. These local checks do not replace cross-family review or Leon's approval.

Captured HTML contains only synthetic reserved `.test` addresses and local signed links. Tokens become unusable when the task database is dropped. Screenshots and this directory are local evidence, not deployed assets.

## Final automated verification

Implementation `eb7c23ddec9ce437a74982da4728e761215f3e52`; follow-up commit adds recovery regression coverage and this verification record.

- Full serial RSpec: **4,063 examples, 0 failures** (`/tmp/email-base-rspec-serial.log`).
- Final affected RSpec, including the added recovery regression: **37 examples, 0 failures** (`/tmp/email-base-final-affected.log`). Earlier transport/inventory regression batch: 149/0; serial commerce/new feature retest: 94/0.
- Full Vitest: **214 files passed, 1 skipped; 2,391 tests passed, 3 skipped** (`/tmp/email-base-vitest-last.log`).
- Frontend lint and production build passed (`/tmp/email-base-lint-final.log`, `/tmp/email-base-build-final.log`).
- RuboCop: **1,083 files, no offenses** (`/tmp/email-base-rubocop-final.log`). Brakeman: **no warnings** (`/tmp/email-base-brakeman-final.log`). Ruby and production npm dependency audits: **no vulnerabilities** (`/tmp/email-base-audit-final.log`, `/tmp/email-base-npm-audit.log`). Advisory Impeccable returned `[]`.
- Browser acceptance/evidence: the eight required local captured-mail stages passed with the fixture and device limits in `evidence/README.md`. No real email or external provider verification.

Required CI and cross-family review remain lead-owned. No merge or deployment was performed. Shared-guidance setup remains missing its agent-context configuration; no shared settings changed.
