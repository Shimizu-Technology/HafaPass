# 🎟️ HafaPass

**Guam's Hospitality Ticketing Platform** — powered by Ambros Inc.'s venue network.

## Overview

HafaPass is a ticketing platform designed for Guam's hospitality industry. It enables venues, clubs, and event organizers to create events, sell tickets, and check in attendees via QR code scanning.

## Tech Stack

- **Backend:** Ruby on Rails 8 API
- **Frontend:** React 18 with Vite
- **Authentication:** Clerk
- **Database:** PostgreSQL
- **Payments:** Stripe
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
├── potential.md             # Full PRD & database schema
├── COMPETITIVE_ANALYSIS.md  # Market research
├── FUTURE_IMPROVEMENTS.md   # Technical debt & roadmap
└── screenshots/             # Visual verification screenshots
```

## Getting Started

### Prerequisites

- Ruby 3.2+ and Rails 8+
- Node.js 18+
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

5. **Start background jobs** (optional, in another terminal)
   ```bash
   cd hafapass_api
   bundle exec sidekiq
   ```
   > Note: Without Sidekiq running, emails are processed inline (synchronously). With Sidekiq + Redis, emails are processed asynchronously for better performance.

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

**Without Redis:** Falls back to inline processing (synchronous).

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

### Frontend (`hafapass_frontend/.env.local`)
| Variable | Required | Description |
|----------|----------|-------------|
| `VITE_CLERK_PUBLISHABLE_KEY` | Yes | Clerk publishable key |
| `VITE_API_URL` | No | API base URL (default: http://localhost:3000/api/v1) |

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
# Backend - RSpec (152 specs)
cd hafapass_api
bundle exec rspec

# Frontend - ESLint
cd hafapass_frontend
npm run lint

# Frontend - Production build
cd hafapass_frontend
npm run build
```

## Production Checklist

### Required for Launch

| Item | Status | Notes |
|------|--------|-------|
| Stripe API keys | ⚪ Configure | Set `STRIPE_SECRET_KEY`, `STRIPE_PUBLISHABLE_KEY`, `STRIPE_WEBHOOK_SECRET` |
| Redis | ⚪ Configure | Set `REDIS_URL` for background jobs |
| CORS origins | ⚪ Configure | Set `ALLOWED_ORIGINS` to production domains |
| Database | ⚪ Configure | Set `DATABASE_URL` (Neon or similar) |
| Clerk production | ⚪ Configure | Switch to production Clerk instance |
| Domain & SSL | ⚪ Configure | Point domain to deployed services |

### Optional Enhancements

| Item | Status | Notes |
|------|--------|-------|
| AWS S3 uploads | ⚪ Optional | Set S3 credentials for image uploads |
| Resend emails | ⚪ Optional | Set `RESEND_API_KEY` for real emails |
| Monitoring | ⚪ Recommended | Add Sentry for error tracking |

### Deployment

- **Backend:** Deploy to Render, Railway, or Heroku
- **Frontend:** Deploy to Netlify or Vercel (SPA routing configured via `_redirects`)
- **Sidekiq:** Run as separate worker process in production

## License

Proprietary - Shimizu Technology LLC

---

*"We're not building a GuamTime competitor. We're building the ticketing arm of Guam's hospitality network."*
