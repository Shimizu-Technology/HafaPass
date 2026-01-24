# HafaPass - Product Requirements Document

## Overview

HafaPass is a ticketing platform for Guam's hospitality industry, powered by Ambros Inc.'s island-wide venue network. The MVP enables event organizers to create events, sell tickets, and check in attendees via QR code scanning. Distribution through Ambros's existing B2B relationships with every bar, club, restaurant, and hotel on Guam provides a go-to-market advantage over generic ticketing platforms.

## Target Audience

- **Primary:** Venue owners, event promoters, nightlife organizers on Guam
- **Secondary:** Attendees (military personnel, tourists, locals) purchasing tickets

### Key Pain Points
- **Venues:** No easy way to sell tickets; current options (GuamTime) take 10-15%+ of profits
- **Attendees:** Fragmented event discovery, clunky mobile checkout
- **Ambros:** Venues hosting more events = more beverage sales; needs ticketing for sponsored events

## Core Features (MVP)

1. **User Authentication** - Sign up, sign in, sign out via Clerk
2. **Organizer Profile** - Create and manage organizer/venue profile
3. **Event Management** - Create, edit, publish events with cover images
4. **Ticket Types** - Multiple ticket types per event with pricing and inventory
5. **Public Event Discovery** - Browse and view published events
6. **Checkout Flow** - Purchase tickets with service fee calculation (Stripe scaffolded)
7. **Digital Tickets** - QR code generation and mobile-friendly display
8. **Scanner** - Check in attendees via QR code scanning
9. **Dashboard** - View sales, revenue, and attendee data

## Tech Stack

- **Backend:** Ruby on Rails API (API-only mode)
- **Frontend:** React.js with Vite
- **Authentication:** Clerk (frontend components + backend JWT verification)
- **Database:** PostgreSQL (Neon for production, local for dev)
- **Payments:** Stripe (scaffolded, ready for API keys)
- **File Storage:** AWS S3 (scaffolded, ready for API keys)
- **Email:** Resend (scaffolded, ready for API keys)
- **Styling:** Tailwind CSS
- **Testing:** RSpec (backend)

## Architecture

- Rails API on `localhost:3000` — API-only, JSON responses, versioned under `/api/v1/`
- React Vite app on `localhost:5173` — Mobile-first SPA
- Clerk handles authentication on frontend; JWT verification on backend
- RESTful API design with proper HTTP status codes

## Data Model

### Users (synced from Clerk)
- clerk_id, email, first_name, last_name, phone, role (attendee/organizer/admin)

### OrganizerProfiles
- user_id, business_name, business_description, logo_url, stripe_account_id, is_ambros_partner

### Events
- organizer_profile_id, title, slug (unique), description, short_description
- venue_name, venue_address, venue_city
- starts_at, ends_at, doors_open_at, timezone (default: Pacific/Guam)
- status (draft/published/cancelled/completed)
- category (nightlife/concert/festival/dining/sports/other)
- age_restriction (all_ages/eighteen_plus/twenty_one_plus)
- max_capacity, cover_image_url, is_featured

### TicketTypes
- event_id, name, description, price_cents, quantity_available, quantity_sold
- max_per_order, sales_start_at, sales_end_at, sort_order

### Orders
- user_id (optional, guest checkout allowed), event_id
- status (pending/completed/refunded/cancelled)
- subtotal_cents, service_fee_cents, total_cents
- buyer_email, buyer_name, buyer_phone
- stripe_payment_intent_id (nullable for MVP mock)

### Tickets
- order_id, ticket_type_id, event_id
- qr_code (unique UUID), status (issued/checked_in/cancelled/transferred)
- attendee_name, attendee_email, checked_in_at

## UI/UX Requirements

- **Design:** Clean, modern, mobile-first
- **Colors:** Ocean blues, sandy neutrals, coral/sunset accents
- **Typography:** Modern sans-serif
- **Responsive:** All pages must work at 375px mobile viewport
- **Touch targets:** Minimum 44x44px on mobile
- **Loading states:** Skeleton/spinner on all data-fetching pages
- **Error states:** User-friendly error messages on API failures

## Security Considerations

- Clerk handles all authentication (no custom password storage)
- Backend verifies Clerk JWTs on all protected endpoints
- Role-based access: organizer endpoints require organizer profile
- CORS configured for frontend origin only
- Input validation on all API endpoints
- QR codes use SecureRandom.uuid (not guessable)

## Third-Party Integrations (Scaffolded)

- **Stripe:** Payment intent creation, checkout flow (mock for MVP)
- **AWS S3:** Event cover image uploads (URL input for MVP)
- **Resend:** Order confirmation emails (placeholder for MVP)

## Pricing Model

| Fee Type | Amount | Paid By |
|----------|--------|---------|
| Service Fee | 3% + $0.50 per ticket | Buyer (added to price) |
| Payment Processing | ~2.9% + $0.30 (Stripe) | Organizer (deducted from payout) |
| Free Events | $0 | No fees |

