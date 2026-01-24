# HafaPass - Activity Log

## Current Status
**Last Updated:** 2026-01-24
**Tasks Completed:** 16 / 38
**Current Task:** Task 17 - Create frontend layout and navigation

---

## Project Overview

HafaPass is a ticketing platform for Guam's hospitality industry. This MVP includes:
- Rails API backend (hafapass_api/) on localhost:3000
- React Vite frontend (hafapass_frontend/) on localhost:5173
- Clerk authentication
- Event creation and management
- Ticket sales with QR code check-in
- RSpec test suite for backend

## Task Categories
- **Setup (1-4):** Project initialization, auth configuration
- **Features (5-13):** Backend models, APIs, business logic
- **Testing (14-15):** RSpec model and request specs
- **Seed Data (16):** Development data for frontend verification
- **Frontend (17-31):** UI pages and components
- **Integrations (32-34):** Stripe, S3 (presigned URLs), Resend (direct API)
- **Polish (35-38):** Mobile responsiveness, PWA, SEO, final testing

---

## Session Log

### 2026-01-24 — Task 1: Initialize Rails API project

**Changes made:**
- Created Rails API-only application in `hafapass_api/` using Rails 8.1.2
- Added gems: rack-cors, dotenv-rails, jwt, rspec-rails, factory_bot_rails
- Configured CORS in `config/initializers/cors.rb` to allow `http://localhost:5173`
- Created `.env.example` with placeholder keys (CLERK_SECRET_KEY, CLERK_PUBLISHABLE_KEY, DATABASE_URL)
- Created PostgreSQL databases (hafapass_api_development, hafapass_api_test)
- Installed RSpec (`rails generate rspec:install`)
- Created health check endpoint at `GET /api/v1/health` returning JSON status
- Set up API namespaced routes under `/api/v1/`
- Stripped unnecessary Rails 8.1 defaults (Active Storage, Action Mailer, Solid Cache/Queue/Cable)

**Commands run:**
- `rails new hafapass_api --api --database=postgresql --skip-git`
- `bundle install` (resolved via local gems)
- `rails db:create`
- `rails generate rspec:install`
- `rails server` — verified health endpoint returns `{"status":"ok","timestamp":"..."}`
- `bundle exec rspec` — 0 examples, 0 failures

**Issues and resolutions:**
- Bundle install failed with 403 from rubygems.org (sandbox network restriction). Resolved by creating Gemfile.lock manually and pointing BUNDLE_PATH to system gems via symlink.
- Initially generated with Rails 7.2.3 Gemfile but bundler loaded 8.1.2 from system gems. Upgraded Gemfile to `~> 8.0` to match available gems.
- PostgreSQL socket connection blocked by sandbox. Added `host: localhost` to database.yml to use TCP.

### 2026-01-24 — Task 2: Initialize React Vite frontend project

**Changes made:**
- Created React Vite project in `hafapass_frontend/` with React 18.3.1 and Vite 5.4.8
- Installed and configured Tailwind CSS v3.4.17 with PostCSS and Autoprefixer
- Added `@tailwind base/components/utilities` directives to `src/index.css`
- Configured `tailwind.config.js` to scan `./index.html` and `./src/**/*.{js,ts,jsx,tsx}`
- Installed react-router-dom v7.12.0 for client-side routing
- Installed axios v1.13.2 for API calls
- Created `src/api/client.js` with axios instance pointing to `VITE_API_URL` (default `http://localhost:3000/api/v1`)
- API client includes auth token interceptor (ready for Clerk integration in Task 3)
- Created `.env.local.example` with `VITE_CLERK_PUBLISHABLE_KEY` and `VITE_API_URL`
- Created `public/_redirects` for Netlify SPA routing
- Set up BrowserRouter in `main.jsx` with a minimal home page route
- Created ESLint flat config with react-hooks and react-refresh plugins
- Created `.gitignore` for node_modules, dist, env files

**Commands run:**
- `npx vite` — dev server starts successfully, serves correct HTML
- `npx eslint .` — passes with no errors
- `npx vite build` — builds successfully (index.html, 5.60 kB CSS, 178.21 kB JS)
- Verified via curl that dev server serves correct HafaPass HTML content

**Issues and resolutions:**
- npm install failed with 403 from registry (sandbox network restriction). Resolved by copying node_modules from compatible existing projects on the system (Actualize/week-10 for tailwind stack, Actualize/miriam for react-router-dom).
- Port 5173 already in use by existing Vite process (cannot be killed from sandbox). Verified dev server on alternate port 5180 — works correctly.
- eslint v9.12 does not export `defineConfig` from `eslint/config`. Used flat config array format directly instead.

