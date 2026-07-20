# HåfaPass Pilot Readiness and Incident Runbook

Status: engineering implementation complete; external approvals and production drills required before paid pilot inventory opens.

## Release authority and named ownership

The proposed primary event-day/on-call owner is **Leon Shimizu, Shimizu Technology**. This assignment must be explicitly confirmed for each pilot event, with a named backup, phone number, and private escalation channel recorded in the deployment system—not in source control. The event organizer must also name an event commander, door lead, finance contact, and venue safety contact.

No one person may silently approve their own production payment configuration, payout evidence, or reconciliation exception. The existing role and audit controls remain authoritative.

## Hard production gates

Do not open paid pilot inventory until every item has dated evidence and an owner:

- GitHub release commit is green, reviewed, and deployable; no open P0 finding.
- Guam/US counsel approves buyer terms, organizer agreement, privacy, acceptable use, refunds/cancellations, and retention schedule.
- Accounting approves merchant-of-record, tax, fee, reserve, negative-balance, refund, and payout treatment.
- The selected provider confirms Guam, the exact HåfaPass entity, platform flow, bank accounts, disputes, refunds, and payouts in writing.
- Resend domain and webhook are verified; a real delivery, hard-bounce test address, and suppression event are visible in the support console.
- Sentry and uptime alerts are configured with the named primary and backup on call.
- An isolated backup restore and deploy rollback drill pass.
- A low-value live charge and full refund reconcile to zero variance.
- The three-device offline admission drill in [Event-Day Operations](EVENT_DAY_OPERATIONS.md) passes.
- Desktop and mobile pilot scripts below pass with keyboard and screen-reader spot checks.

## Production configuration checklist

Core: `DATABASE_URL`, `REDIS_URL`, Clerk keys, `ALLOWED_ORIGINS`, `FRONTEND_URL`, `GIT_SHA`, and independently supervised web/worker processes.

Communication: `RESEND_API_KEY`, `RESEND_WEBHOOK_SECRET`, verified `MAILER_FROM_EMAIL`, production webhook URL `/webhooks/resend`, and subscriptions for sent, delivered, delayed, failed, bounced, complained, and suppressed events. Resend requests use the persisted delivery idempotency key; webhook deduplication uses `svix-id` and the raw signed body.

The implementation follows Resend's official [idempotency-key guidance](https://resend.com/docs/dashboard/emails/idempotency-keys), [webhook signature verification](https://resend.com/docs/webhooks/verify-webhooks-requests), [at-least-once delivery/deduplication guidance](https://resend.com/docs/webhooks/introduction), [event types](https://resend.com/docs/webhooks/event-types), and [suppression behavior](https://resend.com/docs/dashboard/emails/email-suppressions). Provider-delayed events are observed rather than blindly resent; a hard bounce or complaint suppresses subsequent sends until the underlying address/provider state is deliberately resolved.

Monitoring: backend/frontend Sentry DSNs, environment/release tags, uptime probes, payment/webhook/email/job alert routing, and a synthetic readiness check. Readiness exposes only counts—not recipients, payloads, credentials, or payment details.

Money/event-day providers: complete the evidence gates in [Guam Payment and Payout Decision](GUAM_PAYMENT_AND_PAYOUT_DECISION.md), [Settlement and Payout Operations](SETTLEMENT_AND_PAYOUT_OPERATIONS.md), and [Event-Day Operations](EVENT_DAY_OPERATIONS.md).

## Incident severity and response

| Severity | Examples | Response |
|---|---|---|
| P0 | duplicate charge, oversell, credential compromise, cross-tenant disclosure, widespread entry failure | Page primary and backup immediately; stop the risky operation; preserve evidence; announce an incident commander |
| P1 | payment/webhook uncertainty, payout variance, high delivery failure, scanner reconciliation backlog | Page primary within 15 minutes; pause affected flow; reconcile before replay |
| P2 | isolated delivery failure, individual ticket/support issue, degraded noncritical feature | Ticket and handle within the event support window |

