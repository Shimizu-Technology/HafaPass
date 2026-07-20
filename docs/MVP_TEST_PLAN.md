# HafaPass Pilot Manual Test Plan

Status: evolving pilot gate; not evidence that the current prototype is production-ready
Last baseline: July 20, 2026
Requirements: [TICKETING_PLATFORM_BLUEPRINT.md](TICKETING_PLATFORM_BLUEPRINT.md)
Phase process: [PHASE_DELIVERY_PLAYBOOK.md](PHASE_DELIVERY_PLAYBOOK.md)

This manual plan is run in full during Phase 7 after the required Phase 1–6 foundations merge. Earlier phases run the relevant sections as regression checks.

## 1. Preconditions

- The release commit passes `./scripts/gate.sh` and repository CI.
- There are no open P0 blueprint findings.
- Backend, frontend, Redis, and the background worker are running.
- The selected payment provider is in sandbox mode using HafaPass or approved compatible credentials; Stripe may be used only for sandbox regression until Guam production eligibility is confirmed in writing.
- Webhook forwarding uses a signed endpoint for every enabled provider.
- Email uses a sandbox/test recipient configuration.
- Browser authentication uses `TEST_USER_EMAIL`, `TEST_USER_PASSWORD`, and `TEST_BASE_URL` without exposing environment values.
- Test actors exist for attendee, organization owner, manager, finance, box office, scanner, support, risk/operations, finance admin, and platform admin.
- A future Guam event has multiple ticket types, low inventory, a promo, a guest list, staff assignments, and a waitlist configuration.
- A second organizer/event exists to test isolation.
- All test records are clearly labeled.

Historical baseline before Phase 1:

- Backend: 260 RSpec examples, zero failures.
- Frontend lint/build complete with three hook warnings and a bundle warning.
- No frontend automated tests.
- Eight production npm audit findings.

The expected counts will grow. A hard-coded example count is not the gate; passing the required suites and coverage is.

## 2. Public discovery and event truth

1. Browse on desktop and mobile while signed out.
2. Confirm the default marketplace shows upcoming relevant events, not old published inventory.
3. Test category deep links, date, location, price, search, and availability filters.
4. Paginate/load beyond the first 20 records.
5. Confirm URL state matches visible filters.
6. Open an event and verify title, organizer, venue, policy, age, accessibility, inventory, and ticket state.
7. Confirm a Guam 7:00 PM event displays as 7:00 PM ChST while the test browser uses a non-Guam timezone.
8. Confirm JSON-LD, canonical URL, social metadata, and sitemap use the configured production domain.
9. Confirm ended, cancelled, postponed, sold-out, not-yet-on-sale, and sales-ended events cannot be purchased and explain why.

## 3. Organizer verification and publishing

1. Create an organization and invite team members.
2. Confirm role invitations, acceptance, expiration, removal, and event assignment.
3. Verify paid publishing is blocked before required organizer/connected-account readiness.
4. Create an incomplete draft and confirm the publish checklist identifies every blocker.
5. Enter start/end/doors/sales windows in ChST and confirm stored/displayed values.
6. Add ticket types, tiers, capacity, promo, policy, and venue.
7. Preview and publish.
8. Confirm organizers cannot self-feature, self-partner, self-verify, or set arbitrary statuses through UI or API.
9. Clone and recur an event; verify pricing tiers and deliberately recalculated dates/windows.
10. Confirm another organization cannot access or mutate the event.
11. Archive rather than delete and confirm financial/history records remain.

## 4. Guest checkout and payment recovery

Run on desktop and mobile:

1. Select tickets and verify inventory hold/countdown.
2. Enter minimal buyer information.
3. Apply a valid promo and verify the all-in total.
4. Complete a standard successful card payment.
5. Refresh and revisit confirmation through the protected guest link.
6. Close the browser after provider payment but before redirect; recover the order.
7. Complete a 3DS success and a 3DS failure.
8. Use a declined card and verify inventory/promo release after failure/expiry.
9. Attempt to access the order with a changed/expired token.
10. Buy the final ticket concurrently from two sessions and verify only one succeeds.
11. Confirm confirmation and ticket fulfillment happen once despite duplicate webhooks.
12. Confirm a free ticket follows the approved fee policy and does not unnecessarily require card entry.

## 5. Authenticated buyer lifecycle

1. Sign in using Clerk test credentials.
2. Purchase tickets and find the order in My Tickets.
3. Resend fulfillment and confirm a delivery record is visible to authorized support.
4. Update allowed attendee details and verify audit history.
5. Transfer one ticket, accept as another buyer, and verify credential rotation.
6. Confirm the prior scan credential is invalid.
7. Add supported wallet passes and confirm event/time/details are correct.
8. Request ticket-level cancellation/refund according to policy.
9. Process a rescheduled event’s accept/refund options.
10. Confirm public ticket lookup never exposes buyer email or unnecessary PII.

## 6. Payment, refund, dispute, and ledger reconciliation