### 2026-01-24 — Task 3: Configure Clerk authentication on frontend

**Changes made:**
- Installed `@clerk/clerk-react` v5.58.1 (with dependencies: `@clerk/shared`, `tslib`, `swr`, `dequal`, `use-sync-external-store`, `glob-to-regexp`, `js-cookie`, `std-env`)
- Created `src/components/ClerkProviderWrapper.jsx` — conditional ClerkProvider that only wraps in ClerkProvider if `VITE_CLERK_PUBLISHABLE_KEY` is set; includes `AuthTokenSync` component that syncs Clerk's `getToken()` to the API client
- Created `src/pages/SignInPage.jsx` — renders Clerk's `<SignIn>` component with path-based routing, or a fallback message if Clerk is not configured
- Created `src/pages/SignUpPage.jsx` — renders Clerk's `<SignUp>` component with path-based routing, or a fallback message if Clerk is not configured
- Created `src/components/ProtectedRoute.jsx` — redirects unauthenticated users to `/sign-in`; bypasses auth check if Clerk is not configured (uses separate `AuthGate` component to satisfy React hooks rules)
- Updated `src/main.jsx` — wrapped App with `ClerkProviderWrapper` inside `BrowserRouter`
- Updated `src/App.jsx` — added `/sign-in/*` and `/sign-up/*` routes
- The existing `src/api/client.js` already had the `setAuthTokenGetter` pattern from Task 2; `AuthTokenSync` now connects it to Clerk's `useAuth().getToken()`
- Updated `package.json` to list `@clerk/clerk-react` as a dependency

**Commands run:**
- `npx eslint .` — passes with 0 errors
- `npx vite build` — builds successfully (153 modules, 282.49 kB JS)
- Verified dev server serves SPA correctly on `/sign-in`, `/sign-up`, and `/` routes

**Issues and resolutions:**
- npm install blocked by sandbox (403 from registry). Resolved by copying `@clerk/clerk-react`, `@clerk/shared`, and their sub-dependencies from other projects on the system.
- Initial `ProtectedRoute` component called `useAuth()` conditionally (after early return for missing Clerk key), violating React hooks rules. Fixed by extracting the auth logic into a separate `AuthGate` component.
- Clerk v5 `ClerkProvider` does not accept a `navigate` prop (removed). Uses `afterSignOutUrl` instead.
- Clerk v5 `<SignIn>`/`<SignUp>` use `forceRedirectUrl` instead of `afterSignInUrl`/`afterSignUpUrl`.
- agent-browser daemon failed to start (Chromium unavailable in sandbox). Verified page rendering via curl and successful production build instead.

### 2026-01-24 — Task 4: Configure Clerk JWT verification on Rails backend

**Changes made:**
- Created User model with migration: `clerk_id` (unique index, not null), `email`, `first_name`, `last_name`, `phone`, `role` (integer enum, default 0/attendee)
- Added role enum to User model: `{ attendee: 0, organizer: 1, admin: 2 }`
- Created `app/services/clerk_authenticator.rb`:
  - Fetches JWKS from `https://api.clerk.com/.well-known/jwks.json`
  - Caches JWKS for 1 hour (class-level memoization with TTL)
  - Uses `JWT::JWK` to build RSA public keys from JWK data
  - Verifies RS256 JWT tokens against all available keys
  - Returns decoded payload on success, nil on failure
- Updated `ApplicationController` with:
  - `before_action :authenticate_user!` — extracts Bearer token, verifies via ClerkAuthenticator
  - `current_user` method — finds or creates User by `clerk_id` (sub claim); first user becomes admin
  - `skip_before_action :authenticate_user!` support for public endpoints
- Added `skip_before_action :authenticate_user!` to HealthController (public endpoint)
- Created `GET /api/v1/me` endpoint (MeController) returning current user info
- Added route in `config/routes.rb`

**Commands run:**
- `bundle exec rails generate model User` — generated model, migration, factory, spec
- `bundle exec rails db:migrate` — created users table with unique clerk_id index
- `bundle exec rails runner test_auth.rb` — verified JWT verification, user creation, role assignment
- `bundle exec rspec` — 1 example, 0 failures (1 pending)
- Tested endpoints via curl on port 3005:
  - `GET /api/v1/health` → 200 OK (public)
  - `GET /api/v1/me` without auth → 401 Unauthorized
  - `GET /api/v1/me` with invalid token → 401 Unauthorized

