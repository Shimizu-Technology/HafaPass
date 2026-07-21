# Gate J Pilot Closeout and Expansion Decision

Status: application control implemented; a real completed Gate I run and its restricted external evidence are still required
Last verified: July 21, 2026 (Pacific/Guam)
Parent plan: [Platform Completion Audit](PLATFORM_COMPLETION_AUDIT.md)

## Purpose and boundary

Gate J is the governed boundary between “the bounded pilot finished” and “HafaPass may deliberately operate another event.” It turns the completed Gate I run, current local operational state, external closeout evidence, measured outcomes, and retrospective actions into one append-only decision.

Gate J does not prove that a provider export, bank receipt, physical scan, support shift, buyer survey, organizer interview, device purge, or legal approval is authentic merely because an administrator supplied a reference. The two administrators must inspect the restricted artifacts. Never put attendee data, bank details, identity documents, raw provider payloads, credentials, private contact information, or other unnecessary PII in Gate J fields.

An approved Gate J decision also does not automatically publish an event, enable checkout, change provider readiness, override Gates A–I, enable unfinished product features, or authorize a region outside Guam. Every future event retains its own applicable release and readiness gates.

## Required starting state

Start only after the event's latest Gate I run is `completed`. Before HafaPass accepts a closeout submission, it recalculates the event and refuses to proceed while any of these local blockers remain:

- Pending payments or refunds, open disputes or reconciliation exceptions, unknown card-present outcomes, or payouts in flight.
- Unexpired inventory, catalog, or seat holds, or pending catalog fulfillment.
- Queued or delayed event/order/ticket messages.
- Active scanner devices or effective temporary event-staff assignments.
- Unresolved Gate I incidents.
- For any financial activity, a missing or stale finalized settlement or a non-zero difference between paid payouts and the current finalized settlement.

The application check is necessary but not sufficient. Finance and operations must also inspect provider, bank, venue, communications, support, device, and policy evidence before affirming closeout.

## Assemble the restricted closeout bundle

Keep the bundle in the approved private evidence system and record only a durable reference plus its lowercase SHA-256 digest in HafaPass. The bundle should contain:

1. The exact release candidate, completed Gate I run, plan, approval, actions, checkpoints, incidents, resolutions, completion evidence, and any exception history.
2. Order and provider exports covering sales, discounts, tax, buyer and organizer fees, refunds, disputes, add-ons, donations, cash/card door sales, settlement, payout, and bank receipt.
3. Admission reconciliation covering issued, valid, admitted, reversed, conflicted, rejected, and no-show tickets, including device sync completion.
4. Delivery and support evidence covering queued/delayed/failed/bounced/complained messages, affected customers, resolutions, and support contacts.
5. Cleanup evidence covering temporary staff revocation, scanner-device revocation, device-local data purge, and the approved retention policy.
6. A metric export and calculation notes, including denominators and collection windows.
7. Organizer feedback and an appropriately consented, privacy-safe buyer feedback summary.
8. The retrospective record, action owners, due dates, priorities, blocking status, and evidence references.

Gate J requires distinct evidence references for financial, provider, admission, support, cleanup, metrics, feedback, and retrospective material. A reference must be accessible to both reviewers and retained under the approved policy.

## Metrics and interpretation

HafaPass calculates the following local measures from its immutable/event-scoped records at submission time:

- Completed orders, ticket and add-on quantities, gross sales, discounts, tax, buyer/organizer fees, total charged, refunds, disputes, door cash/card sales, settlement, paid payout, and payout variance.
- Checkout starts, completed-order conversion, and abandonment. Rates are basis points (`10,000 = 100%`). If there are no checkout-start events, the rate is zero—not proof of excellent conversion.
- Valid tickets, net admitted tickets after reversals, no-shows, admission conflicts, and admission rejections.
- Message exceptions and support-note count.
- Average/maximum refund time from local creation to local success and payout time from settlement finalization/calculation to paid status.
- Attributed, partner-attributed, referral-attributed, and unattributed completed orders.

The operator supplies six outcomes the application cannot reliably infer: support-contact count, entry-latency p50 and p95 in milliseconds, organizer rating from 1–5, buyer response count, and buyer rating. With zero buyer responses, the buyer rating must be zero; otherwise it must be 1–5. HafaPass derives support contacts per 100 completed orders from those inputs.

Treat these as decision evidence, not vanity scores. Preserve sample method and size, define when entry timing begins and ends, separate provider delay from staff handling time, and explain missing or biased feedback. Compare counts and denominators as well as rates. A small first pilot is directional evidence, not statistical certainty.

