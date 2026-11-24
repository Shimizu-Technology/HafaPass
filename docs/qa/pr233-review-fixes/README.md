# PR 233 review fixes — 2026-11-24

This round starts at `5bf1b133044531837356f2226f07a1b7f324747b` in the existing `fix/email-readiness` worktree. Sources: Opus's report at `/Users/agent/work/hafapass-email-reviews/opus-review-REPORT.md`, the current controllers/jobs/models, and unresolved GitHub review threads. HåfaPass serves Guam ticket buyers, organizers and administrators. Acceptance covers explicit consent, exact filtered recipients, recoverable scheduling, fast transactional delivery during campaigns, privacy handling and simulated transport. No production access, real email, merge or deploy is authorized.

| Finding | Change and permanent coverage |
| --- | --- |
| B1 | Dedicated marketing worker in Solid Queue and Sidekiq; provider-boundary serial pacing without recipient re-poll jobs. Orders, tickets, transfers, refunds and requested waitlist offers/notices bypass this lane. `email_marketing_lane_spec` covers a backed-off blast plus immediate order delivery and priority template routing. |
| B2 | After-commit checkout job, capped name, enqueue/write rescue and class-only logging. `orders_spec` and `email_marketing_lane_spec` cover 121-character names and write/enqueue failures. |
| S1 | Strict ISO scheduling, 422 before mutation, stale/invalid recovery blocked. Request regressions reject invalid/past dates. |
| S2 | Saved filter snapshot used by list eligibility, preview and delivery selection; changing filters invalidates frontend draft/preview. Regression compares displayed count to deliveries. |
| S3 | Locked cancellation, blocked reason, six-hour default schedule grace; blocked content requires a new confirmed draft. API/job and recovery regressions cover cancellation, address loss and blocked batches. |
| S4 | Exact subject/audience/count confirmation; TEST prerequisite help; successful test required before enabling send. Frontend regression covers failed tests and locked composition. |
| S5 | Set-based batched eligibility/consent/suppression queries and concurrent lower-recipient index; bulk delivery inserts in the background dispatcher. Query-count regression covers 110 subscribers. |
| S6 | Grouped history queries; batched consent history and waitlist unsubscribe lookups. |
| S7 | Only filter snapshot and count on mailing; recipient addresses reside in delivery rows, using existing delivery retention. The legacy recipient JSON is empty on new dispatches and excluded from API serialization. |
| S8 | Unfollow records unsubscribe; preference center includes consent/unsubscribe/waitlist organizations. Permanent P3 regression. |
| S9 | Per-wording source versions, named HåfaPass checkout wording and associated checkbox label. Frontend covers unchecked defaults, independent fields and recovery payload. |
| S10 | Fresh double opt-in permitted after unsubscribe-all; confirmation restores platform permission while organizer opt-outs remain. Permanent P5 regression. |
| S11 | New visible preference links do not expire; scoped one-click links remain independent. Eight-year regression. |
| S12 | ENV-configurable carrier-NAT IP budget, durable three-per-address confirmation cap in 30 days, honeypot, normalized path matching. Rate-limit and confirmation-cap regressions. |
| S13 | Subscription, consent, preference and recipient export; hold-aware profile/identity redaction and legacy snapshot removal on deletion. Privacy regressions. |
| S14 | Encrypted, URL-safe purpose-scoped preference identities; old signed links accepted for compatibility. Permanent P6 regression. |
| S15 | Reversible constraint restoration with NOT VALID and recipient-column rollback. Migration regression. |

P1–P7 are permanent tests across `email_review_regression_spec.rb`, `email_marketing_lane_spec.rb` and `orders_spec.rb`. The captured transport request journey exercises signup, confirmation, admin audience, preview, test, send, unsubscribe and exclusion. These simulated results do not prove provider deliverability, real Clerk login or Safari behavior.

