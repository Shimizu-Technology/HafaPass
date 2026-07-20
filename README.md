# 🎟️ HafaPass

**Guam's Hospitality Ticketing Platform** — powered by Ambros Inc.'s venue network.

## Overview

HafaPass is a ticketing platform designed for Guam's hospitality industry. It enables venues, clubs, and event organizers to create events, sell tickets, and check in attendees via QR code scanning.

## Tech Stack

- **Backend:** Ruby on Rails 8 API
- **Frontend:** React 18 with Vite
- **Authentication:** Clerk
- **Database:** PostgreSQL
- **Payments:** Provider-neutral local ledger; Stripe sandbox adapter; PayPal/manual payout onboarding paths (see `docs/GUAM_PAYMENT_AND_PAYOUT_DECISION.md`)
- **Background Jobs:** Sidekiq + Redis
- **Rate Limiting:** Rack::Attack
- **Email:** Resend
- **Styling:** Tailwind CSS

## Project Structure

```
HafaPass/
├── hafapass_api/            # Rails API backend
│   ├── app/
│   │   ├── controllers/     # API endpoints
│   │   ├── models/          # ActiveRecord models
│   │   ├── services/        # Business logic (Stripe, Email, S3)
│   │   └── jobs/            # Background jobs (Sidekiq)
│   └── config/
│       └── initializers/    # Sidekiq, Rack::Attack, Pagy, CORS
├── hafapass_frontend/       # React Vite frontend
│   └── src/
│       ├── components/      # Reusable UI components
│       ├── pages/           # Route-level pages
│       └── api/             # API client
├── starter-app/             # Setup guides (Clerk, Stripe, S3, etc.)
├── docs/
│   ├── TICKETING_PLATFORM_BLUEPRINT.md # Authoritative product/engineering requirements
│   ├── PHASE_DELIVERY_PLAYBOOK.md       # Branch, test, review, and merge process
│   └── MVP_TEST_PLAN.md                 # Full pilot manual test gate
├── COMPETITIVE_ANALYSIS.md  # Current market research and positioning
├── FUTURE_IMPROVEMENTS.md   # Pointer to the authoritative roadmap
└── screenshots/             # Visual verification screenshots
```

## Product and Delivery Roadmap

The current application is a strong prototype, not yet a production-safe real-money ticketing platform. Use these documents as the source of truth:

- [Ticketing Platform Blueprint](docs/TICKETING_PLATFORM_BLUEPRINT.md) — what HafaPass is, verified risks, required capabilities, architecture, compliance, metrics, and completion criteria.
- [Phase Delivery Playbook](docs/PHASE_DELIVERY_PLAYBOOK.md) — the exact phase branches, implementation scope, automated/runtime testing, Greptile 5/5 loop, and merge gates.
- [Pilot Manual Test Plan](docs/MVP_TEST_PLAN.md) — the end-to-end release-candidate validation.
- [Competitive Analysis](COMPETITIVE_ANALYSIS.md) — current GuamTime, Ticketmaster, and alternative-platform findings.

## Getting Started

### Prerequisites

- Ruby 3.3.4 and Rails 8+
- Node.js 20.19+
- PostgreSQL
- Redis (for background jobs - optional in development)
- Clerk account with test application

### Setup

1. **Clone the repository**
   ```bash
   git clone <repo-url>
   cd HafaPass
   ```

2. **Copy environment file**
   ```bash
   cp .env.example .env
   # Edit .env with your actual credentials
   ```

3. **Start the backend**
   ```bash
   cd hafapass_api
   bundle install
   rails db:create db:migrate db:seed
   rails server  # Runs on localhost:3000
   ```

4. **Start the frontend** (in another terminal)
   ```bash
   cd hafapass_frontend
   npm install
   npm run dev  # Runs on localhost:5173
   ```

5. **Start background jobs** (in another terminal when testing queued work)
   ```bash
   cd hafapass_api
   bundle exec sidekiq
   ```
   Development uses Rails' in-process async adapter when `REDIS_URL` is absent. Production requires Redis, a separately running Sidekiq worker, and exactly one commerce clock process; it does not silently fall back to non-durable work. The clock enqueues idempotent inventory-hold expiry every minute.

6. **Open the app**
   Visit http://localhost:5173

## Features

### MVP (Phase 1)
- [x] User authentication (Clerk)
- [x] Organizer profiles
- [x] Event creation and management
- [x] Ticket types with pricing
- [x] Public event listing
- [x] Checkout flow with Stripe
- [x] Digital tickets with QR codes
- [x] QR scanner for check-in
- [x] Organizer dashboard
- [x] Promo codes
- [x] Guest list management
- [x] Refund processing

### Infrastructure
- [x] Background job processing (Sidekiq + Redis)
- [x] Rate limiting (Rack::Attack)
- [x] API pagination
- [x] CORS configuration via environment variables

### Roadmap
- Phase 2: Ambros partner features, promoter splits
- Phase 3: Mobile app, VIP reservations, tourism integrations
- Phase 4: White-label, API, Micronesia expansion

## Architecture

### Background Jobs

Emails are processed asynchronously using Sidekiq. Job queues:
- `emails` - Order confirmations, ticket emails, refund notifications
- `default` - General background tasks

Jobs automatically retry with exponential backoff (up to 5 attempts).

Production boot requires `REDIS_URL`. Readiness reports Redis connectivity and whether a Sidekiq process is active.