## Success Criteria

- Can create an account and organizer profile
- Can create and publish an event with multiple ticket types
- Can browse and view published events as a public user
- Can purchase tickets through mock checkout with correct fee calculation
- Can view purchased tickets with QR codes on mobile
- Can scan and check in tickets with success/error feedback
- Can view sales dashboard with revenue and attendee data
- All API endpoints have passing RSpec tests
- All pages handle loading and error states gracefully

---

## Task List

```json
[
  {
    "id": 1,
    "category": "setup",
    "description": "Initialize Rails API project",
    "steps": [
      "Create new Rails API-only application: rails new hafapass_api --api --database=postgresql",
      "Add gems to Gemfile: rack-cors, dotenv-rails, jwt, rspec-rails, factory_bot_rails",
      "Run bundle install",
      "Configure CORS in config/initializers/cors.rb to allow localhost:5173",
      "Create .env.example with placeholder keys (CLERK_SECRET_KEY, CLERK_PUBLISHABLE_KEY, DATABASE_URL)",
      "Create database with rails db:create",
      "Install RSpec: rails generate rspec:install",
      "Verify rails server starts on port 3000 and returns 200 on a health check endpoint"
    ],
    "passes": true
  },
  {
    "id": 2,
    "category": "setup",
    "description": "Initialize React Vite frontend project",
    "steps": [
      "Create new Vite React project: npm create vite@latest hafapass_frontend -- --template react",
      "cd into hafapass_frontend and run npm install",
      "Install Tailwind CSS v3, postcss, autoprefixer and configure (tailwind.config.js, postcss.config.js, add directives to index.css)",
      "Install react-router-dom for routing",
      "Install axios for API calls",
      "Create src/api/client.js with axios instance pointing to VITE_API_URL (default http://localhost:3000/api/v1)",
      "Create .env.local.example with VITE_CLERK_PUBLISHABLE_KEY and VITE_API_URL",
      "Create public/_redirects file for Netlify SPA routing: '/*    /index.html   200' (prevents 404 on page refresh in production)",
      "Verify dev server starts on port 5173 and displays the default page"
    ],
    "passes": true
  },
  {
    "id": 3,
    "category": "setup",
    "description": "Configure Clerk authentication on frontend",
    "steps": [
      "Install @clerk/clerk-react",
      "Create conditional ClerkProvider wrapper: if VITE_CLERK_PUBLISHABLE_KEY is set, wrap in ClerkProvider; otherwise render children directly (allows app to run without Clerk configured)",
      "Wrap App with the conditional ClerkProvider in main.jsx",
      "Create src/pages/SignInPage.jsx using Clerk's SignIn component",
      "Create src/pages/SignUpPage.jsx using Clerk's SignUp component",
      "Create src/components/ProtectedRoute.jsx that redirects unauthenticated users to /sign-in (bypass if Clerk not configured)",
      "Set up React Router with routes for /, /sign-in, /sign-up",
      "Update src/api/client.js to attach Clerk session token as Bearer header on all requests (using useAuth().getToken())",
      "Verify sign-in page renders at /sign-in"
    ],
    "passes": true
  },
  {
    "id": 4,
    "category": "setup",
    "description": "Configure Clerk JWT verification on Rails backend",
    "steps": [
      "Create app/services/clerk_authenticator.rb that fetches Clerk JWKS from https://api.clerk.com/.well-known/jwks.json and verifies JWT tokens",
      "Cache JWKS keys for 1 hour to avoid fetching on every request (use Rails.cache or class-level memoization with TTL)",
      "Add authenticate_user! before_action to ApplicationController that extracts Bearer token from Authorization header and verifies it",
      "Add current_user method that finds or creates User by clerk_id (sub claim) from JWT — first user created becomes admin role automatically",
      "Add skip_before_action :authenticate_user! support for public endpoints",
      "Create a simple GET /api/v1/me endpoint that returns current user info (for testing auth)",
      "Verify unauthenticated requests get 401 and authenticated requests get 200"
    ],
    "passes": true
  },
  {
    "id": 5,
    "category": "feature",
    "description": "Create User model and sync endpoint",
    "steps": [
      "Generate User model: clerk_id:string email:string first_name:string last_name:string phone:string role:integer",
      "Add database index on clerk_id (unique)",
      "Add enum for role: { attendee: 0, organizer: 1, admin: 2 }",
      "Run migration",
      "Create POST /api/v1/users/sync endpoint that creates or updates a user from Clerk webhook data",
      "Add route to config/routes.rb under api/v1 namespace",
      "Test endpoint responds correctly with curl"
    ],
    "passes": true
  },
  {
    "id": 6,
    "category": "feature",
    "description": "Create OrganizerProfile model and API",
    "steps": [
      "Generate OrganizerProfile model: user_id:references business_name:string business_description:text logo_url:string stripe_account_id:string is_ambros_partner:boolean",
      "Add has_one :organizer_profile to User, belongs_to :user to OrganizerProfile",
      "Add validates :business_name, presence: true",
      "Run migration",
      "Create organizer_profiles_controller with show and create_or_update actions (authenticated)",
      "Routes: GET /api/v1/organizer_profile, POST /api/v1/organizer_profile, PUT /api/v1/organizer_profile",
      "Test endpoints with curl using a valid JWT"
    ],
    "passes": true
  },
  {
    "id": 7,
    "category": "feature",
    "description": "Create Event model and API",
    "steps": [
      "Generate Event model with fields: organizer_profile_id:references title:string slug:string description:text short_description:string cover_image_url:string venue_name:string venue_address:string venue_city:string starts_at:datetime ends_at:datetime doors_open_at:datetime timezone:string status:integer category:integer age_restriction:integer max_capacity:integer is_featured:boolean published_at:datetime",
      "Add unique index on slug",
      "Add enums for status, category, age_restriction",
      "Add before_save callback to generate_slug from title (append random suffix if slug already exists)",
      "Add scopes: published, upcoming, past, featured",
      "Run migration",
      "Add has_many :events to OrganizerProfile",
      "Create events_controller with index (public, published only) and show (by slug) actions",
      "Create organizer/events_controller with index, show, create, update, destroy actions (authenticated, scoped to current organizer)",
      "Add publish action that sets status to published and published_at",
      "Add routes: GET /api/v1/events, GET /api/v1/events/:slug (public); full CRUD under /api/v1/organizer/events (protected)",
      "Test endpoints with curl"
    ],
    "passes": true
  },
  {
    "id": 8,
    "category": "feature",
    "description": "Create TicketType model and API",
    "steps": [
      "Generate TicketType model: event_id:references name:string description:text price_cents:integer quantity_available:integer quantity_sold:integer max_per_order:integer sales_start_at:datetime sales_end_at:datetime sort_order:integer",
      "Set default quantity_sold to 0",
      "Add belongs_to :event, has_many :ticket_types to Event",
      "Add validates :name, :price_cents, :quantity_available presence and numericality",
      "Add sold_out? and available_quantity methods",
      "Run migration",
      "Create organizer/ticket_types_controller nested under events with CRUD actions",
      "Routes: /api/v1/organizer/events/:event_id/ticket_types",
      "Include ticket_types in public event show response",
      "Test endpoints with curl"
    ],
    "passes": true
  },
  {
    "id": 9,
    "category": "feature",
    "description": "Create Order and Ticket models",
    "steps": [
      "Generate Order model: user_id:references event_id:references status:integer subtotal_cents:integer service_fee_cents:integer total_cents:integer buyer_email:string buyer_name:string buyer_phone:string stripe_payment_intent_id:string completed_at:datetime",
      "Generate Ticket model: order_id:references ticket_type_id:references event_id:references qr_code:string status:integer attendee_name:string attendee_email:string checked_in_at:datetime",
      "Add unique index on tickets.qr_code",
      "Add enums: Order status (pending:0, completed:1, refunded:2, cancelled:3), Ticket status (issued:0, checked_in:1, cancelled:2, transferred:3)",
      "Add all associations between models (Order has_many tickets, belongs_to event, etc.)",
      "Add generate_qr_code! method to Ticket using SecureRandom.uuid",
      "Add check_in! method to Ticket that validates status is issued before updating",
      "Add before_create :set_attendee_info callback on Ticket (copies from order)",
      "Run migrations",
      "Verify models can be created in rails console"
    ],
    "passes": true
  },
  {
    "id": 10,
    "category": "feature",
    "description": "Create Orders API with mock checkout",
    "steps": [
      "Create orders_controller with create action",
      "Accept params: event_id, buyer_email, buyer_name, buyer_phone, line_items (array of {ticket_type_id, quantity})",
      "Validate: ticket types belong to event, quantities available, max_per_order not exceeded",
      "Calculate subtotal from ticket prices * quantities",
      "Calculate service_fee: (subtotal * 0.03) + (total_ticket_count * 50) cents",
      "Calculate total: subtotal + service_fee",
      "Create order and tickets in a transaction, increment quantity_sold on ticket types",
      "Generate QR codes for all tickets immediately (mock checkout = instant completion)",
      "Set order status to completed and completed_at",
      "Return order with nested tickets in response",
      "Add routes: POST /api/v1/orders",
      "Test with curl"
    ],
    "passes": true
  },
  {
    "id": 11,
    "category": "feature",
    "description": "Create attendee orders and tickets API",
    "steps": [
      "Add index action to orders_controller: GET /api/v1/me/orders (authenticated, scoped to current_user)",
      "Add show action: GET /api/v1/me/orders/:id (authenticated)",
      "Create tickets_controller with index: GET /api/v1/me/tickets (authenticated)",
      "Add show action for individual ticket: GET /api/v1/tickets/:qr_code (public, for QR display)",
      "Include event and ticket_type details in responses",
      "Test endpoints with curl"
    ],
    "passes": true
  },
  {
    "id": 12,
    "category": "feature",
    "description": "Create ticket check-in API",
    "steps": [
      "Create check_ins_controller with create action",
      "Lookup ticket by qr_code parameter",
      "Return 404 if ticket not found",
      "Return 422 with message if ticket already checked in (include checked_in_at)",
      "Return 422 if ticket is cancelled",
      "On success: call ticket.check_in!, return ticket details with event and ticket_type info",
      "Add route: POST /api/v1/check_in/:qr_code",
      "Test all scenarios with curl (valid, already checked in, not found)"
    ],
    "passes": true
  },
  {
    "id": 13,
    "category": "feature",
    "description": "Create organizer dashboard stats API",
    "steps": [
      "Add stats action to organizer/events_controller",
      "Calculate and return: total_tickets_sold, total_revenue_cents, tickets_checked_in",
      "Include tickets_by_type: array of {name, sold, available, revenue_cents}",
      "Include recent_orders: last 10 orders with buyer info and ticket count",
      "Add route: GET /api/v1/organizer/events/:id/stats",
      "Add attendees action: list all tickets for event with attendee info and check-in status",
      "Add route: GET /api/v1/organizer/events/:id/attendees",
      "Test with curl"
    ],
    "passes": true
  },
  {
    "id": 14,
    "category": "testing",
    "description": "RSpec model specs",
    "steps": [
      "Configure FactoryBot with factories for User, OrganizerProfile, Event, TicketType, Order, Ticket",
      "Write User model specs: validates clerk_id uniqueness, role enum works",
      "Write Event model specs: slug generation, slug uniqueness with suffix, scopes (published, upcoming), status enum",
      "Write TicketType model specs: sold_out?, available_quantity, validations",
      "Write Order model specs: status enum, associations",
      "Write Ticket model specs: generate_qr_code! produces UUID, check_in! updates status and timestamp, check_in! fails if not issued",
      "Run rspec and verify all specs pass"
    ],
    "passes": true
  },
  {
    "id": 15,
    "category": "testing",
    "description": "RSpec request specs",
    "steps": [
      "Create support/auth_helpers.rb that stubs Clerk JWT verification for test requests",
      "Write request specs for GET /api/v1/events (returns published events only)",
      "Write request specs for GET /api/v1/events/:slug (returns event with ticket_types)",
      "Write request specs for POST /api/v1/orders (creates order, tickets, increments quantity_sold)",
      "Write request specs for POST /api/v1/orders with insufficient inventory (returns 422)",
      "Write request specs for POST /api/v1/check_in/:qr_code (all scenarios: success, already checked in, not found)",
      "Write request specs for organizer events CRUD (requires auth)",
      "Run rspec and verify all specs pass"
    ],
    "passes": true
  },
  {
    "id": 16,
    "category": "feature",
    "description": "Create seed data for development",
    "steps": [
      "Create db/seeds.rb with realistic sample data",
      "Create 2 users with organizer profiles (e.g., 'Island Nights Promotions', 'Guam Beach Club')",
      "Create 6 events across categories: 2 nightlife, 1 concert, 1 festival, 1 dining, 1 sports",
      "Include mix of statuses: 4 published (upcoming), 1 draft, 1 past/completed",
      "Add 2-3 ticket types per event (General Admission, VIP, Early Bird) with varying prices",
      "Create 5-10 sample orders with tickets for the published events",
      "Mark 3-4 tickets as checked_in for the past event",
      "Run rails db:seed and verify data with rails console",
      "Verify GET /api/v1/events returns the published events"
    ],
    "passes": true
  },
  {
    "id": 17,
    "category": "frontend",
    "description": "Create frontend layout and navigation",
    "steps": [
      "Create src/components/Layout.jsx with header, main content, and footer areas",
      "Create src/components/Navbar.jsx with: logo (text 'HafaPass'), nav links (Events, Dashboard for logged-in), auth buttons",
      "Import and use UserButton from @clerk/clerk-react for logged-in users",
      "Add responsive mobile menu with hamburger toggle (useState for open/close)",
      "Style with Tailwind: ocean blue header (bg-blue-900), white text, clean sans-serif",
      "Add footer with copyright and 'Powered by Shimizu Technology'",
      "Wrap all routes in Layout component",
      "Verify layout renders correctly at desktop and mobile widths"
    ],
    "passes": true
  },
  {
    "id": 18,
    "category": "frontend",
    "description": "Create home page",
    "steps": [
      "Create src/pages/HomePage.jsx at / route",
      "Add hero section: gradient background (ocean blue to teal), tagline 'Your Island. Your Events. Your Pass.', CTA button 'Browse Events'",
      "Add featured events section: fetch upcoming events from API, display top 3-4 as cards",
      "Create src/components/EventCard.jsx: cover image (or placeholder gradient), title, date, venue, starting price",
      "Add 'For Organizers' CTA section: brief pitch, 'Get Started' button linking to /dashboard",
      "Add loading spinner while fetching events",
      "Add empty state if no events available",
      "Handle API errors with user-friendly message",
      "Verify home page renders with seed data"
    ],
    "passes": true
  },
  {
    "id": 19,
    "category": "frontend",
    "description": "Create events listing page",
    "steps": [
      "Create src/pages/EventsPage.jsx at /events route",
      "Fetch all published events from GET /api/v1/events",
      "Display events in responsive grid (1 col mobile, 2 col tablet, 3 col desktop) using EventCard",
      "Add page title 'Upcoming Events'",
      "Add loading skeleton/spinner while fetching",
      "Add empty state: 'No events available right now. Check back soon!'",
      "Handle API errors gracefully with retry option",
      "Link each EventCard to /events/:slug",
      "Verify page renders with seed data from the API"
    ],
    "passes": true
  },
  {
    "id": 20,
    "category": "frontend",
    "description": "Create event detail page",
    "steps": [
      "Create src/pages/EventDetailPage.jsx at /events/:slug route",
      "Fetch event from GET /api/v1/events/:slug (includes ticket_types)",
      "Display: cover image (full width), title, date/time formatted nicely, venue name and address",
      "Display description text",
      "Display age restriction badge if not all_ages",
      "Display ticket types section: name, price ($XX.XX format), availability ('X remaining' or 'Sold Out')",
      "Add quantity selector (number input or +/- buttons) for each available ticket type",
      "Add 'Get Tickets' button that navigates to /checkout/:slug with selected quantities in state",
      "Disable 'Get Tickets' if no tickets selected",
      "Add loading and error states",
      "Verify page renders with seed data"
    ],
    "passes": true
  },
  {
    "id": 21,
    "category": "frontend",
    "description": "Create checkout page - order summary",
    "steps": [
      "Create src/pages/CheckoutPage.jsx at /checkout/:slug route",
      "Receive selected ticket quantities from navigation state (redirect back to event if missing)",
      "Fetch event details if not already in state",
      "Display order summary: list each selected ticket type with name, quantity, line total",
      "Calculate and display subtotal",
      "Calculate and display service fee: (subtotal * 3%) + ($0.50 * total_tickets)",
      "Display order total (subtotal + service fee)",
      "Style as a clean card/panel layout",
      "Add 'Back to Event' link",
      "Verify calculations match the backend fee logic"
    ],
    "passes": false
  },
  {
    "id": 22,
    "category": "frontend",
    "description": "Create checkout page - buyer form and submission",
    "steps": [
      "Add buyer information form to CheckoutPage: name (required), email (required), phone (optional)",
      "Add form validation: email format, name not empty",
      "Add 'Complete Purchase' button (styled as primary CTA, full width on mobile)",
      "On submit: POST to /api/v1/orders with event_id, buyer info, and line_items array",
      "Show loading state on button during submission ('Processing...')",
      "On success: redirect to /orders/:id/confirmation",
      "On error: display error message (e.g., 'Tickets no longer available'), don't clear form",
      "Verify full checkout flow works end-to-end with seed data"
    ],
    "passes": false
  },
  {
    "id": 23,
    "category": "frontend",
    "description": "Create order confirmation page",
    "steps": [
      "Create src/pages/OrderConfirmationPage.jsx at /orders/:id/confirmation",
      "Fetch order details from GET /api/v1/me/orders/:id (or pass via navigation state)",
      "Display success message: 'Your tickets are confirmed!'",
      "Show order summary: event name, date, buyer name, total paid",
      "List each ticket with: ticket type name, attendee name, 'View Ticket' link",
      "Link each ticket to /tickets/:qr_code",
      "Add 'Browse More Events' button linking to /events",
      "Add loading and error states",
      "Verify page renders after successful checkout"
    ],
    "passes": false
  },
  {
    "id": 24,
    "category": "frontend",
    "description": "Create ticket display page with QR code",
    "steps": [
      "Install qrcode.react library: npm install qrcode.react",
      "Create src/pages/TicketPage.jsx at /tickets/:qr_code",
      "Fetch ticket from GET /api/v1/tickets/:qr_code",
      "Display large QR code (256x256) using qrcode.react QRCodeSVG component, encoding the qr_code value",
      "Display event name, date/time, venue below QR code",
      "Display ticket type name and attendee name",
      "Display ticket status badge (issued = green 'Valid', checked_in = gray 'Used')",
      "Style as a mobile-friendly ticket card (centered, max-width, shadow)",
      "Add loading and error states (including 'Ticket not found')",
      "Verify QR code renders and is scannable"
    ],
    "passes": false
  },
  {
    "id": 25,
    "category": "frontend",
    "description": "Create my tickets page",
    "steps": [
      "Create src/pages/MyTicketsPage.jsx at /my-tickets route (protected)",
      "Fetch user's orders from GET /api/v1/me/orders",
      "Group tickets by event, showing upcoming events first",
      "For each event: show event name, date, list of tickets with type and status",
      "Each ticket links to /tickets/:qr_code",
      "Add loading and empty states ('No tickets yet. Browse events to get started!')",
      "Add link to /my-tickets in Navbar for authenticated users",
      "Handle API errors gracefully",
      "Verify page shows tickets after completing a checkout"
    ],
    "passes": false
  },
  {
    "id": 26,
    "category": "frontend",
    "description": "Create organizer dashboard home",
    "steps": [
      "Create src/pages/dashboard/DashboardPage.jsx at /dashboard (protected)",
      "Check if current user has organizer profile (GET /api/v1/organizer_profile)",
      "If no profile: show OrganizerProfileForm (business_name, business_description fields)",
      "On profile form submit: POST to /api/v1/organizer_profile, then reload",
      "If has profile: display welcome message with business name",
      "Show list of organizer's events (GET /api/v1/organizer/events) as cards with title, date, status badge, tickets sold",
      "Add 'Create Event' button linking to /dashboard/events/new",
      "Add loading and error states",
      "Verify dashboard renders for logged-in user"
    ],
    "passes": false
  },
  {
    "id": 27,
    "category": "frontend",
    "description": "Create event creation form",
    "steps": [
      "Create src/pages/dashboard/CreateEventPage.jsx at /dashboard/events/new (protected)",
      "Build form with sections: Basic Info (title, short_description, description, category dropdown, age_restriction dropdown)",
      "Add Venue section: venue_name, venue_address, venue_city (default 'Guam')",
      "Add Date/Time section: starts_at (datetime-local input), ends_at, doors_open_at",
      "Add Settings section: max_capacity (number), cover_image_url (text input for URL)",
      "Add form validation: title, venue_name, starts_at required",
      "On submit: POST to /api/v1/organizer/events",
      "On success: redirect to /dashboard/events/:id/edit (to add ticket types)",
      "Show loading state during submission, display errors if any",
      "Verify form creates a draft event"
    ],
    "passes": false
  },
  {
    "id": 28,
    "category": "frontend",
    "description": "Create event edit page",
    "steps": [
      "Create src/pages/dashboard/EditEventPage.jsx at /dashboard/events/:id/edit (protected)",
      "Fetch event from GET /api/v1/organizer/events/:id",
      "Pre-populate same form fields as create page with existing values",
      "On submit: PUT to /api/v1/organizer/events/:id",
      "Show event status badge (draft/published) at top of page",
      "Add 'Publish Event' button (only shown for draft events) that calls POST /api/v1/organizer/events/:id/publish",
      "Show confirmation dialog before publishing",
      "Add 'View Analytics' link for published events",
      "Add loading and error states",
      "Verify editing and saving works"
    ],
    "passes": false
  },
  {
    "id": 29,
    "category": "frontend",
    "description": "Create ticket type management on event edit",
    "steps": [
      "Add TicketTypesSection component to EditEventPage (below event form)",
      "Fetch existing ticket types for the event",
      "Display each ticket type as an editable card: name, price (dollar input converted to cents), quantity_available, max_per_order",
      "Add 'Add Ticket Type' button that shows an inline form",
      "On add: POST to /api/v1/organizer/events/:event_id/ticket_types",
      "Add edit functionality: inline edit on each ticket type card, PUT to update",
      "Add delete button on each ticket type (only if quantity_sold is 0)",
      "Show quantity_sold / quantity_available for each type",
      "Handle loading and errors for each operation",
      "Verify adding, editing, and removing ticket types works"
    ],
    "passes": false
  },
  {
    "id": 30,
    "category": "frontend",
    "description": "Create event analytics page",
    "steps": [
      "Create src/pages/dashboard/EventAnalyticsPage.jsx at /dashboard/events/:id/analytics (protected)",
      "Fetch stats from GET /api/v1/organizer/events/:id/stats",
      "Display summary cards: Total Tickets Sold, Total Revenue (formatted as $XX.XX), Check-in Rate",
      "Display tickets by type table: type name, sold count, available, revenue",
      "Display recent orders list: buyer name, email, ticket count, total, date",
      "Add 'View Attendees' section or tab showing attendee list with check-in status",
      "Add link back to event edit page",
      "Add loading and error states",
      "Verify stats display correctly with seed data"
    ],
    "passes": false
  },
  {
    "id": 31,
    "category": "frontend",
    "description": "Create QR code scanner page",
    "steps": [
      "Install QR scanning library: npm install html5-qrcode",
      "Create src/pages/dashboard/ScannerPage.jsx at /dashboard/scanner (protected)",
      "Initialize Html5QrcodeScanner with camera access on mount",
      "On successful scan: POST to /api/v1/check_in/:qr_code",
      "Display result feedback: green success card (attendee name, ticket type, event), yellow warning ('Already checked in at [time]'), red error ('Invalid ticket')",
      "Auto-reset scanner after 3 seconds to scan next ticket",
      "Add manual QR code text input as fallback (for when camera doesn't work)",
      "Add scan count display: 'X tickets checked in this session'",
      "Handle camera permission denied gracefully",
      "Verify scanner works (can test with manual input using QR codes from seed data)"
    ],
    "passes": false
  },
  {
    "id": 32,
    "category": "integration",
    "description": "Scaffold Stripe integration",
    "steps": [
      "Add stripe gem to Gemfile and bundle install",
      "Create config/initializers/stripe.rb: Stripe.api_key = ENV['STRIPE_SECRET_KEY'] (only if key present)",
      "Create app/services/stripe_service.rb with placeholder methods: create_payment_intent(order), confirm_payment(payment_intent_id)",
      "Add comments in OrdersController indicating where Stripe integration would replace mock checkout",
      "Add STRIPE_SECRET_KEY and STRIPE_PUBLISHABLE_KEY to .env.example",
      "Verify app runs without Stripe keys (no errors on boot)"
    ],
    "passes": false
  },
  {
    "id": 33,
    "category": "integration",
    "description": "Scaffold S3 image upload with presigned URLs",
    "steps": [
      "Add aws-sdk-s3 gem to Gemfile and bundle install",
      "Create config/initializers/aws.rb: configure AWS S3 client only if ENV keys present (graceful no-op otherwise)",
      "Create app/services/s3_service.rb with presigned URL pattern: generate_presigned_post(filename, content_type) that returns {url, fields} for direct browser upload",
      "Add generate_presigned_get(key) method for generating time-limited download URLs",
      "S3 key format: uploads/events/:event_id/:timestamp_:filename",
      "Create POST /api/v1/uploads/presign endpoint that returns presigned POST data (authenticated)",
      "Add comments in events controller indicating where S3 presigned URL would replace cover_image_url text input",
      "Add AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_BUCKET, AWS_REGION to .env.example",
      "Verify app runs without AWS keys (presign endpoint returns 503 'Storage not configured')"
    ],
    "passes": false
  },
  {
    "id": 34,
    "category": "integration",
    "description": "Scaffold Resend email service",
    "steps": [
      "Add resend gem to Gemfile and bundle install",
      "Create config/initializers/resend.rb: set Resend.api_key only if ENV key present",
      "Create app/services/email_service.rb using Resend::Emails.send directly (NOT ActionMailer mail() — it has lazy evaluation issues with Resend)",
      "Add send_order_confirmation(order) method: builds inline HTML with order details, calls Resend::Emails.send with from, to, subject, html params",
      "Add send_ticket_email(ticket) method: inline HTML with ticket details and link to /tickets/:qr_code",
      "If RESEND_API_KEY not configured, log 'Email would be sent to [email]' and return without error",
      "Call EmailService.send_order_confirmation in orders_controller after successful creation (wrapped in begin/rescue so it never breaks checkout)",
      "Add RESEND_API_KEY and MAILER_FROM_EMAIL to .env.example",
      "Verify app runs without Resend key and orders still complete successfully"
    ],
    "passes": false
  },
  {
    "id": 35,
    "category": "polish",
    "description": "Mobile responsiveness pass",
    "steps": [
      "Review all pages at 375px mobile viewport in browser",
      "Fix any overflowing content or broken layouts",
      "Ensure all touch targets are at least 44x44px (buttons, links, form fields)",
      "Verify mobile navigation hamburger menu works correctly",
      "Verify checkout flow is usable on mobile (form fields, buttons)",
      "Verify ticket page QR code is large enough to scan on mobile",
      "Verify scanner page works on mobile (camera access)",
      "Test event cards stack properly on mobile",
      "Take screenshots at 375px and 1280px widths for key pages"
    ],
    "passes": false
  },
  {
    "id": 36,
    "category": "polish",
    "description": "PWA setup for mobile installability",
    "steps": [
      "Create public/manifest.json with: name 'HafaPass', short_name 'HafaPass', start_url '/', display 'standalone', background_color '#1e3a5f', theme_color '#1e3a5f'",
      "Add icons array to manifest: 192x192 and 512x512 PNG icons (create simple placeholder icons with the app name or use a solid color square)",
      "Add to index.html head: <link rel='manifest' href='/manifest.json' />",
      "Add meta tags: <meta name='theme-color' content='#1e3a5f' />, <meta name='apple-mobile-web-app-capable' content='yes' />, <meta name='apple-mobile-web-app-status-bar-style' content='default' />",
      "Add <link rel='apple-touch-icon' href='/icons/icon-192.png' />",
      "Verify in browser DevTools > Application tab that manifest is detected",
      "Verify 'Add to Home Screen' prompt appears on mobile Chrome (or install option in desktop Chrome)"
    ],
    "passes": false
  },
  {
    "id": 37,
    "category": "polish",
    "description": "SEO basics and Open Graph tags",
    "steps": [
      "Create public/robots.txt: Allow /, Disallow /dashboard, Disallow /api/, add Sitemap URL",
      "Update index.html with base meta tags: title 'HafaPass - Guam Event Tickets', description 'Discover and purchase tickets for events across Guam', keywords",
      "Add Open Graph meta tags to index.html: og:title, og:description, og:image (use a default social share image), og:url, og:type 'website'",
      "Add Twitter Card meta tags: twitter:card 'summary_large_image', twitter:title, twitter:description",
      "Update public/_redirects to serve robots.txt directly: '/robots.txt /robots.txt 200' before the SPA catch-all",
      "Verify robots.txt is accessible at /robots.txt",
      "Verify Open Graph tags render in browser page source"
    ],
    "passes": false
  },
  {
    "id": 38,
    "category": "polish",
    "description": "Final integration testing and documentation",
    "steps": [
      "Test complete flow end-to-end with agent-browser: sign up -> create organizer profile -> create event -> add ticket types -> publish -> view as public -> purchase tickets -> view tickets with QR -> scan ticket -> view analytics",
      "Fix any issues found during end-to-end testing",
      "Create README.md with: project description, tech stack, setup instructions (both servers), required env vars, how to seed data",
      "Document remaining TODOs for production: real Stripe integration, S3 uploads, Resend emails, Neon database, deploy to Render/Netlify",
      "Verify all RSpec tests still pass: bundle exec rspec",
      "Verify frontend builds without errors: npm run build",
      "Take final screenshots of all key pages using agent-browser for documentation"
    ],
    "passes": false
  }
]
```