Recipient retention: mailing JSON must remain empty; delivery rows are the sole recipient snapshot and retain the existing message-delivery retention/redaction policy. Privacy deletion redacts subscriber profile/preferences and consent identity using the existing legal-hold guard. Consent action/version timestamps remain as deidentified evidence. The broader seven-year retention policy remains the repository's engineering draft pending counsel/CPA review.

Validation completed on this fix round:

- Full serial RSpec: 4,088 examples, zero failures. Final affected retest after the small follow/preference/blocked-dispatch fixes: 122 examples, zero failures.
- Full Vitest: 214 files passed, one skipped; 2,396 tests passed, three skipped. Final confirmation-dialog assertion retest also passed.
- CI Chromium suite: 211 passed initially; six signup payload assertions needed the newly added honeypot field. All six then passed. PWA deploy/offline suite: two passed. WebKit/real devices were not run on this headless Mac mini.
- Captured-mail browser journey: all eight stages passed against local Rails and simulated transport, with a synthetic admin and verified-address fixture. Evidence: `/Users/agent/work/hafapass-email-evidence/review-fixes/` (`result.json`, captured HTML, screenshots). Priority-lane regression sent the simulated order confirmation with 100 blast recipients pending and a backed-off limiter.
- Production Vite build, frontend lint, RuboCop (1,089 files), Brakeman (no warnings), Bundler Audit and production npm audit (no vulnerabilities) passed. Impeccable advisory returned `[]`.
- Actual migration 140200 down/up succeeded inside a rolled-back transaction against the isolated demo DB. Every Rails database command followed an explicit database-name assertion.
- Borrowed PostgreSQL remains running. Task-owned API/Vite/browser processes stopped; task databases dropped. Worktree retained; pre-existing `.codex/` and `EMAIL_AUDIT.md` preserved.

The read-only shared-context check failed because this host lacks `/Users/agent/.config/shimizu-technology/agent-context.json`; synced canonical guidance was read directly. No shared settings changed.

Lead follow-up: final-head CI/review and the eventual merge/release decision. No merge/deploy or real email occurred. External sender-domain/webhook/inbox acceptance and real Clerk/Safari checks remain the existing pre-campaign owner checks.

## Round 2 fixes (starts at 57d9a6f2)

Acceptance: same-organizer door locks remain responsive during marketing pacing and HTTP; priority mail never waits on the bulk backoff; organizer verification stays at five/hour; checkout consent preserves request evidence; unsafe rollback refuses before schema changes. Agent-executed affected-flow QA uses isolated local databases and captured/simulated transport only.

- B3: future slots are reserved and committed before waiting, before the delivery lease or organizer locks. Authorization commits before HTTP; the existing frozen request/key, lease ownership check and sent-state persistence remain intact. A permission change during HTTP cannot recall an accepted message.
- N1: priority 429s use delayed job retries and never call the marketing backoff. Threaded probes also acquire the slot backoff promptly while marketing waits or performs HTTP.
- N2: organizer verification is independently fixed at five/hour, with a six-request throttle regression.
- N3: checkout captures IP and at most 500 user-agent characters and passes them through the background job into the append-only consent ledger. Request and job regressions cover both boundaries.
- N4: migration down refuses before DDL if any delivery lacks a legacy subject; see `docs/EMAIL_COMPLIANCE.md` for reconciliation requirements. Regressions cover safe restoration and refusal with an actual platform-only delivery.
- N5: self-tests use `emails`, checkout subscription capture uses `default`, and its confirmation uses `emails`. Commercial consent/suppression rules remain in effect.

Captured-mail Chromium journey: eight stages passed, using a synthetic admin and verified-address fixture, on the Round 2 implementation. Evidence: `/Users/agent/work/hafapass-email-evidence/round2-fixes/` (`result.json`, captured HTML and screenshots). No real Clerk authentication, external delivery, mobile Safari or real-device checks are claimed. No frontend files changed.

Validation on implementation commit `0d6705ade5e6cd41da2f2f05459ede66eecbbacc`:

- Full serial RSpec: **4,098 examples, zero failures**, 4 minutes 12.3 seconds. Final probe timings from that run: organizer lock **1.11 ms during slot wait**, **0.48 ms during HTTP** (required <200 ms); slot backoff **1.33 ms / 0.62 ms** respectively. Both barriers assert no open transaction, and replay sends no second request.
- RuboCop: **1,090 files, no offenses**. Brakeman: **zero errors, zero security warnings**.
- Actual migration refusal with populated email-base-only rows and an empty-delivery down/up cycle passed in a rolled-back transaction on the task demo DB.
- Captured-mail Chromium journey: **8/8 stages passed**. Frontend lint/Vitest not rerun because no frontend files changed.
- Task-owned API/Vite/browser processes stopped; lifecycle status has no active owned resources. Dropped `hafapass_round2fix233_test` and `hafapass_round2fix233_demo`; borrowed protected PostgreSQL remains available. Worktree and pre-existing untracked files retained. No merge, deploy or real email.

PR mapping: B3 and N1–N5 are implemented in `0d6705ad`; this QA record is a separate documentation commit. Lead owns final-head CI/review and the merge decision.

## Production-faithful schema correction (2026-11-24)

Scope: preserve already-applied production migration history and limit the schema delta to PR #233. Baseline: `origin/main` at `debe3fb92afd87cd0d8b9f077bac39a4dc7973d5`; worker started at `4a402cd1`. HafaPass is the live Guam ticketing platform; this correction changes schema preparation, not buyer or organizer UI. Acceptance is agent-executed database migration/schema verification and automated regression checks; no new browser or real-provider acceptance is claimed.

- Restored `20260720000002` and `20260720150000` byte-for-byte from `origin/main`. Kept the two-worker transactional/marketing assertions in `puma_cluster_spec`.
- Created `hafapass_pr233_schema_fix_test` on the existing protected localhost PostgreSQL service. Loaded `origin/main`'s schema, then ran `db:migrate`; the log confirms only `20261124140000`, `20261124140100`, `20261124140200`, `20261124140300`, `20261124150000`, and `20261124150100` ran. Each explicit Rails database command first asserted `current_database()` against this exact task DB.
- Rolled all six migrations down to `20261124100000`, then up again and dumped the schema. Preserved main's equivalent cast syntax for the existing attendee-info and door-check constraints to avoid unrelated PostgreSQL dump formatting changes. Reloaded the generated schema before full RSpec.
- Schema diff against `origin/main`: **78 lines changed, 76 insertions, 2 deletions**. Only the version, five email tables, follow consent columns, delivery links/recipient index/expanded subject constraint, and their foreign keys differ. Removing exactly those changes reproduces main's schema byte-for-byte.
- CI now explicitly uses `db:schema:load`; the two RSpec worker databases already use schema load in `scripts/ci_rspec.py`.

Follow-up outside #233: investigate the pre-existing full migration-chain replay failures on main (historical checkout recovery uses the current `Order` model and references refund/payment tables before the commerce-ledger migration). No fresh full-chain replay repair is included here. This correction verifies the production-shaped schema-load plus new-migrations path; it does not claim a successful from-zero historical replay.

Validation of the correction on the Mac mini (Ruby 3.3.14, PostgreSQL 16, Node 24): full RSpec **4,138 examples / 0 failures** (7m15s), full Vitest **2,426 passed / 3 skipped** (219 passing files, one skipped), RuboCop **1,100 files / no offenses**, CI-helper tests **6 passed**, `git diff --check` passed. The expanded delivery subject constraint and lower-recipient index are valid in the schema-loaded DB. All six new migrations completed both down and up.

Cleanup: dropped the task DB; foreground test processes finished, including the self-cleaning Puma integration test. Lifecycle status has no active owned resources. Protected pre-existing PostgreSQL remains running. Preserved the worktree and pre-existing `.codex/` and `EMAIL_AUDIT.md`. No merge or deployment; final-head CI/review remain lead-owned. The shared-context read-only check could not run because this host lacks `~/.config/shimizu-technology/agent-context.json`; applicable synced guidance was read directly.