## Reconcile and clean up

The submitter must affirm all of the following only after checking the referenced artifacts:

- Reconciled: sales, discounts, taxes, fees, refunds, disputes, add-ons, door sales, settlement, payout, scans, support cases, message exceptions, admission exceptions, and reconciliation exceptions.
- Completed cleanup: temporary staff revoked, scanner devices revoked, device-local data purged, and retention policy followed.

“Reconciled” means every difference is explained and resolved under an approved accounting/operating treatment; it does not mean changing local records to match an unexplained provider value. Any uncertainty keeps the gate on hold.

## Retrospective actions

Record between 1 and 25 concrete actions. Each action requires a title, private owner reference, ISO-8601 due date, `p0`–`p3` priority, `planned` or `completed` status, evidence reference, and an explicit `blocks_expansion` value. A planned action's due date must be after the closeout is signed.

An approval for anything beyond `hold` is refused while an expansion-blocking action remains planned. Do not classify a safety, money-integrity, access-control, accessibility, or widespread entry issue as non-blocking merely to approve another event.

## Allowed expansion decisions

Gate J permits exactly one of these decisions:

| Decision | Maximum authority | Required evidence |
|---|---|---|
| `hold` | Zero events and zero inventory; no expiry | Use when evidence is incomplete, outcomes are unsafe/uncertain, or fixes remain |
| `repeat_bounded_pilot` | One Guam event, 1–250 tickets, expiring within 90 days | Completed expansion-blocking actions and a defined rationale/window |
| `limited_guam_expansion` | 1–10 Guam events, 1–1,000 tickets per event, expiring within 90 days | Completed expansion-blocking actions plus explicit demand and operating-capacity evidence |

All decisions set `new_regions` to false. Gate J can recommend complex charts, a waiting room, or memberships/season products only when a product-evidence reference supports the recommendation. The recommendation records a measured next investment; it does not enable or implement that feature.

When evidence is mixed, choose the smaller authority. Expiry requires a new decision; authority is not silently renewable or transferable to another region.

## Two-person lifecycle

1. An administrator opens **Admin → Events → Gate J pilot closeout** for the completed event and confirms the displayed application revision and system metrics.
2. The administrator enters the bundle reference/digest, external outcomes, eight evidence references, every reconciliation and cleanup affirmation, retrospective actions, and the explicit expansion decision/scope.
3. HafaPass locks the event/run, recomputes blockers and metrics, captures a local-state digest, and creates an append-only submission.
4. A different administrator retrieves the same submission, opens every restricted reference, validates the calculations and claims, and approves or rejects it. The submitter cannot self-approve.
5. Immediately before approval, HafaPass recalculates the local metrics, local-state digest, and application revision. Any change requires a new submission; decisions cannot silently bless a different snapshot.
6. If later evidence invalidates an approval, an administrator records a specific append-only revocation reason. Correct the underlying issue and submit a new closeout rather than editing history.

A pending submission must be decided before another can be filed. A current approval must be revoked before a replacement submission. Rejection and revocation never delete the original record.

## API map

All endpoints require an authenticated administrator:

| Operation | Endpoint |
|---|---|
| Inspect the event's current Gate J state and metric snapshot | `GET /api/v1/admin/events/:event_id/pilot_closeout` |
| Submit closeout evidence and an expansion decision | `POST /api/v1/admin/events/:event_id/pilot_closeout_reviews` |
| Independently approve a submission | `POST /api/v1/admin/pilot_closeout_reviews/:id/approve` |
| Reject a submission with a reason | `POST /api/v1/admin/pilot_closeout_reviews/:id/reject` |
| Revoke an approval with a reason | `POST /api/v1/admin/pilot_closeout_reviews/:id/revoke` |

## Exit evidence

Gate J exits successfully only when the latest approval is not revoked and still matches the current application revision and local event-state digest. Retain:

- The completed Gate I run identifier and full append-only operating history.
- The Gate J submission, independent approval, application revision, local-state digest, bundle digest, and eight restricted evidence references.
- The system/local metric report plus definitions, denominators, collection windows, and external outcomes.
- Every reconciliation and cleanup attestation, with reviewer identity and timestamp.
- Retrospective actions and proof that every expansion-blocking action was completed before a non-hold approval.
- The exact bounded decision, Guam-only scope, inventory/event caps, expiry, rationale, and demand/capacity/product evidence where applicable.

An active approval is evidence that the recorded software and review controls were satisfied. It is not a general statement that HafaPass is “production ready,” and it never replaces the next event's readiness, provider, venue, staffing, or safety evidence.