---

## Agent Instructions

1. Read `activity.md` first to understand current state
2. Find next task with `"passes": false`
3. Complete all steps for that task
4. **Verify with agent-browser** (see verification protocol below)
5. Update task to `"passes": true`
6. Log completion in `activity.md`
7. Commit changes with descriptive message
8. Repeat until all tasks pass

### Agent-Browser Verification Protocol

**Every frontend task MUST be verified with agent-browser.** Do not mark a frontend task as passing without browser verification and a screenshot.

**For frontend/UI tasks:**
```bash
# 1. Open the relevant page
agent-browser open http://localhost:5173/[route]

# 2. Take a snapshot to verify DOM structure and interactive elements
agent-browser snapshot -i -c

# 3. Interact with the page (fill forms, click buttons, etc.)
agent-browser fill @e1 "test value"
agent-browser click @e2

# 4. Take a screenshot for visual verification
agent-browser screenshot screenshots/task-[id]-[name].png

# 5. For mobile verification (touch targets, responsive layout)
agent-browser screenshot screenshots/task-[id]-mobile.png --viewport 375x812
```

**For authenticated pages:**
```bash
agent-browser open http://localhost:5173/sign-in
agent-browser snapshot -i
# Fill in test Clerk credentials
agent-browser fill @email "test-admin@hafameetings.com"
agent-browser fill @password "HafaMeetings!"
agent-browser click @submit
agent-browser wait --load networkidle
# Now navigate to protected page
agent-browser open http://localhost:5173/dashboard
agent-browser snapshot -i -c
agent-browser screenshot screenshots/task-[id]-dashboard.png
```