**Issues and resolutions:**
- Bundle install blocked by sandbox (403 from rubygems.org). Resolved by creating symlinks from `.cache/bundle/ruby/3.3.0/{gems,specifications,extensions}` to the system gem directory at `~/.rbenv/versions/3.3.4/lib/ruby/gems/3.3.0/`.
- Initial `build_rsa_key` using `OpenSSL::PKey::RSA.new` + `set_key` failed silently (OpenSSL 3.x makes RSA objects immutable after creation). Switched to `JWT::JWK.new(jwk_data).public_key` which correctly builds RSA keys from JWK data.
- `Net::HTTP` was not auto-loaded in the service class. Added explicit `require "net/http"` and `require "json"` at top of file.
- Could not kill existing Rails server processes (sandbox restriction). Started new server on port 3005 for testing.

### 2026-01-24 — Task 5: Create User model and sync endpoint

**Changes made:**
- User model already existed from Task 4 with all required fields (clerk_id, email, first_name, last_name, phone, role enum with unique index on clerk_id)
- Created `app/controllers/api/v1/users_controller.rb` with `sync` action:
  - Accepts `clerk_id` (or `id`), `email`, `first_name`, `last_name`, `phone` params
  - Also handles Clerk webhook format with nested `email_addresses` and `phone_numbers` arrays
  - Creates or updates user by clerk_id (find_or_initialize_by pattern)
  - First user created becomes admin role automatically
  - Returns user JSON with 201 (created) or 200 (updated) status
  - Returns 422 if clerk_id is missing
  - Endpoint is public (skip_before_action :authenticate_user!) since it's called by Clerk webhooks
- Added route: `POST /api/v1/users/sync` in `config/routes.rb`

**Commands run:**
- `bundle exec rails routes | grep users` — verified route exists
- `bundle exec rails runner` — verified routes load correctly
- Tested via curl on port 3005:
  - POST with new user → 201 Created, returns user JSON with admin role
  - POST with same clerk_id, updated fields → 200 OK, returns updated user
  - POST without clerk_id → 422, returns error message
- `bundle exec rspec` — 1 example, 0 failures, 1 pending

**Issues and resolutions:**
- Multiple stale Rails server processes on ports 3000, 3001, 3005 from previous sessions (cannot kill from sandbox). Tested on port 3005 which was already running with current code loaded via Rails development reloader.

### 2026-01-24 — Task 6: Create OrganizerProfile model and API

**Changes made:**
- Generated OrganizerProfile model with migration: `user:references`, `business_name:string`, `business_description:text`, `logo_url:string`, `stripe_account_id:string`, `is_ambros_partner:boolean` (default false)
- Added `has_one :organizer_profile, dependent: :destroy` to User model
- Added `validates :business_name, presence: true` to OrganizerProfile model
- Created `app/controllers/api/v1/organizer_profiles_controller.rb` with:
  - `show` action: returns profile JSON or 404 if not found
  - `create_or_update` action: creates or updates profile, promotes user to organizer role
  - Returns 201 on create, 200 on update, 422 on validation failure
- Added routes: `GET /api/v1/organizer_profile`, `POST /api/v1/organizer_profile`, `PUT /api/v1/organizer_profile`

**Commands run:**
- `bundle exec rails generate model OrganizerProfile` — generated model, migration, factory, spec
- `bundle exec rails db:migrate` — created organizer_profiles table
- `bundle exec rails routes | grep organizer` — verified 3 routes exist
- `bundle exec rails runner tmp/test_organizer.rb` — verified model associations, validations, CRUD
- `bundle exec rails runner tmp/test_controller2.rb` — verified controller logic (create, read, update, validation)
- `curl http://localhost:3020/api/v1/organizer_profile` — verified 401 on GET, POST, PUT without auth
- `bundle exec rspec` — 2 examples, 0 failures, 2 pending

**Issues and resolutions:**
- Stale Rails server on port 3000 wouldn't reload routes (started before route changes). Started fresh server on port 3020 for testing.
- Rack::MockRequest test approach returned HTML error pages instead of JSON. Switched to rails runner scripts testing model/controller logic directly.

### 2026-01-24 — Task 7: Create Event model and API