Commerce-ledger deployment, backfill, reconciliation, and rollback-forward procedures are documented in [docs/COMMERCE_LEDGER_OPERATIONS.md](docs/COMMERCE_LEDGER_OPERATIONS.md).

### Rate Limiting

API endpoints are protected by Rack::Attack:

| Endpoint | Limit |
|----------|-------|
| General requests | 300/5 min per IP |
| Order creation | 10/min per IP, 5/min per email |
| Check-in scanning | 60/min per IP |
| Promo code validation | 30/min per IP |

### Pagination

List endpoints return paginated responses:

```json
{
  "events": [...],
  "meta": {
    "current_page": 1,
    "total_pages": 5,
    "total_count": 42,
    "per_page": 20
  }
}
```

Query params: `?page=2&per_page=10`

## Environment Variables

### Backend (`hafapass_api/.env`)
| Variable | Required | Description |
|----------|----------|-------------|
| `CLERK_SECRET_KEY` | Yes | Clerk backend API key for JWT verification |
| `CLERK_PUBLISHABLE_KEY` | Yes | Clerk publishable key |
| `DATABASE_URL` | Production | PostgreSQL connection string (uses local DB in dev) |
| `REDIS_URL` | Production | Redis URL for Sidekiq (e.g., `redis://localhost:6379/0`) |
| `ALLOWED_ORIGINS` | Production | Comma-separated CORS origins (e.g., `https://hafapass.com,https://www.hafapass.com`) |
| `STRIPE_SECRET_KEY` | No | Stripe API key (mock checkout without it) |
| `STRIPE_PUBLISHABLE_KEY` | No | Stripe frontend key |
| `STRIPE_WEBHOOK_SECRET` | Production | Stripe webhook signing secret |
| `AWS_ACCESS_KEY_ID` | No | S3 upload access key |
| `AWS_SECRET_ACCESS_KEY` | No | S3 upload secret key |
| `AWS_BUCKET` | No | S3 bucket name |
| `AWS_REGION` | No | AWS region (default: us-west-2) |
| `RESEND_API_KEY` | No | Resend email API key |
| `MAILER_FROM_EMAIL` | No | From address for emails (default: tickets@hafapass.com) |
| `FRONTEND_URL` | No | Frontend URL for email links (default: http://localhost:5173) |
| `PUBLIC_WEB_URL` | No | Canonical public site URL for SEO and sitemaps (default: https://hafapass.com) |
| `SENTRY_DSN` | Production | Backend error-monitoring DSN |
| `SENTRY_ENVIRONMENT` | No | Monitoring environment label (defaults to Rails environment) |
| `SENTRY_TRACES_SAMPLE_RATE` | No | Backend performance trace sample rate (default: `0.1`) |

### Frontend (`hafapass_frontend/.env.local`)
| Variable | Required | Description |
|----------|----------|-------------|
| `VITE_CLERK_PUBLISHABLE_KEY` | Yes | Clerk publishable key |
| `VITE_API_URL` | No | API base URL (default: http://localhost:3000/api/v1) |
| `VITE_PUBLIC_WEB_URL` | No | Canonical public site URL (default: https://hafapass.com) |
| `VITE_SENTRY_DSN` | Production | Frontend error-monitoring DSN |
| `VITE_SENTRY_ENVIRONMENT` | No | Frontend monitoring environment label |
| `VITE_SENTRY_RELEASE` | Production | Release identifier shared with source-map upload |

## Seed Data

Seed the database with realistic Guam-themed sample data:
```bash
cd hafapass_api
rails db:seed
```

This creates:
- 5 users (2 organizers, 3 attendees)
- 2 organizer profiles (Island Nights Promotions, Guam Beach Club)
- 6 events across categories (nightlife, concert, festival, dining, sports)
- 16 ticket types with varying prices
- 11 orders with 24 tickets
- 4 checked-in tickets

## Testing

```bash
# Full local contract: tests, lint, security, build, audit, and browser smoke
./scripts/gate.sh

# Skip only the browser portion when Playwright is unavailable locally
SKIP_E2E=1 ./scripts/gate.sh
```

The root CI workflow runs the same concerns in parallel. See the [operations runbook](docs/OPERATIONS_RUNBOOK.md) for readiness, worker, monitoring, and incident procedures.

## Production Checklist

Production readiness is defined by the blueprint pilot gate—not by configuring credentials alone. Launch requires, among other items, the immutable commerce ledger, expiring inventory holds, safe webhook/payment transitions, organizer payout architecture, ChST correctness, recoverable guest checkout, offline admissions, durable workers, monitoring, backup/restore proof, security/accessibility testing, and approved legal/accounting policies.

Do not reuse another project’s production credentials. Compatible sandbox credentials may be used locally only under the secret policy in the [Phase Delivery Playbook](docs/PHASE_DELIVERY_PLAYBOOK.md), and every borrowed credential must be replaced with a dedicated HafaPass key before production.

### Deployment

- **Backend:** Deploy to Render, Railway, or Heroku
- **Frontend:** Deploy to Netlify or Vercel (SPA routing configured via `_redirects`)
- **Sidekiq:** Run as separate worker process in production

## License

Proprietary - Shimizu Technology LLC

---

*"We're not building a GuamTime competitor. We're building the ticketing arm of Guam's hospitality network."*
