# 🎟️ HafaPass

**Guam's Hospitality Ticketing Platform** — powered by Ambros Inc.'s venue network.

## Overview

HafaPass is a ticketing platform designed for Guam's hospitality industry. It enables venues, clubs, and event organizers to create events, sell tickets, and check in attendees via QR code scanning.

## Tech Stack

- **Backend:** Ruby on Rails API
- **Frontend:** React.js with Vite
- **Authentication:** Clerk
- **Database:** PostgreSQL
- **Payments:** Stripe (scaffolded)
- **Styling:** Tailwind CSS

## Project Structure

```
HafaPass/
├── hafapass_api/          # Rails API backend
├── hafapass_frontend/     # React Vite frontend
├── prd.md                 # Product requirements & task list
├── PROMPT.md              # Ralph Wiggum loop instructions
├── ralph.sh               # Autonomous dev loop script
├── activity.md            # Development progress log
└── screenshots/           # Visual verification screenshots
```

## Getting Started

### Prerequisites

- Ruby 3.2+ and Rails 7+
- Node.js 18+
- PostgreSQL
- Claude Code CLI (for Ralph Wiggum loop)
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

5. **Open the app**
   Visit http://localhost:5173

## Development with Ralph Wiggum

This project uses the Ralph Wiggum autonomous development loop. To continue development:

```bash
./ralph.sh 30  # Run 30 iterations
```

The loop will:
1. Pick up the next incomplete task from `prd.md`
2. Implement the feature
3. Verify in browser using agent-browser
4. Commit the changes
5. Log progress to `activity.md`
6. Repeat until complete

## Features

### MVP (Phase 1)
- [x] User authentication (Clerk)
- [x] Organizer profiles
- [x] Event creation and management
- [x] Ticket types with pricing
- [x] Public event listing
- [x] Checkout flow (Stripe scaffolded)
- [x] Digital tickets with QR codes
- [x] QR scanner for check-in
- [x] Organizer dashboard

### Roadmap
- Phase 2: Ambros partner features, promoter splits
- Phase 3: Mobile app, VIP reservations, tourism integrations
- Phase 4: White-label, API, Micronesia expansion

## Environment Variables

### Backend (`hafapass_api/.env`)
| Variable | Required | Description |
|----------|----------|-------------|
| `CLERK_SECRET_KEY` | Yes | Clerk backend API key for JWT verification |
| `CLERK_PUBLISHABLE_KEY` | Yes | Clerk publishable key |
| `DATABASE_URL` | Production | PostgreSQL connection string (uses local DB in dev) |
| `STRIPE_SECRET_KEY` | No | Stripe API key (mock checkout without it) |
| `STRIPE_PUBLISHABLE_KEY` | No | Stripe frontend key |
| `AWS_ACCESS_KEY_ID` | No | S3 upload access key |
| `AWS_SECRET_ACCESS_KEY` | No | S3 upload secret key |
| `AWS_BUCKET` | No | S3 bucket name |
| `AWS_REGION` | No | AWS region (default: us-west-2) |
| `RESEND_API_KEY` | No | Resend email API key |
| `MAILER_FROM_EMAIL` | No | From address for emails (default: tickets@hafapass.com) |

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

## Production TODOs

The following items are scaffolded but require real API keys for production:

1. **Stripe Payments** — Replace mock checkout with real Stripe PaymentIntents. The `StripeService` class and comments in `OrdersController` indicate where to integrate. Add webhook handler for payment confirmation.

2. **AWS S3 Uploads** — Enable real image uploads by configuring S3 credentials. The `S3Service` generates presigned POST URLs. Replace `cover_image_url` text input with drag-and-drop upload component.

3. **Resend Emails** — Enable order confirmation and ticket emails by adding `RESEND_API_KEY`. The `EmailService` already has full HTML templates ready.

4. **Database (Neon)** — Migrate from local PostgreSQL to Neon serverless Postgres for production. Set `DATABASE_URL` environment variable.

5. **Deployment** — Deploy Rails API to Render (or similar), React frontend to Netlify (SPA routing already configured with `_redirects` file). Configure CORS for production domain.

6. **Domain & SSL** — Point custom domain to deployed services. Update `VITE_API_URL` for production API.

7. **Clerk Production** — Switch from Clerk development to production instance. Update keys in environment variables.

## License

Proprietary - Shimizu Technology LLC

---

*"We're not building a GuamTime competitor. We're building the ticketing arm of Guam's hospitality network."*