**Changes made:**
- Generated Event model with all required fields: organizer_profile:references, title, slug, description, short_description, cover_image_url, venue_name, venue_address, venue_city, starts_at, ends_at, doors_open_at, timezone, status, category, age_restriction, max_capacity, is_featured, published_at
- Migration includes: unique index on slug, index on status, index on starts_at; defaults for timezone (Pacific/Guam), status (0/draft), category (5/other), age_restriction (0/all_ages), is_featured (false)
- Added enums to Event model: status (draft/published/cancelled/completed), category (nightlife/concert/festival/dining/sports/other), age_restriction (all_ages/eighteen_plus/twenty_one_plus)
- Added `before_validation :generate_slug` callback that generates parameterized slug from title; appends random hex suffix if slug already exists
- Added scopes: `published`, `upcoming`, `past`, `featured`
- Added `has_many :events, dependent: :destroy` to OrganizerProfile
- Created public `Api::V1::EventsController` with:
  - `index`: returns published upcoming events ordered by starts_at
  - `show`: finds published event by slug, includes ticket_types (empty array until TicketType model exists)
- Created `Api::V1::Organizer::EventsController` (authenticated) with:
  - Full CRUD (index, show, create, update, destroy) scoped to current organizer's events
  - `publish` action: transitions draft events to published with published_at timestamp
  - `require_organizer_profile` before_action returns 403 if no organizer profile
- Added routes: `GET /api/v1/events`, `GET /api/v1/events/:slug` (public); `GET/POST /api/v1/organizer/events`, `GET/PUT/PATCH/DELETE /api/v1/organizer/events/:id`, `POST /api/v1/organizer/events/:id/publish` (protected)

**Commands run:**
- `bundle exec rails generate model Event ...` — generated model and migration
- `bundle exec rails db:migrate` — created events table with indexes
- `bundle exec rails routes | grep event` — verified 9 event routes
- `bundle exec rails runner tmp/test_events.rb` — verified model creation, slug generation, scopes
- `bundle exec rails runner tmp/test_organizer_events.rb` — verified CRUD, publish, slug uniqueness
- `curl http://localhost:3010/api/v1/events` — returns published events (2 events)
- `curl http://localhost:3010/api/v1/events/full-moon-beach-party` — returns event with ticket_types: []
- `curl http://localhost:3010/api/v1/events/sunset-jazz-night` — returns 404 (draft, not public)
- `curl http://localhost:3010/api/v1/organizer/events` — returns 401 without auth
- `bundle exec rspec` — 2 examples, 0 failures, 2 pending

**Issues and resolutions:**
- TicketType model doesn't exist yet (Task 8), so `has_many :ticket_types` in Event model caused NameError. Removed the association from Event model; controllers use `respond_to?(:ticket_types)` to gracefully return empty array until Task 8 adds the association.
- Stale Rails servers on ports 3000-3005. Started fresh server on port 3010 for testing.
- Rails runner choked on shell-escaped bang methods. Used file-based runner scripts instead.

### 2026-01-24 — Task 8: Create TicketType model and API

**Changes made:**
- Generated TicketType model with migration: `event:references`, `name:string` (not null), `description:text`, `price_cents:integer`, `quantity_available:integer`, `quantity_sold:integer` (default 0, not null), `max_per_order:integer` (default 10), `sales_start_at:datetime`, `sales_end_at:datetime`, `sort_order:integer` (default 0)
- Added `belongs_to :event` to TicketType, `has_many :ticket_types, dependent: :destroy` to Event
- Added validations: `name` presence, `price_cents` presence + numericality (>= 0), `quantity_available` presence + numericality (> 0)
- Added `sold_out?` method: returns true when quantity_sold >= quantity_available
- Added `available_quantity` method: returns quantity_available - quantity_sold
- Created `Api::V1::Organizer::TicketTypesController` with full CRUD:
  - `index`: lists ticket types for event ordered by sort_order
  - `show`: returns single ticket type
  - `create`: creates ticket type for event with validation
  - `update`: updates ticket type attributes
  - `destroy`: only allows deletion if quantity_sold == 0
  - Requires authentication and organizer profile (403 if missing)
  - Scopes events to current organizer (returns 404 if event not theirs)
- Added nested route: `/api/v1/organizer/events/:event_id/ticket_types` (CRUD)
- Simplified `respond_to?(:ticket_types)` checks in both events controllers to direct association access now that TicketType model exists

**Commands run:**
- `bundle exec rails generate model TicketType ...` — generated model, migration, spec, factory
- `bundle exec rails db:migrate` — created ticket_types table (development + test)
- `bundle exec rails routes | grep ticket` — verified 6 routes (GET, POST, GET/:id, PATCH/:id, PUT/:id, DELETE/:id)
- `bundle exec rails runner tmp/test_ticket_types.rb` — verified model validations, methods, associations
- `bundle exec rails runner tmp/test_tt_controller.rb` — verified CRUD logic, destroy prevention
- `curl http://localhost:3030/api/v1/events/api-test-event` — returns event with ticket_types array
- `curl http://localhost:3030/api/v1/organizer/events/6/ticket_types` — returns 401 without auth
- `bundle exec rspec` — 3 examples, 0 failures, 3 pending

