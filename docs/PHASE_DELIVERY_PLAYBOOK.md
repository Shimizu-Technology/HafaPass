# HafaPass Phase Delivery Playbook

Status: required implementation and review process
Last verified: July 20, 2026 (Pacific/Guam)
Product requirements: [TICKETING_PLATFORM_BLUEPRINT.md](TICKETING_PLATFORM_BLUEPRINT.md)

## 1. Purpose

This playbook defines how every HafaPass platform phase is implemented, tested, reviewed, merged, and proven complete. The phases are sequential because later work depends on invariants established by earlier work.

No phase is complete merely because code was written or automated tests are green. Each phase must close the full feedback loop:

1. Start from current `main`.
2. Implement the complete phase scope.
3. Run focused tests during development.
4. Run the full local gate.
5. Start the real backend and frontend.
6. Exercise relevant public/authenticated flows in a browser.
7. Fix defects and repeat the gate/runtime checks.
8. Push a dedicated phase branch and open a PR.
9. Address Greptile feedback until the PR is a clean 5/5.
10. Confirm CI and review state, merge to `main`, update local `main`, and only then create the next phase branch.

## 2. Non-negotiable source-control rules

- Each phase has exactly one primary phase branch from the latest `origin/main`.
- Branches use the `codex/phase-NN-description` convention.
- Never build the next phase on an unmerged phase branch.
- Never mix unrelated user worktree changes into a phase commit.
- Stage explicit files when the worktree is mixed.
- Migrations are additive and reversible where the data model permits.
- Do not rewrite or squash away evidence needed to understand financial migrations.
- PR descriptions list requirements delivered, schema/API changes, migration/rollback notes, gate results, browser evidence, remaining risks, and screenshots for UI changes.
- The final merge method must preserve a coherent audit trail and must not bypass required checks.

## 3. Secret and test-account policy

The user has authorized local testing with compatible test credentials from another Shimizu project, including Hafaloha, until HafaPass receives dedicated keys. That authorization does not permit secrets to appear in source control, logs, PRs, screenshots, shell history, documentation, or assistant responses.

Rules:

- Never commit `.env` files, secret keys, webhook secrets, private keys, or copied credentials.
- Never print secret values to terminal output.
- Use environment-variable names and configuration-status checks in code.
- Use only test/sandbox credentials for automated and local payment flows.
- Prefer already-injected environment variables or a securely created untracked local environment file.
- Verify that a borrowed credential is compatible with the intended service and environment before using it.
- Do not send production email/SMS, create live charges, upload private customer files, or change production infrastructure during local verification.
- Before production launch, replace every borrowed key with a dedicated HafaPass key and rotate any credential that was unnecessarily exposed.
- Continue following `AGENTS.md`: Clerk browser testing uses `TEST_USER_EMAIL`, `TEST_USER_PASSWORD`, and `TEST_BASE_URL` without reading or exposing `.env` contents.

## 4. Required verification layers

### 4.1 Focused development tests

Each behavior starts with a failing test when practical. Run the narrowest relevant test during iteration, then the full suite before review.

Backend examples:

```bash
cd hafapass_api
RBENV_VERSION=3.3.4 rbenv exec bundle exec rspec spec/path/to/spec.rb
```

Frontend examples after Phase 1 establishes the test runner:

```bash
cd hafapass_frontend
npm run test -- --run src/path/to/test
npm run test:e2e -- path/to/spec
```

### 4.2 Full local gate

Phase 1 creates `scripts/gate.sh`. From then on, every phase must finish with:

```bash
./scripts/gate.sh
```

The gate must match CI and include:

- Backend RSpec.
- Backend lint.
- Brakeman.
- Bundler dependency audit.
- Frontend lint with zero warnings.
- Frontend unit/component tests.
- Frontend production build.
- Production dependency audit.
- End-to-end smoke tests where they can run deterministically.
- Repository hygiene checks for debug statements and accidentally tracked secrets.

