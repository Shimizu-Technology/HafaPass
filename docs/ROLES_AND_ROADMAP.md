# HafaPass Roles, Permissions, and Post-MVP Roadmap

This document captures the current role model and the permission model HafaPass should work toward after the initial MVP. It is intended to keep product, engineering, and QA aligned as the platform grows beyond a pilot.

## Current MVP Roles

### Public Guest

A public guest is any visitor without an authenticated Clerk session.

Can do:

- Browse published upcoming events.
- View published event detail pages.
- Buy tickets through guest checkout.
- Validate promo codes during checkout.
- View a completed ticket page when they have a valid QR URL.

Cannot do:

- Access organizer dashboards.
- Check in tickets.
- Cancel pending orders.
- Sync or create arbitrary users.
- View incomplete/pending ticket QR codes.

### Attendee

An attendee is the default authenticated user role.

Can do:

- Buy tickets while signed in.
- View their own orders and tickets.
- Cancel their own pending orders.
- Create an organizer profile, which promotes them into organizer capability.

Cannot do:

- Manage events without an organizer profile.
- Access another buyer's orders.
- Check in tickets unless they also own the relevant organizer profile.
- Access admin payment settings.

### Organizer

An organizer is a user with an organizer profile. The app currently relies more on organizer profile ownership than on the `organizer` role enum alone.

Can do:

- Create, edit, publish, and delete their own events.
- Manage ticket types for their own events.
- View event stats and attendee lists for their own events.
- Manage promo codes for their own events.
- Manage guest list entries and redeem comp tickets for their own events.
- Process refunds for orders on their own events.
- Check in tickets for events owned by their organizer profile.

Cannot do:

- Manage another organizer's events.
- Check in tickets for events they do not own.
- Access admin payment settings.

### Admin

An admin is a platform-level operator. In production, admins should be explicitly configured with `ADMIN_EMAILS`.

Can do:

- Access admin settings.
- Switch payment mode between simulate, Stripe test, and live.
- View Stripe key configuration status.
- Check in tickets for any event.
- Cancel pending orders.

Cannot do yet:

- Use a dedicated support dashboard.
- Impersonate users.
- Manage role assignments through an admin UI.
- View audit logs.

## Current Security Invariants

These should remain true as the codebase changes:

- Pending Stripe orders must not expose ticket QR codes.
- Ticket QR codes should only be issued for completed orders.
- Check-in requires authentication.
- Check-in requires the event owner organizer or an admin.
- Check-in rejects tickets whose order is not completed.
- Order cancellation requires the authenticated buyer or an admin.
- Public user sync must not trust caller-supplied Clerk IDs.
- Ticket purchase availability is checked under database row locks.
- Ticket sale windows are enforced by the backend.

## Recommended Post-MVP Roles

### Event Staff

Purpose: Let venues and promoters add temporary staff without giving full organizer control.

Can do:

- Check in tickets for assigned events.
- View limited attendee/check-in status for assigned events.
- Use manual QR entry when scanning fails.

Should not do:

- Edit event details.
- Change ticket pricing or inventory.
- Issue refunds.
- Access platform settings.

### Scanner

Purpose: A narrower role than event staff, ideal for door workers.

Can do:

- Check in tickets for assigned events only.
- See minimal ticket validation details: attendee name, ticket type, event title, status.

Should not do:

- See buyer email unless explicitly needed.
- View revenue, orders, refunds, or guest list management.
- Edit anything.

### Venue Manager

Purpose: Support venues that host events from multiple promoters.

Can do:

- View events at assigned venue.
- View attendance and door list for assigned venue events.
- Add scanner/event-staff users to assigned venue events.

Should not do:

- Edit another promoter's financial settings.
- Receive payouts unless configured as the merchant/organizer.

### Promoter

Purpose: Support Guam nightlife realities where promoters sell allocations or use promo codes.

Can do:

- View sales attributed to their promo/referral code.
- Potentially manage their own guest allocation.
- Potentially request comp approvals.

Should not do:

- Edit event master details.
- Issue refunds.
- Access full buyer list unless authorized.

### Support Admin

Purpose: Let HafaPass staff help customers without full platform control.

Can do:

- Look up orders, events, and tickets.
- Resend ticket emails.
- Help troubleshoot failed payments.
- View non-sensitive operational metadata.

Should not do:

- Switch live payment mode.
- Change fee settings.
- Issue refunds unless granted separately.

### Platform Admin

Purpose: Full HafaPass operator role.

Can do:

- Manage platform settings.
- Configure payment modes and fees.
- Manage admins/support users.
- View audit logs.
- Override organizer access in emergencies.

## Post-MVP Feature Roadmap

### Production Readiness

- Admin role assignment UI backed by audit logs.
- Explicit role membership table instead of only `users.role` plus organizer profile ownership.
- Staff invitations with expiration and event-level scoping.
- Audit log for check-ins, refunds, settings changes, role changes, and ticket re-sends.
- Monitoring and error tracking.
- Production `ADMIN_EMAILS`, Clerk production instance, Stripe webhook secret, Redis, and locked CORS origins.

### Ticketing Operations

- Offline scanner mode for unreliable venue WiFi.
- Door sales / box office mode.
- Manual cash/card door-sale recording.
- Ticket transfer or controlled resend flow.
- Pending order expiration to release abandoned inventory.
- Waitlist for sold-out events.
- Recurring events and event templates.

### Payments and Organizer Growth

- Stripe Connect onboarding for organizer payouts.
- Payout reporting and settlement status.
- Refund approval workflow.
- Platform fee reporting.
- Promoter code attribution and splits.

### Guam-Specific Differentiation

- Venue pages for Guam bars, clubs, restaurants, hotels, and community spaces.
- Weekend discovery page: "What's happening this weekend on Guam".
- WhatsApp/SMS-friendly ticket delivery and sharing.
- Sponsor placement for Ambros/partner events.
- Tourism-friendly event categories and hotel concierge flow.

### Marketing and Discovery

- Per-event SEO metadata.
- Open Graph share images.
- Featured events and curated collections.
- Social proof: attendee counts, friends going, or public RSVP count where appropriate.
- Organizer/venue follow system.

## MVP Definition of Done

Before calling the MVP ready for a real pilot event, HafaPass should pass the manual test plan in `docs/MVP_TEST_PLAN.md` using realistic event, organizer, attendee, and Stripe test data.
