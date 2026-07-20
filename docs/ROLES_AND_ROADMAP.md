# HafaPass Roles and Permissions

Status: supporting reference
Authoritative roadmap: [TICKETING_PLATFORM_BLUEPRINT.md](TICKETING_PLATFORM_BLUEPRINT.md)
Delivery phases: [PHASE_DELIVERY_PLAYBOOK.md](PHASE_DELIVERY_PLAYBOOK.md)

## Implemented organization roles

### Guest

- Can browse public events and begin guest checkout.
- Cannot reliably recover or cancel a pending paid order in the current implementation.
- A QR-bearing ticket URL currently carries too much access and must not be treated as a safe public credential.

### Attendee

- Default authenticated Clerk user.
- Can view their own orders/tickets and create an organizer profile.
- The current navigation exposes organizer/scanner destinations too broadly even though backend authorization rejects many operations.

### Organizer organization

- Every organizer profile belongs to an organization with unique, lifecycle-managed memberships.
- Owner, manager, finance, marketer, box-office, and scanner permissions are enforced server-side.
- Scanner and box-office roles are limited to explicitly assigned events; assignments can expire or be revoked.
- Privileged verification, connected-account, settlement, payout, and platform fields are not organizer-controlled parameters.

### Platform administrator

- Controls platform-level settings and cross-event administration.
- The prototype lacks the complete support, audit, reconciliation, risk, and message-delivery tools required for production.

## Target authorization model

Authorization is based on organization membership plus explicit event assignments. Clerk authenticates the person; the HafaPass database authorizes each action.

### Organization roles

| Role | Core permissions | Explicit exclusions |
|---|---|---|
| Owner | Organization, members, events, finance, payout settings | Cannot bypass platform risk/compliance controls |
| Manager | Events, inventory, staff, attendees, communications | No ownership transfer or payout-bank changes |
| Finance | Orders, refunds subject to policy, settlements, payouts | No event content or staff management by default |
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
- Staff assignments expire and are scoped to events.
- Scanner responses expose only minimum admission data.
- Finance, refund, role, payout, check-in reversal, resend, and moderation actions create audit records.
- Support access does not imply unrestricted administrator access.
- There is no production first-user-admin shortcut.

The role schema and permission matrix are implemented and tested in Phases 3, 5, 6, and 7 of the delivery playbook.