Until Phase 1 merges, use the verified baseline commands:

```bash
cd hafapass_api
RBENV_VERSION=3.3.4 rbenv exec bundle exec rspec

cd ../hafapass_frontend
npm run lint
npm run build
npm audit --omit=dev
```

### 4.3 Runtime and browser verification

After the gate passes:

```bash
cd hafapass_api
rails server
```

```bash
cd hafapass_frontend
npm run dev
```

Use the configured local ports if the defaults are occupied. The frontend API base must target the local backend.

For authenticated QA, use Clerk test credentials exposed through the permitted test environment. Browser verification must cover:

- Desktop viewport.
- Mobile viewport.
- Public/guest behavior.
- Authenticated attendee behavior.
- Organizer behavior when the phase affects organizers.
- Staff/admin behavior when the phase affects privileged operations.
- Error, loading, empty, unavailable, and recovery states.
- Keyboard and screen-reader-relevant semantics for changed UI.
- Browser console and failed-network-request inspection.

Capture screenshots for material UI changes and attach them to the PR when possible.

### 4.4 Data and external-provider verification

Payment, email, upload, and payout phases require sandbox/provider evidence in addition to mocked tests. Provider callbacks must be exercised through signed test events or provider CLI tooling. Test records must be clearly identifiable and removable through safe application workflows.

## 5. Greptile 5/5 review loop

Every phase PR follows this loop:

1. Push the branch and open the PR as draft while validation is being completed.
2. Request or trigger Greptile review according to repository integration behavior.
3. Read the full PR review, inline threads, score, and CI state.
4. Classify every comment as actionable, clarification, duplicate, outdated, or incorrect.
5. Implement all valid actionable feedback and add regression tests.
6. For a technically incorrect or conflicting comment, respond with concrete code/test evidence; do not make a harmful change solely to increase the score.
7. Push fixes and re-request review.
8. Repeat until Greptile reports a clean 5/5 and no unresolved actionable thread remains.
9. Re-run/confirm the full gate on the reviewed commit.
10. Mark the PR ready and merge only when required GitHub checks are green.

A 5/5 score does not override failing tests, an unresolved security defect, or a contradiction with the blueprint.

If Greptile is unavailable, delayed, uninstalled, or cannot produce a score, do not misrepresent the phase as Greptile-approved. Continue all local/CI verification and record the external-review blocker until the integration becomes available.

## 6. Phase plan

### Phase 0 — Blueprint and delivery governance

Branch: `codex/phase-00-ticketing-blueprint`

Deliverables:

- Authoritative product and architecture blueprint.
- Verified risk register and competitor corrections.
- Requirements by priority and domain.
- Target domain model and lifecycle definitions.
- Phase branches, dependencies, tests, and exit gates.
- Secret-handling and external-provider policy.
- README pointers and legacy-document deprecation.

Verification:

- Internal links resolve.
- Markdown structure is consistent.
- Current audit facts and test baseline are accurate.
- Legacy documents no longer contradict the source of truth.

Exit:

- Documentation PR has Greptile 5/5, green checks, and is merged.

### Phase 1 — Engineering safety and production visibility

Branch: `codex/phase-01-engineering-foundation`

Requirements:

- Move GitHub Actions and dependency automation to repository root.
- Correct backend/frontend working directories and caches.
- Run RSpec rather than Minitest.
- Add/repair RuboCop, Brakeman, bundler-audit, ESLint, frontend test runner, Playwright, build, and npm audit.
- Add `scripts/gate.sh` as the one-command local/CI contract.
- Resolve current production npm vulnerabilities.
- Remove all lint warnings or explicitly fix their underlying behavior.
- Split the initial frontend bundle where practical and enforce a reasoned bundle threshold.
- Provision/document durable Sidekiq/Redis worker execution.
- Add structured logging, error monitoring interfaces, health/readiness checks, and alerts for jobs/webhooks/payments.
- Add secret-scan and debug-statement hygiene checks.

