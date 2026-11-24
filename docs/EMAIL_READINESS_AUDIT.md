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

See `evidence/README.md` for the eight-step local acceptance ledger, environment, initial failure/retest and device limits. Evidence is captured simulation, not inbox delivery. Fixture databases are task-only and must be dropped after checks; shared PostgreSQL remains running. No task runtime resources are intentionally handed off.

Test results are recorded below after the final runs. Initial broad runs found transport tests needing the shared limiter stubbed outside dedicated throughput examples, classification/audit/retention inventories needing updates, and checkout selectors matching the new consent checkbox. A later overlapping focused run collided with a full-suite truncation; the serial rerun is the acceptance result. These failures were retained in `/tmp/email-base-*.log`.

## Configuration and decisions

Configure `RESEND_API_KEY`, sending-domain SPF/DKIM/DMARC, verified `MAILER_FROM_EMAIL`, `RESEND_WEBHOOK_SECRET` and delivered/bounced/complained/delayed/failed/suppressed events, `PUBLIC_API_URL`, frontend URLs, and the actual `HAFAPASS_POSTAL_ADDRESS`. Organizer owners retain address certification. `EMAIL_DOUBLE_OPT_IN=true` is the default. `EMAIL_REQUESTS_PER_SECOND=1` is conservative; this app caps it at 2 against the currently documented Resend team default of 10. Shared-team senders still need coordinated headroom.

Leon must approve consent wording/version `event-alerts-v1` and the default-on double opt-in policy. Home redesign PR #231 should place/reuse the self-contained `EventAlertsSignup` band and avoid duplicate capture surfaces. Optional waitlist signup, reviewed translations, large-list SQL pagination, real Clerk/organizer/device browser acceptance, live controlled mailbox/DKIM/webhook checks and independent cross-family review remain follow-ups. New consent tables have explicit keep retention classifications pending policy review; no destructive retention policy was invented.

Do not merge before cross-family review and Leon's OK.
