# Gate G Physical Event-Day Rehearsal Evidence

Status: application controls implemented; real physical rehearsal evidence pending.

Gate G prevents an event from being published, resumed, or sold in production until an independent administrator approves a complete physical event-day rehearsal for the exact current Gate F candidate. CI proves the scanner, signed-manifest, offline queue, conflict, door-sale, and reconciliation code paths; it does not prove real cameras, batteries, venue connectivity, staff behavior, alerts, payment terminals, or a printed emergency list.

## What the application enforces

The rehearsal record is append-only and bound to the active Gate F approval, material event digest, deployed `GIT_SHA`, effective time, and expiry. Any Gate E/F revocation, application revision change, material event/organizer/venue/inventory/seating change, expiry, or Gate G revocation makes the approval unusable. A different administrator must approve the submitted snapshot.

Production publish/resume, public checkout, box office, and internal order creation fail closed while Gate G is absent or stale. Ordinary sales counters do not invalidate the event digest.

## Required evidence

Keep artifacts in approved restricted storage. HafaPass stores only references, digests, structured results, and decision records. Never upload raw attendee lists, ticket credentials, payment data, private contact details, or secrets to Git.

The submitted bundle must prove:

1. A signed RSA-PSS/SHA-256 manifest and emergency door list for a controlled production-like rehearsal event, with at least 500 generated tickets, SHA-256 digests, signing key ID, generation/expiry timestamps, and signature verification on every device.
2. At least three distinct physical devices. Each record includes model, OS/browser versions, private tester/artifact references, offline completion, manifest verification, queued actions before/after sync, conflict observations, reconnect order, offline-feedback p95, and battery/spare-device plans.
3. Unique, invalid, duplicate, refunded, transferred, rotated, payment-blocked, already-admitted, manual-lookup, reversal, cross-device duplicate, different reconnect-order, conflict-resolution, and queue-drain scenarios.
4. Controlled drills for payment-provider outage, venue internet loss, worker failure, severe application error, evacuation/sales pause, refund incident, and support escalation. Every drill needs an evidence reference, alert acknowledgement, and resolution reference.
5. Cash and card-present results. Each channel must either pass with reconciliation evidence or be explicitly disabled for the pilot with a signed-decision reference. Card-present evidence additionally requires the approved provider/account, a successful attempt, an unknown-outcome drill, and proof that staff did not retry blindly.
6. At least 500 generated tickets, matching expected/observed admissions and conflicts, online p95 at or below 500 ms, offline p95 at or below 100 ms, all devices synced, every card attempt resolved, zero queued actions, zero unresolved conflicts, and zero unexplained admission, inventory, cash, or card variance.
7. Named event commander, technical lead, door lead, finance contact, venue safety contact, and support escalation owner with private contact and acknowledgement references.
8. Stable signing-key, emergency-list privacy, spare-device/battery, venue-network fallback, cash/card policy, alert, issue-resolution, and explicit go-decision controls, with no open P0/P1 issue.

The database validates consistency and thresholds. The independent approver remains responsible for opening the restricted artifacts and confirming they are genuine, complete, representative, and tied to the stated candidate.

## Avoiding a circular publish dependency

Scanner manifests intentionally require a published event, while Gate G intentionally blocks the real production event from publishing. Run the rehearsal against a controlled production-like candidate or rehearsal clone where the release gate is not bypassing real public inventory. Record the rehearsal event/reference and prove its configuration matches the digest-bound production candidate. Do not temporarily publish the real production event, disable its controls, or create live buyer inventory merely to obtain a manifest.

## Decision procedure

1. Freeze the candidate and confirm Gate F is current.
2. Complete the before-doors checklist and three-device drill in [Event-Day Operations](EVENT_DAY_OPERATIONS.md), including provider/network/application incidents and final closeout.
3. Reconcile every device, admission, conflict, door order, cash amount, card attempt, and inventory movement. Any unexplained variance is a no-go.
4. Store the privacy-safe bundle in restricted storage and calculate its SHA-256.
5. Submit the complete structured Gate G record in Admin → Events.
6. A different administrator verifies the bundle and records approval or rejection. Revoke immediately after an integrity concern, failed repeat drill, newly discovered blocker, or material candidate change.

Gate G is necessary but not sufficient to launch. Gate H still requires the approved low-value live-money loop, and later gates govern the controlled pilot and closeout.
