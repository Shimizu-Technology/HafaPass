# HafaPass email base — implementation audit, 2026-11-24

Worktree `/Users/agent/work/hafapass-email`, branch `fix/email-readiness`, PR #233, base `964cbefa`. HafaPass serves Guam ticket buyers, event organizers and platform administrators. This revision extends the original waitlist safety/export audit into a platform and organizer email base. Context comes from the existing outbox, consent checks, organizer authorization, public unsubscribe routes, repository docs and the prior audit/handoff. No production or staging access, real mail, manual deploy, merge or delegated agents.

Acceptance: explicit platform and follower consent; confirmed platform subscriptions; scoped lists and exports; preview/self-test/send/schedule; signed preferences; suppression before transport; certified sender address; bounded, idempotent dispatch; captured local signup → confirm → send → unsubscribe → exclude journey.

| Item | Implementation | Verification / limits |
| --- | --- | --- |
| Platform signup | Dedicated subscriber, status, source/name/interests/villages; append-only consent version/time/IP/UA; footer/Home and separate unchecked checkout choice | Public API and browser footer capture; optional waitlist capture was not added |
| Double opt-in | Default-on flag, expiring signed nonce token, duplicate-safe confirmation/resend | RSpec pending/confirmed/unsubscribe replay/expiry; captured confirmation |
| Follower email consent | Explicit checkbox separate from follow, verified identity, version/time ledger; persisted choice reloads | API consent/scoping tests; organizer browser journey not run |
| Preferences | Scoped signed 90-day page and verified account entry, platform/organizer toggles, unsubscribe all with independent scope restoration | API and Vitest, browser global unsubscribe; existing RFC 8058 paths preserved |
| Platform administration | Status/source/interest/date/search filters, counts, daily growth, consent detail, manual unsubscribe, formula-safe audited CSV | Request tests; browser list/eligible count; listing display capped at 200 records, CSV covers filtered scope |
| Organizer audiences | Own buyers, explicitly opted-in followers, waitlists with separate marketing consent; scoped count/search/CSV | API roles and tenant isolation. Existing event waitlist exports retain the full requested-alert list |
| Compose and preview | Plain text escaped into the exact transport renderer; sandboxed 600/375px HTML previews | Vitest and browser preview; English fallback translations need language review |
| Self-test | Signed-in user's own Clerk-verified address only, TEST label, excluded from statistics | Request tests, Vitest and captured self-test; browser identity is a synthetic fixture |
| Send/schedule/history | Due-now or future queue, audience picker/filtered count, scoped history and provider status groups | Request scheduling/role checks; browser immediate sends; real future-clock worker demonstration not run |
| Required sender footer | Identity, real configured/certified postal address, preferences and scoped unsubscribe headers | Missing-address tests; captured HTML; no invented production address |
| Dispatch and retries | 100-recipient outbox batches; per-recipient durable keys and frozen wire bytes; shared DB limiter default 1 request/sec, 429 backoff; runtime recovery | Limiter/idempotency/provider contract tests; audience snapshot/count currently materializes addresses in memory |
| Webhooks/suppressions | Existing signed provider callbacks retained; complaints/hard bounces suppress and update platform subscriber status; all-marketing preference checked on old/new campaign paths | Existing callback suite and new filtered-count tests; no live provider callbacks |
| Prior fixes retained | Expired offer safety, waitlist search/formula-safe audited export, accurate queued/delivery counts | Original regression coverage remains in full suite |

## Evidence and verification

See `/Users/agent/work/hafapass-email-evidence/README.md` (local only) for the eight-step local acceptance ledger, environment, initial failure/retest and device limits. Evidence is captured simulation, not inbox delivery. Fixture databases are task-only and must be dropped after checks; shared PostgreSQL remains running. No task runtime resources are intentionally handed off.

Test results are recorded below after the final runs. Initial broad runs found transport tests needing the shared limiter stubbed outside dedicated throughput examples, classification/audit/retention inventories needing updates, and checkout selectors matching the new consent checkbox. A later overlapping focused run collided with a full-suite truncation; the serial rerun is the acceptance result. These failures were retained in `/tmp/email-base-*.log`.

## Configuration and decisions

Configure `RESEND_API_KEY`, sending-domain SPF/DKIM/DMARC, verified `MAILER_FROM_EMAIL`, `RESEND_WEBHOOK_SECRET` and delivered/bounced/complained/delayed/failed/suppressed events, `PUBLIC_API_URL`, frontend URLs, and the actual `HAFAPASS_POSTAL_ADDRESS`. Organizer owners retain address certification. `EMAIL_DOUBLE_OPT_IN=true` is the default. `EMAIL_REQUESTS_PER_SECOND=1` is conservative; this app caps it at 2 against the currently documented Resend team default of 10. Shared-team senders still need coordinated headroom.