Automated acceptance:

- A deliberately failing RSpec, frontend test, lint, build, and security scan blocks CI in a controlled verification.
- Gate and CI run equivalent checks.
- Critical buyer/organizer route smoke tests exist.

Runtime acceptance:

- Backend, worker, and frontend start locally.
- Health/readiness distinguish web, database, Redis/worker, and provider configuration.
- A controlled failed job/error is visible without exposing secrets.

### Phase 2 — Commerce ledger and inventory correctness

Branch: `codex/phase-02-commerce-ledger`

Requirements:

- Add immutable order items and fee components.
- Add inventory holds with expiry and scheduled release.
- Add payments, payment events, and raw webhook events.
- Add refund/refund-item ledger.
- Add database constraints and uniqueness for payment intents, organization profiles, money, quantities, and important state.
- Implement locked inventory/capacity allocation.
- Implement promo reservation/finalization/release.
- Replace webhook branching with idempotent state transitions.
- Validate provider amount/currency and record reconciliation exceptions.
- Prevent destructive deletion of events and financial records.
- Correct analytics to gross, discount, refund, net, fee, organizer proceeds, and payout-ready balances.
- Backfill existing development data safely and document production migration strategy.

Automated acceptance matrix:

- Final-ticket concurrency.
- Event-capacity concurrency.
- Pending order expiry.
- Duplicate and out-of-order webhook delivery.
- Late success after client cancellation or reported failure.
- Provider amount/currency mismatch.
- Unlimited and limited promo use/release.
- Multiple partial refunds and concurrent refund attempts.
- Ticket-type edits do not change historical order items.
- Event destroy cannot erase ledger history.

Runtime acceptance:

- Stripe test checkout, expiry, success, decline, refund, and replay are visible in the ledger/admin surfaces.
- Local totals reconcile to Stripe test events.

### Phase 3 — Organizer trust, event integrity, ChST, and marketplace truth

Branch: `codex/phase-03-events-and-time`

Requirements:

- Remove privileged organizer mass-assignment fields.
- Add explicit organizer verification/readiness state.
- Add publish command/checklist and archive/cancel/complete commands.
- Enforce venue, date, ticket, capacity, policy, and payout prerequisites.
- Implement IANA event-time parsing with `Pacific/Guam` default.
- Format event times consistently in public pages, organizer pages, email, PDF, exports, calendars, and scanner.
- Prevent sales for ended/cancelled/postponed/not-on-sale events.
- Correct clone/recurrence rules and pricing-window behavior.
- Create one category taxonomy and server-side search/filter/pagination.
- Return upcoming purchasable inventory by default.
- Correct attendee counts, SEO fields, canonical domain, social metadata, and sitemap.

Automated acceptance:

- Organizer cannot self-feature, self-partner, or set arbitrary status.
- Incomplete/past events cannot publish or sell.
- Guam 7:00 PM remains 7:00 PM ChST across all output surfaces.
- Viewer browser timezone does not silently change venue time.
- Category deep links, pagination, search, and date filters cover records beyond page one.

Runtime acceptance:

- Create, preview, publish, discover, edit, postpone/cancel, and archive an event through the browser.
- Validate desktop/mobile and a non-Guam browser timezone.

### Phase 4 — Checkout recovery, secure tickets, and buyer lifecycle

Branch: `codex/phase-04-checkout-and-tickets`

Requirements:

- Secure guest order access tokens and recovery.
- Correct Stripe return URL and payment-state restoration.
- Checkout expiry timer and clear all-in fee presentation.
- Explicit fee behavior for free events.
- Server-authoritative confirmation and safe refresh/revisit behavior.
- Separate revocable ticket display and scan credentials.
- Remove public attendee PII exposure.
- Self-service ticket resend and order lookup.
- Ticket-level refund/cancellation support.
- Cancellation, postponement, and reschedule buyer actions.
- Dispute state and ticket access policy.
- Rate/purchase limits and practical bot protection.