1. Complete successful, failed, cancelled, expired, and 3DS orders.
2. Replay identical webhook events.
3. Deliver success/failure events out of order.
4. Simulate provider amount/currency mismatch and confirm reconciliation alert.
5. Process multiple partial refunds against different order items.
6. Submit concurrent refund requests and confirm provider/local idempotency.
7. Process a full refund and confirm ticket/inventory policy.
8. Create a test dispute and verify ticket, reserve, notification, and admin state.
9. Edit the current ticket type and confirm historical order-item price/name do not change.
10. Reconcile gross, discounts, refunds, net, HafaPass fees, processing costs, organizer proceeds, reserves, adjustments, and payout to the cent.

## 7. Promo, capacity, and waitlist

1. Use unlimited and limited promos and verify finalized usage.
2. Expire/decline a promo checkout and verify reserved usage releases.
3. Exercise event capacity across multiple ticket types and comps.
4. Sell out and join the waitlist.
5. Issue an offer and verify inventory is held for that person only.
6. Purchase through the signed offer.
7. Expire, decline, cancel, and reuse an offer token; verify correct rejection/promotion.
8. Confirm organizer waitlist reporting includes position, offers, expiry, and conversion.

## 8. Refund, cancellation, and reschedule operations

1. Confirm finance/authorized roles can refund and unauthorized roles cannot.
2. Verify partial refund allocation and remaining valid tickets.
3. Cancel an event and exercise buyer notification/refund policy.
4. Reschedule an event and exercise buyer accept/refund policy.
5. Confirm all actions update settlement and payout state.
6. Confirm delivery messages are safe, logged, resendable, and do not duplicate unexpectedly.

## 9. Offline event-day simulation

Use at least three devices/browser profiles and at least 500 generated tickets:

1. Assign scanner staff and download the signed manifest.
2. Disconnect all scanners from the network.
3. Scan valid, invalid, refunded, transferred, and already-used tickets.
4. Scan the same valid ticket on multiple offline devices.
5. Use manual lookup and check-in reversal.
6. Record approved cash door sales without overselling.
7. Restore connectivity and sync all devices.
8. Confirm one accepted first admission, visible conflicts, complete append-only history, and correct counts.
9. Confirm expired/unassigned staff cannot continue scanning after authorization refresh.
10. Use the printable emergency list as a fallback drill.

Follow the step-by-step setup, three-device procedure, outage decisions, card-result rules, and closeout checklist in [Event-Day Operations](EVENT_DAY_OPERATIONS.md). Automated simulation does not replace this real-device pilot drill.

Performance targets:

- Online p95 scan response under 500 ms at representative load.
- Cached offline feedback feels immediate (target under 100 ms).
- Zero false valid admissions and zero oversold inventory.

## 10. Roles, privacy, and accessibility

1. Exercise every target role against every sensitive API/action.
2. Confirm scanner sees minimum admission data.
3. Confirm support cannot change payout/payment configuration.
4. Confirm organizer finance is isolated by organization.
5. Confirm all role, refund, payout, resend, moderation, and reversal actions are audited.
6. Navigate public, checkout, ticket, organizer, and scanner flows using keyboard only.
7. Check focus order, dialogs, errors, loading announcements, contrast, alt text, reduced motion, and zoom.
8. Run automated accessibility checks and manually verify critical screen-reader labels.

## 11. Messaging and support

1. Verify consolidated order/ticket delivery.
2. Force provider failure and job retry.
3. Exercise bounce/suppression handling.
4. Resend from the support dashboard and verify actor/time/status.
5. Insert HTML-like organizer/user input and verify safe rendering.
6. Exercise cancellation, reschedule, refund, waitlist, and reminder templates.
7. Verify any SMS/WhatsApp flow has recorded consent and opt-out behavior.

## 12. Production operations drill

1. Deploy a release candidate to a production-like environment.
2. Confirm web, worker, Redis, database, storage, email, every enabled payment/payout provider, and monitoring configuration status.
3. Trigger controlled application, job, webhook, and reconciliation failures; confirm alerts.
4. Restore the database and required objects from backup into an isolated environment.
5. Roll back a release using the documented procedure.
6. Execute provider-outage and venue-internet-outage runbooks.
7. Confirm logs, screenshots, and support tools do not disclose secrets or excess PII.

## 13. Pilot sign-off

- [ ] Full local gate and GitHub CI pass on release commit.
- [ ] All P0 blueprint requirements are proven.
- [ ] Production dependency audit has no unaccepted critical/high issues.
- [ ] Payment/ledger/refund/payout reconciliation has zero variance.
- [ ] Desktop/mobile public, buyer, organizer, staff, and admin flows pass.
- [ ] Guam time is correct on every surface.
- [ ] Three-device offline event simulation passes.
- [ ] Backup restore, rollback, and alert drills pass.
- [ ] Legal/accounting/payment/privacy policies are approved.
- [ ] Named event-day support owner and escalation channel exist.
- [ ] Small real test charge and refund succeed before pilot inventory opens.
