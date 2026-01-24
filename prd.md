# HafaPass - Visual Testing PRD

## Overview

This PRD focuses on **complete visual verification and user flow testing** using `agent-browser`. 
The goal is to verify every page renders correctly, test all user flows end-to-end, and capture 
screenshots for documentation.

## Prerequisites

Before running these tests:
1. Rails API must be running on `localhost:3000`
2. Vite dev server must be running on `localhost:5173`
3. Seed data has been loaded (`rails db:seed`)

## Test Data Reference

From seed data:
- **Test User:** test-admin@hafameetings.com / HafaMeetings! (has organizer profile)
- **Published Events:** Full Moon Beach Party, Sunset Sessions, Tumon Bay Night Market, Chamorro Cultural Festival
- **Draft Event:** Corporate Networking Mixer (event ID 15)
- **Event with sales:** Full Moon Beach Party (event ID 11, slug: full-moon-beach-party)

## Tasks

```json
[
  {
    "id": 1,
    "title": "Test Homepage",
    "steps": [
      "Open http://localhost:5173/",
      "Take snapshot and verify: navbar with logo, Events link, Dashboard link, Sign In/Sign Up buttons",
      "Verify hero section with gradient background and tagline 'Your Island. Your Events. Your Pass.'",
      "Verify footer with copyright and 'Powered by Shimizu Technology'",
      "Take screenshot: screenshots/test-01-homepage.png"
    ],
    "passes": true
  },
  {
    "id": 2,
    "title": "Test Homepage Mobile View",
    "steps": [
      "Resize browser to 375x667 (iPhone SE)",
      "Open http://localhost:5173/",
      "Take snapshot and verify mobile layout renders correctly",
      "Verify hamburger menu or mobile nav is present",
      "Verify touch targets are appropriately sized (min 44px)",
      "Take screenshot: screenshots/test-02-homepage-mobile.png",
      "Resize browser back to 1280x800"
    ],
    "passes": true
  },
  {
    "id": 3,
    "title": "Test Events Listing Page",
    "steps": [
      "Open http://localhost:5173/events",
      "Take snapshot and verify page title 'Upcoming Events'",
      "Verify event cards display: title, date, venue, price range",
      "Verify at least 4 published events are shown",
      "Verify draft events are NOT shown",
      "Take screenshot: screenshots/test-03-events-listing.png"
    ],
    "passes": true
  },
  {
    "id": 4,
    "title": "Test Events Listing Mobile View",
    "steps": [
      "Resize browser to 375x667",
      "Open http://localhost:5173/events",
      "Take snapshot and verify cards stack vertically on mobile",
      "Verify event cards are readable and tappable",
      "Take screenshot: screenshots/test-04-events-mobile.png",
      "Resize browser back to 1280x800"
    ],
    "passes": true
  },
  {
    "id": 5,
    "title": "Test Event Detail Page",
    "steps": [
      "Open http://localhost:5173/events/full-moon-beach-party",
      "Take snapshot and verify: event title, description, venue info, date/time",
      "Verify ticket types section shows at least 3 ticket types with prices",
      "Verify 'Get Tickets' or ticket selection UI is present",
      "Verify age restriction badge if present",
      "Take screenshot: screenshots/test-05-event-detail.png"
    ],
    "passes": true
  },
  {
    "id": 6,
    "title": "Test Event Detail Mobile View",
    "steps": [
      "Resize browser to 375x667",
      "Open http://localhost:5173/events/full-moon-beach-party",
      "Take snapshot and verify mobile layout",
      "Verify ticket types are readable",
      "Verify checkout button is accessible",
      "Take screenshot: screenshots/test-06-event-mobile.png",
      "Resize browser back to 1280x800"
    ],
    "passes": true
  },
  {
    "id": 7,
    "title": "Test Ticket Selection Flow",
    "steps": [
      "Open http://localhost:5173/events/full-moon-beach-party",
      "Take snapshot to find ticket quantity selectors",
      "Select 2 of the first ticket type (use +/- buttons or input)",
      "Select 1 of the second ticket type",
      "Verify subtotal updates dynamically",
      "Verify service fee is calculated and shown (3% + $0.50/ticket)",
      "Take screenshot: screenshots/test-07-ticket-selection.png"
    ],
    "passes": true
  },
  {
    "id": 8,
    "title": "Test Checkout Page",
    "steps": [
      "From event detail with tickets selected, click checkout/proceed button",
      "OR navigate to http://localhost:5173/checkout/full-moon-beach-party",
      "Take snapshot and verify checkout form: email, name, phone fields",
      "Verify order summary with ticket types, quantities, subtotal, fees, total",
      "Take screenshot: screenshots/test-08-checkout.png"
    ],
    "passes": true
  },
  {
    "id": 9,
    "title": "Test Checkout Mobile View",
    "steps": [
      "Resize browser to 375x667",
      "Navigate to http://localhost:5173/checkout/full-moon-beach-party",
      "Take snapshot and verify form is usable on mobile",
      "Verify order summary is visible",
      "Take screenshot: screenshots/test-09-checkout-mobile.png",
      "Resize browser back to 1280x800"
    ],
    "passes": true
  },
  {
    "id": 10,
    "title": "Test Checkout Form Validation",
    "steps": [
      "Open http://localhost:5173/checkout/full-moon-beach-party",
      "Click submit without filling any fields",
      "Verify validation errors appear for required fields",
      "Take screenshot: screenshots/test-10-checkout-validation.png"
    ],
    "passes": true
  },
  {
    "id": 11,
    "title": "Test Checkout Form Submission",
    "steps": [
      "Open http://localhost:5173/checkout/full-moon-beach-party",
      "Fill email: testbuyer@example.com",
      "Fill name: Test Buyer",
      "Fill phone: 671-555-1234",
      "Select at least 1 ticket if ticket selection is on this page",
      "Click submit/purchase button",
      "Wait for redirect to confirmation page",
      "Take screenshot: screenshots/test-11-checkout-submit.png"
    ],
    "passes": true
  },
  {
    "id": 12,
    "title": "Test Order Confirmation Page",
    "steps": [
      "After checkout, verify you're on /confirmation/:orderId page",
      "Take snapshot and verify: success message, order details, ticket list",
      "Verify each ticket shows QR code or link to view ticket",
      "Verify order total matches what was shown at checkout",
      "Take screenshot: screenshots/test-12-confirmation.png"
    ],
    "passes": true
  },
  {
    "id": 13,
    "title": "Test Single Ticket View",
    "steps": [
      "From confirmation page, click on a ticket to view it",
      "OR query API for a ticket QR code: rails runner 'puts Ticket.issued.first.qr_code'",
      "Navigate to /tickets/:qrCode",
      "Take snapshot and verify: ticket displays event name, ticket type, QR code image",
      "Verify attendee info is shown",
      "Take screenshot: screenshots/test-13-ticket-view.png"
    ],
    "passes": true
  },
  {
    "id": 14,
    "title": "Test Ticket View Mobile",
    "steps": [
      "Resize browser to 375x667",
      "Navigate to a ticket page (use QR code from previous test)",
      "Take snapshot and verify QR code is large and scannable",
      "Verify all info is readable",
      "Take screenshot: screenshots/test-14-ticket-mobile.png",
      "Resize browser back to 1280x800"
    ],
    "passes": true
  },
  {
    "id": 15,
    "title": "Test Sign In Page",
    "steps": [
      "Open http://localhost:5173/sign-in",
      "Take snapshot and verify Clerk sign-in component renders",
      "Verify form has email/password fields or social login options",
      "Take screenshot: screenshots/test-15-sign-in.png"
    ],
    "passes": true
  },
  {
    "id": 16,
    "title": "Test Sign Up Page",
    "steps": [
      "Open http://localhost:5173/sign-up",
      "Take snapshot and verify Clerk sign-up component renders",
      "Verify form has registration fields",
      "Take screenshot: screenshots/test-16-sign-up.png"
    ],
    "passes": true
  },
  {
    "id": 17,
    "title": "Test Authentication Flow",
    "steps": [
      "Open http://localhost:5173/sign-in",
      "Enter email: test-admin@hafameetings.com",
      "Enter password: HafaMeetings!",
      "Click sign in button",
      "Wait for authentication to complete",
      "Verify navbar now shows user info instead of Sign In/Sign Up",
      "Take screenshot: screenshots/test-17-authenticated.png"
    ],
    "passes": true
  },
  {
    "id": 18,
    "title": "Test My Tickets Page",
    "steps": [
      "While authenticated, navigate to http://localhost:5173/my-tickets",
      "Take snapshot and verify page loads",
      "If tickets exist, verify they display event name, date, status",
      "If no tickets, verify empty state message",
      "Take screenshot: screenshots/test-18-my-tickets.png"
    ],
    "passes": true
  },
  {
    "id": 19,
    "title": "Test My Tickets Mobile View",
    "steps": [
      "Resize browser to 375x667",
      "Navigate to http://localhost:5173/my-tickets",
      "Take snapshot and verify mobile layout",
      "Take screenshot: screenshots/test-19-my-tickets-mobile.png",
      "Resize browser back to 1280x800"
    ],
    "passes": true
  },
  {
    "id": 20,
    "title": "Test Organizer Dashboard",
    "steps": [
      "While authenticated as organizer, navigate to http://localhost:5173/dashboard",
      "Take snapshot and verify: welcome message with business name",
      "Verify event list with at least 5 events (including drafts)",
      "Verify event cards show title, date, status badge, tickets sold",
      "Verify 'Create Event' and 'Scan Tickets' buttons",
      "Take screenshot: screenshots/test-20-dashboard.png"
    ],
    "passes": true
  },
  {
    "id": 21,
    "title": "Test Dashboard Mobile View",
    "steps": [
      "Resize browser to 375x667",
      "Navigate to http://localhost:5173/dashboard",
      "Take snapshot and verify mobile layout",
      "Verify event cards stack and are tappable",
      "Take screenshot: screenshots/test-21-dashboard-mobile.png",
      "Resize browser back to 1280x800"
    ],
    "passes": true
  },
  {
    "id": 22,
    "title": "Test Create Event Page",
    "steps": [
      "While authenticated, navigate to http://localhost:5173/dashboard/events/new",
      "Take snapshot and verify form sections: Basic Info, Venue, Date/Time, Settings",
      "Verify required fields: title, venue_name, starts_at",
      "Verify category dropdown has options",
      "Verify age restriction dropdown has options",
      "Take screenshot: screenshots/test-22-create-event.png"
    ],
    "passes": true
  },
  {
    "id": 23,
    "title": "Test Create Event Form Validation",
    "steps": [
      "On create event page, click submit without filling required fields",
      "Verify validation errors appear",
      "Take screenshot: screenshots/test-23-create-event-validation.png"
    ],
    "passes": true
  },
  {
    "id": 24,
    "title": "Test Create Event Submission",
    "steps": [
      "Fill in create event form:",
      "  - Title: Test Event from Ralph",
      "  - Venue: Test Venue",
      "  - Starts At: (future date)",
      "  - Category: nightlife",
      "Submit the form",
      "Verify redirect to edit page for the new event",
      "Take screenshot: screenshots/test-24-create-event-success.png"
    ],
    "passes": true
  },
  {
    "id": 25,
    "title": "Test Edit Event Page (Published)",
    "steps": [
      "Navigate to http://localhost:5173/dashboard/events/11/edit (Full Moon Beach Party)",
      "Take snapshot and verify form is pre-filled with event data",
      "Verify status badge shows 'Published' (green)",
      "Verify 'View Analytics' link is present",
      "Take screenshot: screenshots/test-25-edit-event-published.png"
    ],
    "passes": true
  },
  {
    "id": 26,
    "title": "Test Edit Event Page (Draft) and Publish Flow",
    "steps": [
      "Navigate to http://localhost:5173/dashboard/events/15/edit (Corporate Networking Mixer - draft)",
      "Take snapshot and verify status badge shows 'Draft' (yellow)",
      "Verify 'Publish Event' button is present",
      "Click 'Publish Event' button",
      "Confirm in the dialog if one appears",
      "Verify status changes to 'Published' (green)",
      "Take screenshot: screenshots/test-26-publish-event.png"
    ],
    "passes": true
  },
  {
    "id": 27,
    "title": "Test Ticket Types Section",
    "steps": [
      "Navigate to http://localhost:5173/dashboard/events/11/edit",
      "Scroll to Ticket Types section",
      "Take snapshot and verify ticket types are listed with name, price, sold/available",
      "Verify at least 3 ticket types are shown",
      "Verify 'Add Ticket Type' form is present",
      "Take screenshot: screenshots/test-27-ticket-types.png"
    ],
    "passes": true
  },
  {
    "id": 28,
    "title": "Test Add New Ticket Type",
    "steps": [
      "On edit event page ticket types section",
      "Find the 'Add Ticket Type' form",
      "Fill: Name: 'VIP Test', Price: 100, Quantity: 50",
      "Click Add button",
      "Verify new ticket type appears in the list",
      "Take screenshot: screenshots/test-28-add-ticket-type.png"
    ],
    "passes": true
  },
  {
    "id": 29,
    "title": "Test Edit Ticket Type",
    "steps": [
      "On ticket types section, click Edit on the VIP Test ticket (or another one)",
      "Verify inline edit form appears",
      "Change the price or quantity",
      "Click Save",
      "Verify changes are reflected",
      "Take screenshot: screenshots/test-29-edit-ticket-type.png"
    ],
    "passes": true
  },
  {
    "id": 30,
    "title": "Test Event Analytics Page",
    "steps": [
      "Navigate to http://localhost:5173/dashboard/events/11/analytics",
      "Take snapshot and verify summary cards: Tickets Sold, Total Revenue, Check-in Rate",
      "Verify Tickets by Type table with columns: type, sold, available, revenue",
      "Verify Recent Orders table",
      "Take screenshot: screenshots/test-30-analytics.png"
    ],
    "passes": true
  },
  {
    "id": 31,
    "title": "Test Analytics Attendees Section",
    "steps": [
      "On analytics page, find 'View All' or 'Attendees' button",
      "Click to expand/load attendees list",
      "Verify attendees are shown with name, email, ticket type, status",
      "Take screenshot: screenshots/test-31-analytics-attendees.png"
    ],
    "passes": true
  },
  {
    "id": 32,
    "title": "Test Analytics Mobile View",
    "steps": [
      "Resize browser to 375x667",
      "Navigate to http://localhost:5173/dashboard/events/11/analytics",
      "Take snapshot and verify summary cards stack vertically",
      "Verify tables are scrollable horizontally",
      "Take screenshot: screenshots/test-32-analytics-mobile.png",
      "Resize browser back to 1280x800"
    ],
    "passes": true
  },
  {
    "id": 33,
    "title": "Test QR Scanner Page",
    "steps": [
      "Navigate to http://localhost:5173/dashboard/scanner",
      "Take snapshot and verify: camera section placeholder, manual input field",
      "Verify 'Start Camera' or camera permission UI",
      "Verify session counter display (0 tickets checked in)",
      "Take screenshot: screenshots/test-33-scanner.png"
    ],
    "passes": true
  },
  {
    "id": 34,
    "title": "Test Scanner Manual Check-In Success",
    "steps": [
      "Get a valid ticket QR code: cd hafapass_api && rails runner 'puts Ticket.issued.first.qr_code'",
      "On scanner page, enter the QR code in manual input field",
      "Click Check In button",
      "Verify success message appears with green styling and attendee name",
      "Verify session counter increases to 1",
      "Take screenshot: screenshots/test-34-scanner-success.png"
    ],
    "passes": true
  },
  {
    "id": 35,
    "title": "Test Scanner Already Checked In",
    "steps": [
      "On scanner page, enter the same QR code again",
      "Click Check In button",
      "Verify warning message appears (yellow) indicating already checked in",
      "Verify check-in timestamp is shown",
      "Take screenshot: screenshots/test-35-scanner-already.png"
    ],
    "passes": true
  },
  {
    "id": 36,
    "title": "Test Scanner Invalid QR Code",
    "steps": [
      "On scanner page, enter invalid QR code: invalid-code-12345",
      "Click Check In button",
      "Verify error message appears (red) - ticket not found",
      "Take screenshot: screenshots/test-36-scanner-error.png"
    ],
    "passes": true
  },
  {
    "id": 37,
    "title": "Test Scanner Mobile View",
    "steps": [
      "Resize browser to 375x667",
      "Navigate to http://localhost:5173/dashboard/scanner",
      "Take snapshot and verify mobile layout",
      "Verify camera section is appropriately sized",
      "Verify manual input is accessible",
      "Take screenshot: screenshots/test-37-scanner-mobile.png",
      "Resize browser back to 1280x800"
    ],
    "passes": true
  },
  {
    "id": 38,
    "title": "Test 404 Page",
    "steps": [
      "Navigate to http://localhost:5173/nonexistent-page-xyz",
      "Take snapshot and verify 404 or 'page not found' message",
      "Verify navigation back to home is possible",
      "Take screenshot: screenshots/test-38-404.png"
    ],
    "passes": true
  },
  {
    "id": 39,
    "title": "Test Event Not Found",
    "steps": [
      "Navigate to http://localhost:5173/events/nonexistent-event-slug",
      "Take snapshot and verify error state (event not found)",
      "Verify user can navigate back",
      "Take screenshot: screenshots/test-39-event-not-found.png"
    ],
    "passes": true
  },
  {
    "id": 40,
    "title": "Test Protected Route Redirect",
    "steps": [
      "Sign out if currently signed in (click user menu > sign out)",
      "Navigate to http://localhost:5173/dashboard",
      "Verify redirect to sign-in page or auth prompt",
      "Take screenshot: screenshots/test-40-protected-redirect.png"
    ],
    "passes": true
  },
  {
    "id": 41,
    "title": "Test SEO Meta Tags",
    "steps": [
      "Use curl to fetch http://localhost:5173/ and inspect HTML",
      "Verify <title> contains 'HafaPass - Guam Event Tickets'",
      "Verify meta description is present",
      "Verify Open Graph tags: og:title, og:description, og:image",
      "Verify Twitter card tags",
      "Log findings to activity.md"
    ],
    "passes": true
  },
  {
    "id": 42,
    "title": "Test PWA Manifest",
    "steps": [
      "Fetch http://localhost:5173/manifest.json",
      "Verify manifest contains: name, short_name, icons, start_url, display",
      "Verify icon files exist (icon-192.png, icon-512.png)",
      "Log PWA compliance status to activity.md"
    ],
    "passes": true
  },
  {
    "id": 43,
    "title": "Test robots.txt",
    "steps": [
      "Fetch http://localhost:5173/robots.txt",
      "Verify it contains Allow and Disallow rules",
      "Verify /dashboard and /api are disallowed",
      "Log findings to activity.md"
    ],
    "passes": true
  },
  {
    "id": 44,
    "title": "Test Loading States",
    "steps": [
      "Open http://localhost:5173/events with network throttling if possible",
      "OR observe the brief loading state when page first loads",
      "Verify loading spinner or skeleton appears before data",
      "Take screenshot if loading state is visible: screenshots/test-44-loading.png",
      "Note: Loading states may be too fast to capture - document observation"
    ],
    "passes": true
  },
  {
    "id": 45,
    "title": "Final Test Summary",
    "steps": [
      "List all screenshots taken in screenshots/ directory",
      "Count total screenshots captured (should be 40+)",
      "Log summary of any issues found during testing",
      "Document any failed tests and reasons",
      "Update activity.md with comprehensive test results",
      "Verify public pages work without authentication",
      "Verify protected pages require authentication"
    ],
    "passes": true
  }
]
```

## Success Criteria

- All 45 tasks have `"passes": true`
- 40+ screenshots captured in `screenshots/` directory
- Any UI bugs found are documented in activity.md
- All major user flows verified working end-to-end
- Mobile views verified for all key pages
- SEO/PWA compliance verified

## Notes

- If Clerk authentication is not configured, skip auth-dependent tasks and note in activity.md
- For camera-based scanner tests, verify the UI renders even if camera access is denied
- Take additional screenshots if interesting states are discovered
- Document any CSS/layout issues found during testing
- If a test fails, document the issue but continue with remaining tests
