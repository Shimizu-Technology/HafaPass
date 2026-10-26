# HåfaPass post-pilot plan

Planning baseline: October 26, 2026. Engineering release [PR #157](https://github.com/Shimizu-Technology/HafaPass/pull/157) is deployed at `bf83acee225aa3a57c19f526db4a9099c7d744d2` according to the release handoff. Deployment is not evidence that a paid pilot or physical-device acceptance has passed. This plan records the requested readiness, mobile and positioning direction; it does not authorize inventory, real transactions, provider sends or expansion.

The [production cutover](PRODUCTION_CUTOVER.md) describes current enforced controls. Detailed Gates E–J remain optional review records and never block publishing or sales. Use the [pilot runbook](PILOT_READINESS_RUNBOOK.md) and [event-day operations](EVENT_DAY_OPERATIONS.md) as operational preparation; optional reviews can record the evidence and closeout. The [platform blueprint](TICKETING_PLATFORM_BLUEPRINT.md) remains the broader roadmap. No native application, concessions or loyalty expansion is part of this follow-up.

## Before the first paid pilot

Record a named owner, date, device/build, result, evidence reference and unresolved issue for each required check. Keep contact details and transaction evidence in the restricted event evidence bundle.

- Test physical iPhones and Android phones: camera permission denial and recovery, QR scanning in venue lighting, ticket retrieval, offline admission, reconnect/sync, background/resume and account switching. Include revoked access and expired offline leases. A narrow desktop viewport is not physical-device evidence.
- Under separate explicit authorization, complete a real low-value purchase, actual ticket email delivery, ticket transfer, eligible refund and enabled wallet retrieval on the intended devices. Verify both visible outcomes and persisted/provider state. A synthetic provider or queued email does not establish real delivery or settlement.
- Complete an actual manual payout closeout using the approved finance process. Match buyer receipts/refunds, fees, organizer proceeds, payout evidence and unexplained variance; record holds and exceptions. A seeded paid payout or a successful test API response is not closeout evidence.
- Confirm primary support and backup, organizer event commander, door lead, finance owner, escalation route, support window and stop authority. Decide and record the allowed cash/manual fallback and how it will be reconciled. Confirm the uptime-monitor choice, alert destination and acknowledgement owner; test the alert. Do not treat a proposed owner or an unconfigured monitor as ready.
- Inspect the current deployment and enforced policy/provider, organizer-verification, payment-mode and payout requirements. For the first paid pilot, we recommend bounded inventory, named checkpoints and a hold/repeat/limited-expansion decision after closeout. Optional Gate I/J records can capture those decisions; neither a Gate I approval/active run nor a Gate J decision is required by the application to sell. Resolve material operational failures before proceeding.

## Sequence after an operated pilot

1. **Fix observed failures first.** Review incidents, abandoned purchases, support work, entry queues and financial closeout. Rank by customer impact, frequency and recovery cost. Assign owners and acceptance evidence before adding new surfaces.
2. **Keep buyer access on mobile web/PWA.** Make checkout, email/order recovery and ticket presentation easy without a forced app download. Validate saved-ticket retrieval, account changes, weak connectivity and return visits on actual phones. A buyer native app stays deferred until repeat usage demonstrates a recurring need that web/PWA cannot meet well.
3. **Consider a focused staff app from measured door needs.** Prioritize fast scanning with clear audio/haptic confirmation, manual lookup, role and event boundaries, online freshness, offline queue visibility and recovery. Clearly separate saleable stock, tickets currently eligible for entry and confirmed check-ins; never label them all “available.” Show whether counts are live, cached or awaiting synchronization. Test recovery after permission changes, interruptions and network loss.
4. **Revalidate the next event.** A successful pilot does not approve new inventory, venues, regions or payment flows. Recheck current enforced controls, repeat relevant device and operational checks for the next event, and document what changed. Detailed E–J reviews remain optional.

Native packaging can improve camera access and staff feedback. It cannot prevent the same physical ticket being admitted at disconnected gates that cannot share state. Keep the existing offline lease, collision handling, staff procedure and reconciliation limits visible; use an online or coordinated gate plan when immediate duplicate prevention is required.

## Positioning hypotheses to test

Potential reasons for an organizer to choose HåfaPass are easy self-service with clear approval, understandable fees and finance/payout records, proven event-day recovery, and easy mobile ticket retrieval. These are hypotheses until a measured pilot and organizer feedback support them.

The planning discussion reports that GuamTime already markets local support, scanning, a dashboard and staff access, plus a claimed audience of 20,000. That audience claim is competitor marketing, not a verified HåfaPass measurement or a like-for-like reach comparison. Ticket Tailor and Eventbrite already offer apps. App availability and local support alone do not establish differentiation. Verify current competitor claims and terms before external comparisons; this document does not establish unique, better, cheaper, faster or more accessible performance.

Capture the following observations with their sample size, measurement window and collection method. Keep hypotheses separate from measured results, including failures and missing data:

| Observation | Evidence to collect | Decision it informs |
| --- | --- | --- |
| Buyer conversion | Checkout starts/completions and abandonment reasons, split by device and connection where consent permits | Buyer web/PWA friction to fix |
| Organizer setup | Time and help needed to create an event, understand fees and obtain approval | Whether self-service and approval are clear |
| Support burden | Contacts per event/order, reason, time to acknowledgement and resolution, repeat contacts | Support staffing and recovery priorities |
| Admission | Scan outcomes/latency, permission failures, manual lookups, queue length, offline conflicts and recovery | Staff app scope and gate procedures |
| Financial closeout | Time to reconcile, unexplained variance, holds, corrections and actual payout completion | Finance/payout usability and reliability |
| Repeat organizers | Repeat intent followed by actual subsequent events, with reasons for returning or leaving | Retention and whether differentiation is credible |

The first retrospective should produce a short ordered list of fixes and an explicit hold/repeat/limited-expansion decision, not a claim of market leadership. Add a buyer-native proposal only when repeat usage and a specific unmet task justify its build and ongoing support cost.
