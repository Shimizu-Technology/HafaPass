# HafaPass - Activity Log

## Current Status
**Last Updated:** 2026-01-24
**Tasks Completed:** 1 / 38
**Current Task:** Task 2 - Initialize React Vite frontend project

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
