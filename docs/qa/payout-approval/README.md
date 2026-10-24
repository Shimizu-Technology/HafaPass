# Manual payout approval acceptance

Task base: `87c3e21d`, 24 October 2026. Implementation branch: `codex/hafapass-simple-payout-approval`. Hold: do not merge.

HåfaPass serves Guam event organizers, buyers and event staff. This change serves the sole platform admin and organization owners/finance members setting up check or approved bank-transfer payouts. Stripe buyer payments remain separate. HåfaPass collects as the organizer's limited agent. No production payments or external email sends are part of this verification.

Sources: `CLAUDE.md`; `Organization#payout_ready?`, `ConnectedAccount#payout_ready?`, `PaymentReadinessReviews::Manager`; organizer tax updater and connected-account controllers; dashboard and organization pages; `.github/workflows/ci.yml`. Brain Dump `work/shimizu-tech/future-builds.md` describes the Guam ticketing purpose; its May status is historical, so repository code and this task define current behavior. Main at task start is `87c3e21d`; production behavior was not exercised.

The existing review model and manager permit the submitter to approve. Manual approval intentionally uses one admin action, retaining separate append-only submission and approval records in a transaction. Manual controls describe the human review; they do not falsely affirm the provider integration checklist. Provider-integrated accounts retain detailed evidence review. The policy register is out of scope and `config/policies.yml` must remain unchanged.

The experience follows the existing brand and operational layout: readable review details, visible missing prerequisites, 44px touch targets, named dialogs, keyboard focus, optional approval note, required change-request note, review date defaulting to twelve months, and stable context after actions. Routine save feedback is immediate; no new expressive motion is needed. Browser resizing covers responsive web, not physical-device keyboard or native/PWA behavior.

Agent-executed affected-flow QA. Dedicated local database `hafapass_payout_approval`; API 3059 and Vite 5229 if feasible. Local sends/payments must be simulated or disabled. Fixture setup and saved-state inspection may use Rails; UI journeys must use the actual interface.

| Case | Preconditions, action and expected result | Coverage | Result |
| --- | --- | --- | --- |
| P1 | Admin dashboard lists unapproved check/bank methods, count, newest first, owner, masked W-9, payout details and missing reasons. Organization page exposes the same action. | 375/1280, desktop keyboard | pending |
| P2 | Certified W-9 and complete check details: confirm three items and approve; persisted provider status + submission + approval, organizer approved status and queued email. Paid event can publish. | 375/1280 | pending |
| P3 | Missing W-9 or bank details: disabled approval explains why; API also rejects it without mutation. | 375/1280, server | pending |
| P4 | Ask for changes with a note; organizer sees it, notification contains it, existing approval is revoked append-only. Blank/sensitive notes rejected. | 375/1280, server | pending |
| P5 | Organizer changes check details or W-9; approval drops and queue returns. Bank replacement with identical last four also invalidates approval. | 375/1280, server | pending |
| P6 | Stale review/invalid date/unchecked items/repeated submission fails safely; permission denial and API failure allow recovery without losing the draft. | keyboard, server, browser fixtures | pending |
| P7 | Non-admin cannot approve/request changes; no full TIN/bank number in ordinary responses, snapshots, audits, or notification metadata. Registry covers new actions. | server | pending |
| P8 | Detailed evidence remains available for integrated providers; manual happy path has no evidence hash entry or “Gate B” copy. | browser fixtures | pending |

Automated checks and live UI results will be recorded separately below with tested commits, evidence paths and environment limits.