For every incident: record UTC and Guam timestamps, scope, release, request/job/provider IDs, decisions, customer impact, recovery, reconciliation, and follow-up. Never paste secrets, raw webhook bodies, complete payment data, or unnecessary PII into tickets or chat.

## Provider outage

1. Confirm the outage using readiness, provider status, and persisted attempts/events.
2. Stop new operations whose outcome cannot be known. Do not convert an unknown charge/refund result into a retry.
3. Preserve the original idempotency key and provider reference.
4. For email, distinguish API failure (safe job retry with the same key) from delayed/bounced/complained/suppressed provider events (do not blindly resend).
5. For payments, compare provider state to the immutable local ledger and open a reconciliation exception for every mismatch.
6. Use documented cash/manual fallbacks only when the event and accounting plan pre-authorized them.
7. Reconcile the full outage window before declaring recovery.

## Refund incident

Pause refund processing when provider state is unknown, refunds exceed charged value, ticket states disagree, or a dispute is open. Lock the order, compare payment/refund provider evidence to local immutable amounts, resolve or document each exception, then retry using the existing idempotency key only when the original operation definitely failed. Notify the buyer through a durable delivery record after success.

## Weather, typhoon, cancellation, and reschedule

The event commander decides operational safety; HåfaPass does not override venue/emergency authorities. Record the reason and effective time, use the event lifecycle action, stop sales, publish accurate Guam-local times, notify affected orders, and expose the accept/refund response path. Never mark an event cancelled merely to release inventory or force a payout state.

## Rollback

1. Identify the last known-good commit and confirm its database compatibility.
2. Stop deploys and risky background replays.
3. Back up current database/object state and record the release IDs.
4. Roll back application code through the hosting platform; do not reverse a destructive migration unless its reviewed down path is proven.
5. Confirm health/readiness, worker registration, checkout isolation, delivery processing, and one safe representative flow.
6. Reconcile work created during the affected release window.

## Backup and restore drill

Run at least once before pilot and quarterly thereafter:

1. Produce an encrypted database backup and inventory required object-storage assets.
2. Restore into a new isolated environment with network delivery/payment credentials disabled.
3. Verify row counts and sampled orders, tickets, ledger entries, audits, admission actions, delivery events, and policy snapshots.
4. Run integrity checks and the application test smoke set against the restored environment.
5. Record backup ID, start/end time, RPO/RTO, verifier, discrepancies, and secure destruction date for the drill environment.

Never restore a production backup onto a developer laptop or an environment with active provider credentials.

## Alert drill

Trigger controlled non-PII failures for: application exception, background job, payment/webhook processing, reconciliation exception, and message delivery. Confirm routing to the primary and backup, acknowledge each alert, locate it by release/request/job/provider ID, and close it only after the persisted state is verified. Remove the test trigger afterward.

## Manual pilot matrix

Run on current iOS Safari, Android Chrome, desktop Chrome, Safari, Firefox, and Edge where available:

1. Browse/search an event; verify Guam date/time, venue, policy, price, fee, availability, focus order, zoom, contrast, and alt text.
2. Complete guest and signed-in free checkout; complete approved low-value paid checkout; reject stale terms acceptance.
3. Recover an order, open consolidated fulfillment, present a ticket, and confirm private pages are not cached.
4. Resend from support; force API failure/retry; ingest delivered, bounced, complained, and suppressed events; verify actor/time/status.
5. Cancel/postpone/reschedule and process eligible full/partial/ticket refunds.
6. Exercise organizer roles, event lifecycle, attendee export boundaries, finance isolation, and support least privilege.
7. Run the offline scanner, multi-device collision, door list, cash sale, and approved card-present scenarios.
8. Navigate buyer, organizer, scanner, and support critical paths using keyboard only; spot-check VoiceOver and TalkBack announcements and labels.

Record device/browser versions, tester, timestamp, result, screenshots without PII, and issue links. A failed P0/P1 scenario blocks pilot.

## Closeout

Reconcile payments/refunds/fees/settlements/payouts to zero unexplained variance; resolve admission and message exceptions; export the incident and pilot evidence register; revoke temporary staff/devices; purge offline scanner data within the approved window; and hold a retrospective before expanding inventory.
