# HafaPass Roles and Permissions

Status: supporting reference
Authoritative roadmap: [TICKETING_PLATFORM_BLUEPRINT.md](TICKETING_PLATFORM_BLUEPRINT.md)
Delivery phases: [PHASE_DELIVERY_PLAYBOOK.md](PHASE_DELIVERY_PLAYBOOK.md)

## Implemented organization roles

### Guest

- Can browse public events and begin guest checkout.
- Can recover an order through a scoped, expiring guest-access credential and request safe fulfillment resend.
- Ticket display and scan credentials are separate, versioned, revocable, and do not grant order-level access.

### Attendee

- Default authenticated Clerk user.
- Can view their own orders/tickets and create an organizer profile.
- Organizer, finance, box-office, scanner, support, and administration capabilities remain hidden and rejected unless database authorization grants them.

### Organizer organization

- Every organizer profile belongs to an organization with unique, lifecycle-managed memberships.
- Owner, manager, finance, marketer, box-office, and scanner permissions are enforced server-side.
- Scanner and box-office roles are limited to explicitly assigned events; assignments can expire or be revoked.
- Privileged verification, connected-account, settlement, payout, and platform fields are not organizer-controlled parameters.

### Platform administrator

- Controls platform-level settings and cross-event administration.
- Uses dedicated support, audit, reconciliation, connected-account, marketplace-governance, message-delivery, and operational readiness surfaces.
- Production use of those tools remains subject to the professional approvals and live drills in the completion audit.

## Target authorization model

Authorization is based on organization membership plus explicit event assignments. Clerk authenticates the person; the HafaPass database authorizes each action.

### Organization roles

| Role | Core permissions | Explicit exclusions |
|---|---|---|
| Owner | Organization, members, events, finance, payout settings | Cannot bypass platform risk/compliance controls |
| Manager | Events, inventory, staff, attendees, communications | Cannot cancel events (cancellation requires refund authority), move money, transfer ownership or change payout settings |
| Finance | Finance exports and reports, refunds, settlements and payouts; buyer contact details in refunds and finance exports | No event content or staff management by default |
| Marketer | Event content, campaigns, promoter links, audience segments | No buyer payment data, refunds, or payout settings |
| Box office | Door orders, guest list, attendee lookup, approved adjustments | No payout or organization administration |
| Scanner | Check-in for assigned events only | No buyer email, revenue, refunds, or event editing |

### Platform roles

| Role | Core permissions |
|---|---|
| Support | Order/ticket lookup, safe resend, operational notes; no financial configuration |
| Risk/operations | Organizer verification, event moderation, disputes, event-day override with audit |
| Finance admin | Reconciliation, settlements, payouts, adjustments, refund oversight |
| Platform admin | Platform configuration and role administration with strong audit requirements |

### Promoter/affiliate access

Promoters receive attribution and commission reporting scoped to their links/codes. They do not automatically receive the full buyer list, event-edit access, or refund authority.

### Venue access

Venue managers may see assigned venue events and coordinate venue staff. Venue access does not imply ownership of organizer finances unless the venue is also the contracted seller.

## Authorization invariants

- Client navigation is never the security boundary.
- Every protected API action resolves current user, membership/assignment, resource, and permitted command.
- Organizer-controlled input cannot set partner, featured, verification, payout, admin, or arbitrary lifecycle fields.
- Event staff assignments add access for that event only; they expire or can be revoked. Event-only managers cannot clone or generate recurring events.
- Expired memberships and assignments have no effective access, even when their stored status remains active.
- Scanner phones that are offline keep working until they reconnect or for up to 24 hours. Removing access stops them as soon as they reconnect. Device leases end sooner if membership, assignment or the event admission window ends.
- Organizer seating pauses are separate from platform restrictions. Organizers cannot lift or overwrite platform pauses.
- Managers see sales, but cannot cancel events or move money. Cancellation requires both event management and refund authority.
- Team invitations have per-person and per-organization hourly limits and a one-minute resend cooldown per recipient.
- Scanner responses expose only minimum admission data.
- Finance, refund, role, payout, check-in reversal, resend, and moderation actions create audit records.
- Support access does not imply unrestricted administrator access.
- There is no production first-user-admin shortcut.

The role schema and permission matrix are implemented and tested in Phases 3, 5, 6, and 7 of the delivery playbook.
