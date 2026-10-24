# Manual payout approval acceptance

**Review-fix update:** [review-fixes.md](review-fixes.md) supersedes the bank-entry/approval behavior and records the selected destination, check-only policy, identity fingerprints and refreshed evidence.

Task base: `87c3e21d`, 24 October 2026. Implementation branch: `codex/hafapass-simple-payout-approval`. Hold: do not merge.

HåfaPass serves Guam event organizers, buyers and event staff. This change serves the sole platform admin and organization owners/finance members setting up check or approved bank-transfer payouts. Stripe buyer payments remain separate. HåfaPass collects as the organizer's limited agent. No production payments or external email sends are part of this verification.

Sources: `CLAUDE.md`; `Organization#payout_ready?`, `ConnectedAccount#payout_ready?`, `PaymentReadinessReviews::Manager`; organizer tax updater and connected-account controllers; dashboard and organization pages; `.github/workflows/ci.yml`. Brain Dump `work/shimizu-tech/future-builds.md` describes the Guam ticketing purpose; its May status is historical, so repository code and this task define current behavior. Main at task start is `87c3e21d`; production behavior was not exercised.

The existing review model and manager permit the submitter to approve. Manual approval intentionally uses one admin action, retaining separate append-only submission and approval records in a transaction. Manual controls describe the human review; they do not falsely affirm the provider integration checklist. Provider-integrated accounts retain detailed evidence review. The policy register is out of scope and `config/policies.yml` must remain unchanged.

The experience follows the existing brand and operational layout: readable review details, visible missing prerequisites, 44px touch targets, named dialogs, keyboard focus, optional approval note, required change-request note, review date defaulting to twelve months, and stable context after actions. Routine save feedback is immediate; no new expressive motion is needed. Browser resizing covers responsive web, not physical-device keyboard or native/PWA behavior.

Agent-executed affected-flow QA. Dedicated local database `hafapass_payout_approval`; API 3059 and Vite 5229 if feasible. Local sends/payments must be simulated or disabled. Fixture setup and saved-state inspection may use Rails; UI journeys must use the actual interface.

| Case | Preconditions, action and expected result | Coverage | Result |
| --- | --- | --- | --- |
| P1 | Admin dashboard lists unapproved check/bank methods, count, newest first, owner, masked W-9, payout details and missing reasons. Organization page exposes the same action. | 375/1280, desktop keyboard | passed |
| P2 | Certified W-9 and complete check details: confirm three items and approve; persisted provider status + submission + approval, organizer approved status and queued email. Paid event can publish. | 375/1280 | passed |
| P3 | Missing W-9 or bank details: disabled approval explains why; API also rejects it without mutation. | 375/1280, server | passed |
| P4 | Ask for changes with a note; organizer sees it, notification contains it, existing approval is revoked append-only. Blank/sensitive notes rejected. | 375/1280, server | passed |
| P5 | Organizer changes check details or W-9; approval drops and queue returns. Bank replacement with identical last four also invalidates approval. | 375/1280, server | passed |
| P6 | Stale review/invalid date/unchecked items/repeated submission fails safely; permission denial and API failure allow recovery without losing the draft. | keyboard, server, browser fixtures | passed |
| P7 | Non-admin cannot approve/request changes; no full TIN/bank number in ordinary responses, snapshots, audits, or notification metadata. Registry covers new actions. | server | passed |
| P8 | Detailed evidence remains available for integrated providers; manual happy path has no evidence hash entry or “Gate B” copy. | browser fixtures | passed |

Application source exercised locally: `948c28b8` (the final app source before the evidence-only commit). The note fix permits ordinary Guam ZIP codes while continuing to block account references, known full account numbers, formatted long numeric sequences and TINs. The final app commit and engineering-gate results are recorded in the PR description.

Live checks used the repo's Clerk test user with a short-lived Clerk test sign-in ticket. No extra verification fixture or production authentication bypass was needed. T3 preview snapshots timed out twice, so the repo's agent-browser workflow drove a separate owned Chrome session. API 3059 and Vite 5229 used a freshly rebuilt synthetic database. Jobs used the test adapter and provider credentials were disabled; notifications were persisted and their content was checked by specs, with no external delivery.

Observed saved outcomes:

- A desktop check approval changed the queue count from two to one, set readiness true and created submission/approval rows with the same administrator, provider-status audit and a queued owner notification. Organizer settings showed the approved state at both widths.
- A phone-width check-address edit removed readiness and returned the account to the queue. An admin change request on the organization page appeared in the organizer's settings at both widths and queued a second notification.
- A phone-width bank form saved encrypted banking data and showed only the last four digits. Its phone-width admin approval created a separate review pair and queued a third notification. The draft paid event then published through the real desktop event editor; Rails confirmed `event.published` and persisted `published` status. No checkout or money movement occurred.
- The missing-W-9 fixture showed a disabled approval with its reason. Backend specs additionally cover incomplete bank details, W-9 re-certification, bank edits with unchanged last four digits, edits during pending/processing/held bank payouts, expiration, stale review conflicts, same-admin operation, rollback on audit failure, authorization and response/audit masking.

Browser fixture checks cover keyboard focus/trapping/Escape/return focus, failed-save retry with retained values, long organization/email values, no horizontal overflow, and axe serious/critical checks at 375 and 1280. The six payout cases include waiting, approved and changes-requested organizer states. The full Playwright run passed 133 cases; the six updated payout cases passed again after the final dialog and status-copy changes. Vitest passed 1,879 tests in 172 files. ESLint, build, npm production audit, RuboCop, Brakeman, Bundler Audit, release-freeze and secret/debug hygiene checks passed. The advisory Impeccable scan returned no findings across the changed UI files.

The first full RSpec run used the wrong database suffix and hit the concurrency suite's isolation safeguard. The second ran 3,241 examples with one static deletion-inventory failure: the new bank-string normalization needed an explicit in-memory exemption. That entry was corrected and the 19 affected examples passed. Final full RSpec validation is recorded in the PR description. Required GitHub Actions and CodeRabbit remain separate gates; this document does not claim review approval.

Limits: resized desktop Chrome, not a physical phone; no live W-9-edit journey, real buyer checkout, bank transfer/check issuance, actual email delivery, provider onboarding, or production deployment verification. Those state/security contracts are covered by the named server and fixture tests where applicable.

Evidence in this directory: `admin-queue-{375,1280}.png`, `approval-dialog-{375,1280}.png`, `admin-organization-{375,1280}.png`, `organizer-approved-{375,1280}.png`, `organizer-changes-{375,1280}.png`, `change-request-375.png`, `organizer-bank-375.png`, and `paid-event-published-1280.png`. All images use synthetic payout/tax data and mask TIN/account identifiers.

Lifecycle session `01a16b4d-b52e-7162-b141-9552498e73b2`: owned browser session, API and Vite servers were cleaned after QA. Protected/borrowed services, including the specified Docker ports and port 3011, were not changed. The task branch/worktree is held for PR review. Temporary QA databases are dropped before the final task handoff.