Leon must approve consent wording/version `event-alerts-v1` and the default-on double opt-in policy. Home redesign PR #231 should place/reuse the self-contained `EventAlertsSignup` band and avoid duplicate capture surfaces. Optional waitlist signup, reviewed translations, large-list SQL pagination, real Clerk/organizer/device browser acceptance, live controlled mailbox/DKIM/webhook checks and independent cross-family review remain follow-ups. New consent tables have explicit keep retention classifications pending policy review; no destructive retention policy was invented.

Do not merge before cross-family review and Leon's OK.

## Final automated verification

Implementation `eb7c23ddec9ce437a74982da4728e761215f3e52`; follow-up commit adds recovery regression coverage and this verification record.

- Full serial RSpec: **4,063 examples, 0 failures** (`/tmp/email-base-rspec-serial.log`).
- Final affected RSpec, including the added recovery regression: **37 examples, 0 failures** (`/tmp/email-base-final-affected.log`). Earlier transport/inventory regression batch: 149/0; serial commerce/new feature retest: 94/0.
- Full Vitest: **214 files passed, 1 skipped; 2,391 tests passed, 3 skipped** (`/tmp/email-base-vitest-last.log`).
- Frontend lint and production build passed (`/tmp/email-base-lint-final.log`, `/tmp/email-base-build-final.log`).
- RuboCop: **1,083 files, no offenses** (`/tmp/email-base-rubocop-final.log`). Brakeman: **no warnings** (`/tmp/email-base-brakeman-final.log`). Ruby and production npm dependency audits: **no vulnerabilities** (`/tmp/email-base-audit-final.log`, `/tmp/email-base-npm-audit.log`). Advisory Impeccable returned `[]`.
- Browser acceptance/evidence: the eight required local captured-mail stages passed with the fixture and device limits in `/Users/agent/work/hafapass-email-evidence/README.md` (local only). No real email or external provider verification.

Required CI and cross-family review remain lead-owned. No merge or deployment was performed. Shared-guidance setup remains missing its agent-context configuration; no shared settings changed.

## Browser CI repair (November 24, 2026)

Scope: repair PR #233 from `a5ebb8a27513437bdd9c4f6513c704589925f694`. HåfaPass buyers must reach guest-order recovery and event discovery; organizers must complete box-office sales and reach cancellation/refund controls by keyboard. Event-alert signup must remain distinguishable from recovery and retain its layout through pending, error and confirmation states. Sources: README, Layout/Navbar/HomePage, the three failing browser suites, and run 45325918115 logs/screenshots/error contexts. Tests use synthetic API fixtures and captured/simulated email only.

All six reported failures reproduced before edits. The footer signup reused recovery's “Email address” label; it now uses “Email for event alerts”. Home rendered signup before pending inventory content, so inventory arrival pushed visible form content down (CLS 0.17857 at 375 px and 0.33008 at 768 px). Signup now follows inventory/planning content, reserves its band while pending, and stays invisible/inert until loading settles. Confirmation and error messages reserve their wrapped height; the hidden form retains its dimensions after acceptance.

The desktop cancellation control remained keyboard reachable, but the new intentional Email audiences navigation link put it beyond the helper's fixed 100-Tab budget. The original run stopped on “Retry pricing tiers”, immediately before cancellation review. Only this obsolete test assumption changed: the helper now bounds traversal by control count and allows native date/time controls' internal keyboard stops. Cancellation, refund, axe and focus-trap assertions remain intact. Recovery and inventory layout assertions are unchanged.

Evidence moved to `/Users/agent/work/hafapass-email-evidence/`; `evidence/` is deleted from git and ignored. CI downloads and command logs are siblings of the worktree, outside git. No added logs, scratch files or captured email HTML remain in the PR. Existing untracked `.codex/` and `EMAIL_AUDIT.md` were preserved and excluded.

Repair verification: full CI development Playwright suite **211 passed**, plus **6 passed** new signup confirmation/error stability cases at 375/768/1280 px; production service-worker deploy/offline suite **2 passed**. Full Vitest **2,391 passed, 3 skipped**; final signup unit retest **2 passed**. Final lint, production build, repository hygiene and diff whitespace checks passed. Advisory Impeccable returned `[]`. No backend code changed in this repair; RSpec was not rerun (prior full backend result above). Chromium ran on the Mac mini; native/mobile Safari and real provider delivery were not tested. Logs: `/Users/agent/work/hafapass-email-{reproduce,retest-final,playwright-full,signup-browser,pwa,vitest,lint-final,build-final}.log`. Shared-context read-only check still fails because this host lacks `~/.config/shimizu-technology/agent-context.json`; synced skills were read directly. No merge, deployment or real email send performed.
