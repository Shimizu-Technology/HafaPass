# Gate I Bounded Live-Pilot Operations

Status: application control implemented; a real pilot, named people, provider observations, and external evidence are still required.

## Purpose

Gate I is the production operating boundary between “the prerequisites passed” and “HafaPass may sell a small amount of real inventory.” Gates E–H prove the selected event, release candidate, physical event-day path, and applicable live-money path. Gate I does not repeat those proofs. It binds their exact current approvals to a deliberately small plan, opens sales only while an authorized run is active, pauses on uncertainty, and refuses closeout until the event and local operations are reconciled.

Passing automated tests or clicking every control does not prove a real pilot happened. Evidence references must point to the restricted operating bundle. Do not store telephone numbers, identity documents, attendee data, secrets, raw provider payloads, or payment credentials in Gate I records.

## Enforced boundary

- One event-specific plan is bound to the current event-state digest, application revision, Gate G approval, and—when the event has paid inventory—the exact current Gate H approval.
- Inventory is capped at the lower of the approved value, configured event inventory/capacity, and 250 tickets.
- A plan records support coverage before, during, and for at least two hours after the event; named primary/backup/channel acknowledgement references; eight accountable operating roles; measurable pause thresholds; and every required response/go-no-go control.
- The plan submitter cannot approve the same plan. Submissions, decisions, incidents, checkpoints, and action records are append-only; revocation and incident resolution are new records.
- A normal production event cannot publish/resume or accept public, internal, or box-office checkout without a current Gate I approval. Checkout remains closed until the approved pilot run is active.
- Order creation holds the event lock and rechecks committed ticket quantities against the Gate I cap before creating the order, so concurrent channels share one boundary.
- A P0/P1 incident or any uncertain payment, duplicate charge, oversell, credential compromise, cross-tenant disclosure, or widespread entry failure pauses the run and suspends event sales.
- A monitoring breach pauses an active run. Current monitoring includes checkout conversion, payment failures, hold expiry, delivery failures, scanner conflicts and sync lag, checkout p95, support contacts, provider health, support coverage, Guam communications, reconciliation exceptions, and unknown card-present outcomes.
- Resume requires the approval to remain current, every pause-required incident to be resolved with evidence, and a safe checkpoint whose observation and persisted record both postdate the pause.
- Completion requires the event to be marked completed, a persisted safe post-event checkpoint, no unresolved pause-required incident, zero pending payment/refund/hold/reconciliation/unknown-card/P0-P1 counts, explicit zero variances/exceptions, all closeout affirmations, and a restricted evidence reference plus lowercase SHA-256.

The hidden Gate H proof candidate is excluded from Gate I. It is a one-transaction finance proof, not a public pilot event.

## Before submitting a plan

1. Freeze and deploy the exact reviewed release candidate. Confirm the application revision shown by the Gate I screen.
2. Confirm the event has the exact current Gate G approval. For paid inventory, confirm Gate H is current for the event organization, provider/account configuration, and application revision.
3. Select an inventory cap based on support, venue, provider, scanner, and reconciliation capacity—not desired revenue. The first pilot should be materially below 250 when uncertainty remains.
4. Avoid a high-demand public announcement. State the approved audience, release time/window, partner links, and who can stop promotion.
5. In the private operating system, assign and obtain acknowledgement from:
   - incident commander;
   - business owner;
   - technical lead;
   - finance monitor;
   - support lead;
   - admissions lead;
   - organizer contact; and
   - venue contact.
6. Record primary and backup support coverage before, during, and after the event. The public-facing path must give Guam buyers and organizers a usable local response channel.
7. Choose thresholds from rehearsed capacity and provider evidence. Zero scanner conflicts is a valid threshold. Do not loosen a threshold during an incident to make the dashboard green.
8. Prepare the restricted plan/evidence bundle, calculate its SHA-256, submit it in Admin → Events → Prepare Gate I bounded pilot, and have a different administrator inspect and approve it.

Any material event, Gate G, Gate H, provider/configuration, or deployed application change invalidates the approval. Submit a new plan; do not edit old evidence.

## Starting and monitoring

