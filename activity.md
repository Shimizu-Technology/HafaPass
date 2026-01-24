# HafaPass - Activity Log

## Current Status
**Last Updated:** 2026-01-24
**Tasks Completed:** 2 / 38
**Current Task:** Task 3 - Configure Clerk authentication on frontend

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