**For API-only tasks:**
```bash
# Test with curl, then verify data appears in browser
curl -s http://localhost:3000/api/v1/events | python3 -m json.tool
# Also open the frontend to verify API data renders
agent-browser open http://localhost:5173/events
agent-browser snapshot -i -c
```

**For checkout/order flow verification:**
```bash
# Navigate through the full flow
agent-browser open http://localhost:5173/events
agent-browser snapshot -i
agent-browser click @[event-card]
# Select tickets, fill form, submit, verify confirmation
agent-browser screenshot screenshots/task-[id]-checkout-flow.png
```

### Important Rules

- Only modify the `passes` field. Do not remove or rewrite tasks.
- The Rails API runs on `localhost:3000`
- The React frontend runs on `localhost:5173`
- **Start both servers before any verification**
- For authenticated routes, use: email `test-admin@hafameetings.com`, password `HafaMeetings!`
- Each frontend task should include inline error/loading states
- The Ticket status enum uses `issued` (not `valid`) to avoid ActiveRecord conflicts
- **Take at least one screenshot per frontend task** — save to `screenshots/` directory
- After completing a task, always run `bundle exec rspec` (if backend changed) to catch regressions

---

## Completion Criteria

All tasks marked with `"passes": true`

## Environment Variables Required

### Backend (.env)
```
CLERK_SECRET_KEY=sk_test_xxx
CLERK_PUBLISHABLE_KEY=pk_test_xxx
DATABASE_URL=postgres://... (for production only)
STRIPE_SECRET_KEY=sk_test_xxx (optional for MVP)
AWS_ACCESS_KEY_ID=xxx (optional for MVP)
AWS_SECRET_ACCESS_KEY=xxx (optional for MVP)
AWS_BUCKET=xxx (optional for MVP)
AWS_REGION=us-west-2 (optional for MVP)
RESEND_API_KEY=xxx (optional for MVP)
MAILER_FROM_EMAIL=tickets@hafapass.com (optional for MVP)
```

### Frontend (.env.local)
```
VITE_CLERK_PUBLISHABLE_KEY=pk_test_xxx
VITE_API_URL=http://localhost:3000/api/v1
```