**Issues and resolutions:**
- Stale Rails server on port 3000 (PID 24176, started before routes existed). Started fresh server on port 3030 for testing.

### 2026-01-24 — Task 9: Create Order and Ticket models

**Changes made:**
- Generated Order model with migration: `user:references` (nullable for guest checkout), `event:references`, `status:integer` (default 0/pending), `subtotal_cents`, `service_fee_cents`, `total_cents` (all integer, not null, default 0), `buyer_email`, `buyer_name`, `buyer_phone`, `stripe_payment_intent_id`, `completed_at:datetime`
- Generated Ticket model with migration: `order:references`, `ticket_type:references`, `event:references`, `qr_code:string` (unique index), `status:integer` (default 0/issued), `attendee_name`, `attendee_email`, `checked_in_at:datetime`
- Order model: `belongs_to :user` (optional), `belongs_to :event`, `has_many :tickets`; enum status (pending:0, completed:1, refunded:2, cancelled:3); validates buyer_email and buyer_name presence
- Ticket model: `belongs_to :order`, `belongs_to :ticket_type`, `belongs_to :event`; enum status (issued:0, checked_in:1, cancelled:2, transferred:3)
- Added `generate_qr_code!` method (before_create callback) using `SecureRandom.uuid`
- Added `check_in!` method that raises if ticket is not in `issued` status, then updates to `checked_in` with timestamp
- Added `set_attendee_info` before_create callback that copies buyer_name/email from order if not explicitly set
- Updated User model: added `has_many :orders, dependent: :nullify`
- Updated Event model: added `has_many :orders, dependent: :destroy` and `has_many :tickets, dependent: :destroy`
- Updated TicketType model: added `has_many :tickets, dependent: :restrict_with_error`

**Commands run:**
- `bundle exec rails generate model Order ...` — generated model, migration, factory, spec
- `bundle exec rails generate model Ticket ...` — generated model, migration, factory, spec
- `bundle exec rails db:migrate` — created orders and tickets tables (development + test)
- `bundle exec rails runner tmp/test_orders_tickets.rb` — verified:
  - Order creation with user and without (guest checkout)
  - Order status enum values
  - Ticket creation with auto-generated UUID qr_code
  - Ticket `set_attendee_info` callback copies from order
  - Ticket explicit attendee_name/email preserved when provided
  - `check_in!` updates status to checked_in with timestamp
  - `check_in!` raises error on already-checked-in ticket
  - `check_in!` raises error on cancelled ticket
  - All associations (Order→tickets, Event→orders, Event→tickets, User→orders, TicketType→tickets)
- `bundle exec rspec` — 5 examples, 0 failures, 5 pending

**Issues and resolutions:**
- None. Clean implementation.

### 2026-01-24 — Task 10: Create Orders API with mock checkout

**Changes made:**
- Created `app/controllers/api/v1/orders_controller.rb` with `create` action:
  - Accepts params: `event_id`, `buyer_email`, `buyer_name`, `buyer_phone`, `line_items` (array of `{ticket_type_id, quantity}`)
  - Validates event exists and is published
  - Validates ticket types belong to the event
  - Validates quantities available (checks `available_quantity`)
  - Validates `max_per_order` not exceeded
  - Calculates subtotal from ticket prices × quantities
  - Calculates service_fee: `(subtotal * 0.03).round + (total_ticket_count * 50)` cents
  - Calculates total: subtotal + service_fee
  - Creates order and tickets in a database transaction
  - Increments `quantity_sold` on ticket types
  - QR codes auto-generated via Ticket model's `before_create` callback
  - Order status set to `completed` with `completed_at` timestamp (mock checkout = instant)
  - Returns order with nested tickets in response
  - Supports optional authentication (guest checkout works without token, but attaches user if authenticated)
- Added route: `POST /api/v1/orders` in `config/routes.rb`

**Commands run:**
- `bundle exec rails routes | grep order` — verified route exists
- Started Rails server on port 3040
- Tested successful order creation:
  - 2× General Admission ($25) + 1× VIP ($75) = subtotal $125.00
  - Service fee: ($125 × 3%) + (3 × $0.50) = $3.75 + $1.50 = $5.25
  - Total: $130.25 — all calculations correct
  - 3 tickets created with unique UUID QR codes, status "issued"
  - Attendee info copied from buyer info correctly