1. Publish the approved event. Confirm the private incident bridge, support channel, provider dashboards, application monitoring, worker/readiness state, venue contacts, scanner/device status, and pause authority.
2. Start the bounded pilot in the Gate I console. Sales are authorized only while the run shows `active`.
3. Record checkpoints at minimum:
   - immediately after activation;
   - after the first successful checkout and the first provider outcome;
   - at each planned inventory-release interval;
   - before doors;
   - during peak entry;
   - after entry queues drain;
   - after the event is marked completed; and
   - after every incident recovery, before resume.
4. Attach provider-status and restricted evidence references. HafaPass derives local counts from immutable data; the operator supplies facts that the application cannot self-observe, such as external provider health, actual checkout latency, scanner lag, support coverage, and whether Guam-facing communications are current.
5. Compare funnel volume as well as rates. A zero rate with no attempts is not proof of conversion quality. Preserve dashboard/export evidence needed for Gate J.

## Pause, incident, and resume rules

Pause immediately when an outcome is unknown or continued operation can amplify harm. The console auto-pauses on configured breaches, but the incident commander must not wait for automation.

1. Enter a specific pause reason or report the incident. A Gate I pause also sets the event sales-suspension reason.
2. Stop the affected operation and promotion. Do not blindly retry payments, refunds, payouts, messages, or card-present attempts with unknown outcomes.
3. Preserve request, order, provider, device, release, and Guam/UTC timing references in the restricted incident bundle.
4. Reconcile the actual provider/local state and customer impact. Communicate schedule, entry, refund, or policy changes promptly using Guam-local time.
5. Resolve the incident with a separate evidence record.
6. Record a new safe checkpoint after the pause. Resume only when the console accepts the checkpoint and every mandatory incident is resolved.

Abort when the event cannot safely continue on this plan. Aborting leaves sales suspended. It is not a successful Gate I exit and cannot be converted into one by editing records.

## Completion and exit evidence

After the event:

1. Stop sales as appropriate and mark the event completed through the governed lifecycle.
2. Reconcile every payment outcome, refund, inventory hold, delivery, scanner device/queue/conflict, admission variance, support escalation, reconciliation exception, and card-present unknown result.
3. Record a new safe post-event checkpoint. A checkpoint created before event completion is deliberately rejected as final evidence.
4. Assemble the restricted closeout bundle and SHA-256.
5. Affirm every closeout result and enter zero unexplained payment, inventory, admission, and operating-exception variance.
6. Complete Gate I in the console. Export/reference the append-only plan, decision, run actions, checkpoints, incidents/resolutions, and completion evidence for Gate J.

Gate I exits successfully only when the run is `completed`. This proves that HafaPass enforced the recorded software boundary and that administrators attested to the referenced evidence. It does not independently verify external provider exports, bank records, physical staffing, legal authority, or customer outcomes; those artifacts must be inspected during Gate J.

## Operator API map

All routes are admin-only and audit logged.

| Action | Route |
|---|---|
| Inspect event Gate I state | `GET /api/v1/admin/events/:event_id/live_pilot` |
| Submit plan | `POST /api/v1/admin/events/:event_id/live_pilot_reviews` |
| Approve/reject/revoke | `POST /api/v1/admin/live_pilot_reviews/:id/{approve,reject,revoke}` |
| Start approved run | `POST /api/v1/admin/live_pilot_reviews/:id/start` |
| Pause/resume/abort | `POST /api/v1/admin/live_pilot_runs/:id/{pause,resume,abort}` |
| Record checkpoint | `POST /api/v1/admin/live_pilot_runs/:id/checkpoint` |
| Report incident | `POST /api/v1/admin/live_pilot_runs/:id/incidents` |
| Resolve incident | `POST /api/v1/admin/live_pilot_incidents/:id/resolve` |
| Complete reconciled run | `POST /api/v1/admin/live_pilot_runs/:id/complete` |

## Evidence boundary

Gate I records deliberately contain operational summaries and restricted references. Access to referenced evidence must be least-privilege, retained under the approved policy, and auditable. A digest mismatch, missing artifact, unnamed/unavailable operator, provider dashboard that cannot be reconciled, or unsupported attestation is a failed gate—not an administrative correction.