Automated acceptance:

- Guest and authenticated success.
- Free checkout.
- Card decline and 3DS success/failure.
- Browser close/reload before and after provider completion.
- Duplicate webhook does not issue duplicate tickets.
- Compromised/rotated QR is rejected.
- Guest cannot access another guest order.
- Public ticket endpoint exposes no unnecessary personal data.

Runtime acceptance:

- Complete the matrix using Stripe test tooling and real browser redirects.
- Confirm buyer recovery and resend on mobile.

### Phase 5 — Organizations, roles, settlements, and payouts

Branch: `codex/phase-05-organizations-and-payouts`

Prerequisite decision:

- Confirm Guam business/bank support, merchant of record, Connect account type, charge model, refund/dispute liability, reserves, and payout policy with Stripe/legal/accounting.

Requirements:

- Organizations and unique memberships.
- Owner, manager, finance, marketer, box-office, and scanner roles.
- Event-level staff assignment.
- Stripe Connect onboarding and requirements-due state.
- Paid publishing blocked until payout-ready.
- Immutable settlement calculation and statement.
- Payout, reserve, adjustment, refund, dispute, and negative-balance reconciliation.
- Organizer financial dashboard with gross/refunds/net/fees/proceeds/payouts.
- Finance/admin actions audited.

Automated acceptance:

- Role-permission matrix.
- Connected-account readiness transitions.
- Settlement recalculation is deterministic and does not overwrite prior finalized statements.
- Refund/dispute adjustments reconcile correctly before and after payout.

Runtime acceptance:

- Test organizer onboarding through test Connect.
- Sell, refund, settle, and reconcile a test event to the cent.

### Phase 6 — Offline admissions and event-day operations

Branch: `codex/phase-06-event-day-operations`

Requirements:

- Authorized scanner devices and signed versioned manifests.
- Offline local manifest and scan queue.
- Cross-browser QR decoding plus manual lookup.
- Multi-device conflict reconciliation.
- Append-only check-ins and audited reversals.
- Staff-limited attendee information.
- Live admitted/remaining/device sync dashboard.
- Printable emergency door list.
- Cash door sales and confirmed supported card-present integration.
- Door inventory allocation that shares the central ledger.

Automated acceptance:

- Offline valid/invalid/duplicate scans.
- Same ticket scanned offline on multiple devices.
- Revoked/refunded/transferred ticket sync.
- Staff authorization expiry and event isolation.
- Door sale uses inventory and financial ledger correctly.

Runtime acceptance:

- Three-device simulation with internet loss and restoration.
- At least 500 generated tickets under representative scan load.
- Online p95 under 500 ms and immediate cached feedback.

### Phase 7 — Communications, support, compliance, and pilot

Branch: `codex/phase-07-pilot-readiness`

Requirements:

- Durable email/message deliveries and provider events.
- Safe consolidated ticket fulfillment.
- Escaped organizer/user content.
- Admin resend, bounce/suppression, and failure visibility.
- Event update/cancellation/reschedule/refund/waitlist templates.
- Support order/ticket/event lookup with least privilege.
- Buyer terms, organizer agreement, privacy, refund/cancellation, acceptable-use, and data-retention artifacts reviewed by professionals.
- Incident, event-day, provider-outage, refund, weather, rollback, backup, and restore runbooks.
- Production configuration checklist and named on-call ownership.

Automated acceptance:

- Delivery idempotency, retries, failure, bounce, and resend.
- HTML injection tests.
- Support/admin permission tests.
- Accessibility test suite and targeted manual keyboard/screen-reader QA.

Runtime/pilot acceptance:

- Real low-value test charge and refund.
- Backup restoration and rollback drill.
- Alert and incident drill.
- Full manual pilot plan on desktop and mobile.
- No open P0 findings.

### Phase 8 — Competitive general-admission platform

Branch: `codex/phase-08-competitive-features`

Requirements:

- Secure transfer acceptance and credential rotation.
- Apple and Google wallet passes.
- Waitlist offers with inventory holds, single-use tokens, expiry, and conversion.
- Donations, merchandise, concessions/add-ons.
- Registration questions, waivers, and consent snapshots.
- Promoter/referral attribution and commission reporting.
- Fee absorb/pass/split policies.
- Organizer CRM export/segments and scheduled communications.
- Maintainable Japanese/CHamoru content where selected.

Acceptance:

- Transfer, wallet, waitlist, add-on, waiver, donation, and promoter flows each have request/unit/E2E coverage.
- Transfer and waitlist concurrency cannot duplicate valid ownership or oversell.
- Financial features feed the same ledger and settlement engine.

### Phase 9 — Marketplace growth and Guam distribution

Branch: `codex/phase-09-marketplace-growth`

Requirements:

- Curated collections and administrator governance.
- Tonight, This Weekend, family, price, village, venue, and organizer discovery.
- Favorites, follows, reminders, and referrals.
- Venue/organizer credibility pages.
- Hotel, concierge, tourism, Ambros, and promoter distribution links.
- Privacy-safe conversion funnel and attribution analytics.
- Empty-marketplace safeguards and supply-health reporting.

Acceptance:

- Every acquisition source and referral can be measured through purchase without leaking personal data.
- Discovery queries are paginated, indexed, accessible, SEO-correct, and performant.

### Phase 10 — Assigned seating and larger venues

Branch: `codex/phase-10-assigned-seating`

Requirements:

- Reusable venues, layouts, sections, rows, seats, price zones, and obstructions.
- Event-specific seating configuration and holds.
- Accessible and companion-seat metadata, sales stages, prices, transfers, exchanges, and controlled release.
- High-contention seat allocation.
- Organizer/box-office seat map and buyer seat selection.
- Emergency operational controls and complete audit trail.
- Evaluate build-versus-integrate before implementing a proprietary map editor.

Acceptance:

- Seat contention cannot double-sell.
- Accessible-seat workflows satisfy approved policy and DOJ guidance.
- Keyboard and assistive-technology users can select equivalent seats.
- Transfer/refund/cancellation/door operations remain correct for assigned seats.

## 7. PR description template

```markdown
## Phase NN: Outcome

### Requirements delivered
- Blueprint IDs and behaviors

### Why
- User, financial, operational, or security problem solved

### Implementation
- Domain/API/UI changes
- Migrations and rollback considerations

### Verification
- Focused tests
- Full gate results
- Runtime/browser scenarios
- External provider scenarios

### Visual QA
- Desktop screenshot
- Mobile screenshot
- Error/recovery state screenshot

### Operations and risk
- Monitoring/runbook/config changes
- Known non-blocking follow-ups assigned to later blueprint phases
```

## 8. Merge checklist

- [ ] Complete phase scope is implemented; no unrecorded scope reduction.
- [ ] Focused regression tests cover discovered defects.
- [ ] Full local gate passes on the pushed commit.
- [ ] Backend/frontend/worker start successfully.
- [ ] Browser and external-provider checks pass.
- [ ] Documentation and runbooks reflect behavior.
- [ ] PR targets current `main` and contains only phase changes.
- [ ] GitHub CI is green.
- [ ] Greptile reports 5/5.
- [ ] No unresolved actionable review thread remains.
- [ ] Migration, rollback, security, privacy, and operations impacts are understood.
- [ ] PR is merged.
- [ ] Local `main` is updated from `origin/main` before the next branch.

## 9. Program completion audit

Before declaring the platform complete, create a requirement-by-requirement matrix from the blueprint. For each requirement, record:

- Merged PR and commit.
- Authoritative implementation file/migration.
- Automated tests proving the invariant.
- Runtime or provider evidence.
- Operational documentation.
- Current status: proven, contradicted, incomplete, insufficient evidence, or missing.

Only `proven` requirements count as complete. A passing broad test suite is not evidence for a behavior the suite does not exercise.