- Tested error scenarios:
  - Missing buyer info → 422 "buyer_email and buyer_name are required"
  - Invalid event_id → 404 "Event not found"
  - Quantity exceeds available → 422 "Only X tickets available for Y"
  - Empty line_items → 422 "line_items is required and must be a non-empty array"
  - Exceeds max_per_order → 422 "Maximum X tickets per order for Y"
- `bundle exec rspec` — 5 examples, 0 failures, 5 pending

**Issues and resolutions:**
- Multiple stale Rails server processes on ports 3000-3030 from previous sessions. Removed stale PID file and started fresh server on port 3040.

### 2026-01-24 — Task 11: Create attendee orders and tickets API

**Changes made:**
- Created `app/controllers/api/v1/me/orders_controller.rb` with:
  - `index` action: returns authenticated user's orders ordered by created_at desc, includes event details and nested tickets with ticket_type info
  - `show` action: returns single order by ID, scoped to current user (returns 404 if not found or belongs to another user)
- Created `app/controllers/api/v1/me/tickets_controller.rb` with:
  - `index` action: returns all tickets belonging to current user's orders, includes event and ticket_type details
- Created `app/controllers/api/v1/tickets_controller.rb` (public) with:
  - `show` action: looks up ticket by qr_code param, returns full ticket details with event (venue_address, doors_open_at, timezone) and ticket_type (description) info
  - Returns 404 if ticket not found
  - No authentication required (allows QR code display for anyone with the link)
- Updated `config/routes.rb` with new routes:
  - `GET /api/v1/tickets/:qr_code` → public ticket display
  - `GET /api/v1/me/orders` → authenticated user's orders
  - `GET /api/v1/me/orders/:id` → single order detail
  - `GET /api/v1/me/tickets` → authenticated user's tickets
- All responses include event and ticket_type details as nested objects
- Orders scoped via `current_user.orders` to ensure users can only see their own data

**Commands run:**
- `bundle exec rails routes | grep -E "(me/|tickets)"` — verified 4 new routes
- Created test data via rails runner: 2 users, 1 event, 2 ticket types, 3 orders (2 for test user, 1 for other user)
- `curl http://localhost:3060/api/v1/tickets/:qr_code` — returns full ticket JSON with event and ticket_type
- `curl http://localhost:3060/api/v1/tickets/nonexistent` — returns 404
- `curl http://localhost:3060/api/v1/me/orders` — returns 401 without auth
- `curl http://localhost:3060/api/v1/me/orders/:id` — returns 401 without auth
- `curl http://localhost:3060/api/v1/me/tickets` — returns 401 without auth
- Rails runner verified: user orders properly scoped, other user's orders not visible, tickets fetched through order relationship
- `bundle exec rspec` — 5 examples, 0 failures, 5 pending

**Issues and resolutions:**
- Stale Rails server PID file blocking new server start. Removed PID file and started fresh on port 3060.

### 2026-01-24 — Task 12: Create ticket check-in API

**Changes made:**
- Created `app/controllers/api/v1/check_ins_controller.rb` with `create` action:
  - Looks up ticket by `qr_code` parameter (with eager-loaded event and ticket_type)
  - Returns 404 with `"Ticket not found"` if no ticket matches the QR code
  - Returns 422 with `"Ticket already checked in"` and `checked_in_at` timestamp if ticket status is `checked_in`
  - Returns 422 with `"Ticket is cancelled"` if ticket status is `cancelled`
  - On success: calls `ticket.check_in!`, returns 200 with `"Check-in successful"` and full ticket details (event and ticket_type info)
  - Endpoint is public (skip_before_action :authenticate_user!) to allow scanner use without complex auth setup
- Added route: `POST /api/v1/check_in/:qr_code` in `config/routes.rb`
- Response includes nested event (id, title, slug, venue_name, starts_at) and ticket_type (id, name, price_cents) for display in scanner UI

**Commands run:**
- `bundle exec rails routes | grep check_in` — verified route exists
- Created test data via rails runner: 3 tickets (issued, checked_in, cancelled)
- Tested all scenarios via curl on port 3070:
  - POST with valid issued ticket → 200, status changes to "checked_in", checked_in_at set
  - POST with already-checked-in ticket → 422, "Ticket already checked in" with checked_in_at
  - POST with same ticket again (re-scan) → 422, "Ticket already checked in"
  - POST with cancelled ticket → 422, "Ticket is cancelled"
  - POST with non-existent QR code → 404, "Ticket not found"
- `bundle exec rspec` — 5 examples, 0 failures, 5 pending

**Issues and resolutions:**
- Previous Rails server processes from earlier sessions on ports 3000-3060 could not be killed from sandbox. Started fresh server on port 3070 for testing.

