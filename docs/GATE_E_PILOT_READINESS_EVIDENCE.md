# Gate E — Event-Specific Pilot Readiness Evidence

Status: application control implemented; a real organizer, venue, operating team, and signed readiness bundle are still required.

## Why this exists

An organizer verification or provider credential cannot prove that one specific event is safe to put on sale. Gate E binds the first pilot's event configuration to a signed operating plan, six named operational roles, twelve explicit controls, an effective window, and an independent administrator's decision.

This control prevents a checklist document from becoming detached from the event it approved. Production publication/resumption and checkout fail closed when no current approval matches the event.

## Required workflow

1. Select a bounded, low-risk organizer and event. Prefer general admission or a simple native seat layout.
2. Finish the normal publishing checklist: verified organizer and agreement, venue, Guam schedule, capacity, inventory, ticket windows, and approved payout readiness for paid sales.
3. Store the signed readiness sheet and privacy-safe supporting evidence in restricted storage. Do not place contracts, identity documents, bank details, phone numbers, payment data, or secrets in Git.
4. Record only the restricted evidence reference and the lowercase SHA-256 digest in Admin → Events → Prepare pilot readiness.
5. Name the primary and backup on-call owners, event commander, door lead, finance contact, and venue safety contact. Contact references must point to the restricted on-call directory.
6. Affirm every control only after the evidence supports it.
7. A different administrator reviews and approves the exact submission. The API prevents self-approval.
8. Revoke the approval immediately if venue, safety, staffing, payout, event, or evidence conditions cease to be valid.

## Required controls

- The organizer/event scope is intentionally low-risk and support demand is bounded.
- Organizer identity and the current organizer agreement are verified.
- The approved payout method is ready for this event.
- Event content and prohibited-event review are complete.
- Venue, schedule, capacity, and inventory reconcile.
- Prices, fees, and refund policy are approved.
- Assigned seats are physically reconciled, including accessible/companion groupings and obstructions, or assigned seating is explicitly not applicable.
- Support channels and the response SLA are staffed.
- Cash controls, staffing, and shift ownership are defined.
- Scanners, batteries, spare devices, and connectivity fallback are assigned.
- Emergency door-list access, custody, and disposal are restricted.
- No pilot scenario has an unresolved P0 or P1 issue.

## Immutable event-state binding

The application computes a canonical SHA-256 digest over material sale and operating configuration:

- event identity, content, venue, Guam schedule, capacity, fee policy, locale, attendee visibility, and transfer settings;
- organizer verification and exact agreement acceptance;
- organization status and connected-account readiness digests;
- the exact served policy-registry digest;
- ticket types, prices, limits, inventory, sales windows, door allocations, pricing tiers, add-ons, donations, registration questions, waivers, and promo configuration;
- assigned-seating layout version, renderer, seat-to-ticket mapping, operational status, labels, zones, and accessibility metadata.

Ordinary sales counters are deliberately excluded, so selling a ticket does not invalidate approval. Material configuration changes do invalidate approval without rewriting history. The event must receive a new evidence submission and independent approval before production sales continue.

## Append-only decisions and privacy boundary

Submissions, approvals, rejections, and revocations are new rows. Evidence fields are read-only, decision rows have database-enforced parent relationships, each submission can receive only one approval-or-rejection decision, and each approval can be revoked only once. Audit records include the decision, event, evidence/digest metadata, and assigned role names as keys; they exclude the assignment values so the audit stream does not copy private contact-directory data.

The full readiness record is available only through administrator endpoints. Public event and checkout payloads do not expose names or contact references.

## Production enforcement

- `Event#publish_checklist` requires a current event-specific approval in production for both publish and resume transitions.
- `POST /api/v1/orders` independently rechecks approval at checkout. A previously published event cannot continue accepting orders after expiry, revocation, or material configuration drift.
- Development/test environments expose the workflow without blocking ordinary local event fixtures. Production always fails closed; there is no credential or environment-variable bypass.

## Evidence that still must be produced outside the application

The software does not select the organizer, inspect a venue, verify a physical seat, name real people, provision devices, approve cash handling, or resolve P0/P1 findings. Gate E is complete only when the actual event has a signed evidence bundle, all owners have confirmed their assignments, the second administrator has approved the current digest, and there is no unresolved P0/P1 scenario.

Gate F device/browser/accessibility/load proof and Gate G physical event-day rehearsal remain separate release gates.