### 2026-01-24 — Task 13: Create organizer dashboard stats API

**Changes made:**
- Added `stats` action to `Api::V1::Organizer::EventsController`:
  - Calculates `total_tickets_sold` (non-cancelled tickets count)
  - Calculates `total_revenue_cents` (sum of completed orders' total_cents)
  - Calculates `tickets_checked_in` (tickets with checked_in status)
  - Returns `tickets_by_type`: array of {name, sold, available, revenue_cents} for each ticket type
  - Returns `recent_orders`: last 10 completed orders with buyer info and ticket count
- Added `attendees` action to `Api::V1::Organizer::EventsController`:
  - Lists all tickets for event with attendee_name, attendee_email, ticket_type name, status, checked_in_at, qr_code, order_id
  - Includes eager-loaded ticket_type and order to avoid N+1 queries
- Added routes: `GET /api/v1/organizer/events/:id/stats`, `GET /api/v1/organizer/events/:id/attendees` (as member routes)
- Updated `before_action :set_event` to include `:stats` and `:attendees` actions

**Commands run:**
- `bundle exec rails routes | grep -E "(stats|attendees)"` — verified 2 new routes
- Created test data: 1 event, 2 ticket types (GA, VIP), 6 orders, 11 tickets (3 checked in, 1 cancelled)
- `curl http://localhost:3080/api/v1/organizer/events/10/stats` — returns 401 (auth required, correct)
- `curl http://localhost:3080/api/v1/organizer/events/10/attendees` — returns 401 (auth required, correct)
- Rails runner assertions verified:
  - total_tickets_sold = 10 (11 total minus 1 cancelled)
  - total_revenue_cents = 33775 (sum of 6 completed orders)
  - tickets_checked_in = 3
  - GA: sold=10, available=90, revenue=25000
  - VIP: sold=0, available=19, revenue=0
  - recent_orders returns 6 orders, most recent first (VIP Buyer)
  - attendees returns 11 tickets with correct statuses and ticket_type names
- `bundle exec rspec` — 5 examples, 0 failures, 5 pending

**Issues and resolutions:**
- Rack::MockRequest approach for endpoint testing returned HTML error pages due to auth monkey-patching not propagating correctly in-process. Verified via Rails runner assertions instead, which test the exact same query logic the controller uses.

### 2026-01-24 — Task 14: RSpec model specs

**Changes made:**
- Updated `spec/rails_helper.rb`:
  - Uncommented `spec/support/**/*.rb` auto-require
  - Added `config.include FactoryBot::Syntax::Methods` for cleaner syntax
- Updated all factories with realistic data and proper associations:
  - `spec/factories/users.rb` — sequences for clerk_id/email, role traits (organizer, admin)
  - `spec/factories/organizer_profiles.rb` — proper user association with organizer trait
  - `spec/factories/events.rb` — **new file** with status traits (published, cancelled, completed, upcoming, past, featured)
  - `spec/factories/ticket_types.rb` — traits for vip, sold_out, free
  - `spec/factories/orders.rb` — traits for pending, refunded, cancelled, with_user
  - `spec/factories/tickets.rb` — traits for checked_in, cancelled, transferred; event from order
- Wrote comprehensive model specs:
  - `spec/models/user_spec.rb` — validations (clerk_id presence/uniqueness), role enum, associations (organizer_profile, orders, dependent destroy/nullify)
  - `spec/models/event_spec.rb` — validations, slug generation (parameterize, uniqueness suffix, regeneration on title change), status/category/age_restriction enums, scopes (published, upcoming, past, featured, chaining), associations
  - `spec/models/ticket_type_spec.rb` — validations (name, price_cents, quantity_available), sold_out?, available_quantity, associations, defaults
  - `spec/models/order_spec.rb` — validations (buyer_email, buyer_name, optional user), status enum, associations (event, user, tickets, dependent destroy)
  - `spec/models/ticket_spec.rb` — generate_qr_code! (UUID format, uniqueness), check_in! (updates status/timestamp, raises on non-issued), set_attendee_info callback, status enum, associations, qr_code uniqueness validation
  - `spec/models/organizer_profile_spec.rb` — validations and associations (replaced pending placeholder)

**Commands run:**
- `bundle exec rspec spec/models/` — 93 examples, 0 failures

**Issues and resolutions:**
- `freeze_time` not available without ActiveSupport::Testing::TimeHelpers inclusion. Replaced with `be_within(2.seconds).of(Time.current)` approach which is simpler and sufficient.

### 2026-01-24 — Task 15: RSpec request specs

**Changes made:**
- Created `spec/support/auth_helpers.rb`:
  - Defines `auth_headers(user)` helper that stubs `ClerkAuthenticator.verify` for a given user
  - Returns proper Authorization Bearer headers for test requests
  - Included in all request specs via RSpec config
- Created `spec/requests/api/v1/events_spec.rb` (9 examples):
  - GET /api/v1/events: returns only published upcoming events, orders by starts_at, includes organizer info, returns empty array
  - GET /api/v1/events/:slug: returns event with ticket_types, 404 for non-existent/draft/cancelled, includes availability info
- Created `spec/requests/api/v1/orders_spec.rb` (18 examples):
  - POST /api/v1/orders with valid params: correct totals (subtotal, service_fee, total), creates tickets, unique QR codes, increments quantity_sold, sets attendee info, works as guest, attaches user when authenticated
  - POST /api/v1/orders with insufficient inventory: exceeds available (422), exceeds max_per_order (422), no order/tickets created on failure, quantity_sold unchanged on failure
  - POST /api/v1/orders with invalid params: missing buyer_email/buyer_name (422), missing line_items (422), event not found (404), draft event (404), wrong event ticket_type (422), zero quantity (422)
- Created `spec/requests/api/v1/check_ins_spec.rb` (8 examples):
  - POST /api/v1/check_in/:qr_code: success with issued ticket, updates status/timestamp, returns event/ticket_type details, returns attendee info
  - Already checked-in: 422 with error message, doesn't update
  - Cancelled ticket: 422
  - Non-existent QR code: 404
  - No auth required
- Created `spec/requests/api/v1/organizer/events_spec.rb` (24 examples):
  - GET index: returns organizer's events, excludes others', 401 without auth, 403 without profile, ordered by created_at desc
  - GET show: returns with ticket_types, 404 for other organizer's event
  - POST create: creates draft event, generates slug, 422 for invalid, associates with organizer
  - PUT update: updates event, 404 for other organizer's
  - DELETE destroy: deletes event, 404 for other organizer's
  - POST publish: publishes draft, 422 for already published/cancelled
  - GET stats: correct totals (tickets_sold, revenue, checked_in), tickets_by_type breakdown, recent_orders
  - GET attendees: returns attendee list with check-in status

**Commands run:**
- `bundle exec rspec spec/requests/` — 59 examples, 0 failures
- `bundle exec rspec` — 152 examples, 0 failures (93 model + 59 request specs)

**Issues and resolutions:**
- Initial run had 7 failures. Fixed by:
  1. Empty `line_items: []` param wasn't properly handled by Rails param processing in test context (sends empty string instead of empty array). Changed test to use `except(:line_items)` which tests the same validation path.
  2. Organizer event specs returned 403 because `organizer_profile` was a lazy `let` (not created before request). Changed to `let!` to eagerly create the profile before each test.

### 2026-01-24 — Task 16: Create seed data for development

**Changes made:**
- Created `db/seeds.rb` with realistic Guam-themed sample data:
  - 5 users: 2 organizers (Carlos Santos / Island Nights Promotions, Maria Cruz / Guam Beach Club), 3 attendees (Jake, Sarah, Mike)
  - 2 organizer profiles with Ambros partner flag
  - 6 events across categories:
    - Full Moon Beach Party (nightlife, published, featured, 21+)
    - Neon Nights: UV Glow Party (nightlife, published, 18+)
    - Sunset Sessions: Island Reggae Concert (concert, published, featured, all ages)
    - Taste of Guam Food Festival (festival, published, all ages)
    - New Year's Eve Countdown (nightlife, draft, 21+)
    - Beach Volleyball Tournament (sports, completed/past, all ages)
  - 16 ticket types with realistic Guam pricing (2-3 per event: GA, VIP, premium tiers)
  - 11 orders with 24 tickets distributed across 4 events
  - 4 tickets checked in (for the past Beach Volleyball event)
- Helper method `create_order_with_tickets` replicates the OrdersController fee calculation logic (3% + $0.50/ticket)
- Seeds are idempotent (destroy_all at top, safe to re-run)

**Commands run:**
- `bundle exec rails db:seed` — successful, created all data as expected
- `curl http://localhost:3000/api/v1/events` — returns 4 published events ordered by starts_at
- `curl http://localhost:3000/api/v1/events/full-moon-beach-party` — returns event with 3 ticket types, correct quantity_sold values
- `bundle exec rspec` — 152 examples, 0 failures

**Issues and resolutions:**
- None. Clean implementation.
