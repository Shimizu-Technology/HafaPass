# 🎟️ HafaPass

**Guam's Hospitality Ticketing Platform** — powered by Ambros Inc.'s venue network.

## Overview

HafaPass is a ticketing platform designed for Guam's hospitality industry. It enables venues, clubs, and event organizers to create events, sell tickets, and check in attendees via QR code scanning.

## Tech Stack

- **Backend:** Ruby on Rails 8 API
- **Frontend:** React 18 with Vite
- **Authentication:** Clerk
- **Database:** PostgreSQL
- **Payments:** Provider-neutral local ledger; Stripe sandbox adapter; PayPal/manual payout paths with fail-closed evidence approval (one administrator may submit and approve) (see `docs/GUAM_PAYMENT_AND_PAYOUT_DECISION.md` and `docs/GATE_B_PAYMENT_READINESS_OPERATIONS.md`)
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

The Phase 0–10 engineering program is merged, but HafaPass is not yet authorized for production real-money ticketing because external approvals and live drills remain open. Use these documents as the source of truth:

- [General-admission testing candidate](docs/LAUNCH_TESTING_CANDIDATE.md) — supported rehearsal, recovery checks, deployment impact, and remaining launch evidence.
- [Private testing staging](docs/PRIVATE_TESTING_STAGING.md) — isolated production-style loading with simulated money and delivery.
- [Ticketing Platform Blueprint](docs/TICKETING_PLATFORM_BLUEPRINT.md) — what HafaPass is, verified risks, required capabilities, architecture, compliance, metrics, and completion criteria.
- [Phase Delivery Playbook](docs/PHASE_DELIVERY_PLAYBOOK.md) — the exact phase branches, implementation scope, automated/runtime testing, CodeRabbit review loop, and merge gates.
- [Platform Completion Audit](docs/PLATFORM_COMPLETION_AUDIT.md) — requirement evidence, market revalidation, honest production-readiness verdict, and ordered launch plan.
- [Release Candidate Operations](docs/RELEASE_CANDIDATE_OPERATIONS.md) — exact-commit Gate A capture, private evidence register, protected-branch freeze, approvals, and immutable candidate tags.
- [Gate D Provider and Policy Evidence](docs/GATE_D_PROVIDER_POLICY_EVIDENCE.md) — fail-closed provider/policy enablement, immutable evidence, independent approval, expiry, configuration binding, and remaining external proof.
- **Selling in production:** an admin verifies each organizer from the admin dashboard (one action, audited) and can pause all of an organizer's sales or a single event. Gates E–J below are optional records; they no longer block publishing or sales. See [Production cutover](docs/PRODUCTION_CUTOVER.md).
- [Gate E Pilot Readiness Evidence](docs/GATE_E_PILOT_READINESS_EVIDENCE.md) — event-bound operating evidence, named command ownership, independent approval, and configuration-drift invalidation (optional record).
- [Gate F Validation Evidence](docs/GATE_F_VALIDATION_EVIDENCE.md) — candidate-bound device, representative-user, accessibility, and expected-onsale load evidence (optional record).
- [Gate G Event-Day Rehearsal Evidence](docs/GATE_G_EVENT_DAY_REHEARSAL_EVIDENCE.md) — candidate-bound signed-manifest, three-device offline, incident, door-sale, staffing, alert, and zero-variance rehearsal evidence.
- [Gate H Low-Value Live-Money Proof](docs/GATE_H_LIVE_MONEY_PROOF.md) — hidden one-use charge authorization plus real refund, settlement, payout, bank-receipt, negative-balance, communication, and cent-exact approval evidence.
- [Gate I Bounded Live-Pilot Operations](docs/GATE_I_BOUNDED_LIVE_PILOT.md) — approved bounded-inventory plan, active sales window, monitoring checkpoints, automatic safety pauses, incident evidence, and reconciled post-event exit.
- [Gate J Pilot Closeout and Expansion Decision](docs/GATE_J_PILOT_CLOSEOUT.md) — exact-state closeout metrics, reconciliation/cleanup evidence, retrospective actions, independent approval, and deliberately bounded Guam-only expansion.
- [Pilot Manual Test Plan](docs/MVP_TEST_PLAN.md) — the end-to-end release-candidate validation.
- [Event-Day Operations](docs/EVENT_DAY_OPERATIONS.md) — signed offline scanning, device drills, door sales, Clover gates, reconciliation, and fallback procedures.
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
   Development uses Rails' in-process async adapter when `REDIS_URL` is absent. Production requires Redis, a separately running Sidekiq worker, and exactly one commerce clock process; it does not silently fall back to non-durable work. The clock enqueues idempotent general-admission and assigned-seat hold expiry every minute and the marketplace retention job daily.

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

### Delivery status and next horizon

- [x] Engineering Phases 0–10: safety foundation, commerce ledger, Guam event integrity, buyer lifecycle, organizations/payout accounting, offline event day, support/compliance surfaces, competitive features, marketplace distribution, and assigned seating.
- [ ] Production release gates: approved Guam payment/payout path, professional policies, dedicated provider configuration, live transaction/reconciliation proof, backup/alert/device/accessibility drills, and named event operations.
- [ ] Evidence-triggered expansion only: complex visual seating provider, high-demand waiting room, season products/memberships, white-label/API, or regional expansion after pilot metrics justify them.

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
| `ALLOWED_ORIGINS` | Staging/production | Comma-separated CORS origins (e.g., `https://tickets.example.com`); required in every deployed environment |
| `STRIPE_TEST_SECRET_KEY`, `STRIPE_TEST_PUBLISHABLE_KEY`, `STRIPE_TEST_PLATFORM_ACCOUNT_ID` | Test payments | Stripe sandbox keys and account ID (simulated checkout without them). `STRIPE_SECRET_KEY`/`STRIPE_PUBLISHABLE_KEY` are a deprecated test-only fallback |
| `STRIPE_WEBHOOK_SECRET` | Test payments | Signing secret of the test-mode webhook endpoint |
| `STRIPE_LIVE_SECRET_KEY`, `STRIPE_LIVE_PUBLISHABLE_KEY`, `STRIPE_LIVE_PLATFORM_ACCOUNT_ID`, `STRIPE_LIVE_WEBHOOK_SECRET` | Live payments | Live keys, account ID and live-mode webhook secret; production only. Admins switch modes in Admin → Settings |
| `ADMISSION_MANIFEST_PRIVATE_KEY_PEM` | Production | Stable RSA private key used to sign offline scanner manifests |
| `CLOVER_REST_PAY_BASE_URL` | Card-present pilot | Approved Clover cloud `/connect` base URL |
| `CLOVER_REST_PAY_ACCESS_TOKEN_ORGANIZATION_<id>` | Card-present pilot | Encrypted Clover OAuth token scoped to one HåfaPass organization |
| `AWS_ACCESS_KEY_ID` | Production | Dedicated private object-storage access key |
| `AWS_SECRET_ACCESS_KEY` | Production | Dedicated private object-storage secret key |
| `AWS_BUCKET` | Production | Private object-storage bucket name |
| `AWS_REGION` | Production | Object-storage region |
| `RESEND_API_KEY` | Production | Resend email API key |
| `RESEND_WEBHOOK_SECRET` | Production email | Resend/Svix webhook signing secret |
| `MAILER_FROM_EMAIL` | Production | Verified from address for emails; required whenever sending is enabled (dev/test use `tickets@example.test`) |
| `MAILER_REPLY_TO` | Support deployment | Receiving operator mailbox for customer replies; optional in code, captured in each saved outbound payload |
| `PROVIDER_CONFIGURATION_REVISION` | Production | Non-secret revision bumped for any provider-side account/domain/webhook/issuer configuration change |
| `FRONTEND_URL` | Staging/production | HTTPS frontend URL for email and share links; the API refuses to boot without it outside development/test |
| `PUBLIC_WEB_URL` | Staging/production | HTTPS canonical public site URL for SEO, sitemaps and share previews; required at boot outside development/test |
| `SENTRY_DSN` | Production | Backend error-monitoring DSN |
| `SENTRY_ENVIRONMENT` | No | Monitoring environment label (defaults to Rails environment) |
| `SENTRY_TRACES_SAMPLE_RATE` | No | Backend performance trace sample rate (default: `0.1`) |
| `GIT_SHA` / `COMMIT_REF` | Production | Exact 40- or 64-hex deployed commit digest; branch names are rejected by readiness |

### Frontend (`hafapass_frontend/.env.local`)
| Variable | Required | Description |
|----------|----------|-------------|
| `VITE_CLERK_PUBLISHABLE_KEY` | Yes | Clerk publishable key |
| `VITE_API_URL` | No | API base URL (default: http://localhost:3000/api/v1) |
| `VITE_PUBLIC_WEB_URL` | Deployment | Canonical public site URL; fills OG image/JSON-LD tags and `robots.txt` at build time, and per-page canonical/share links |
| `VITE_SUPPORT_EMAIL` | No | Optional override for support links; normally they use the admin-managed `platform_email`/`platform_phone` from `/api/v1/config` |
| `VITE_SENTRY_DSN` | Production | Frontend error-monitoring DSN |
| `VITE_SENTRY_ENVIRONMENT` | No | Frontend monitoring environment label |
| `VITE_SENTRY_RELEASE` | Production | Release identifier shared with source-map upload |

Set the support email (admin `platform_email`, or the `VITE_SUPPORT_EMAIL` override) and `MAILER_REPLY_TO` to a mailbox the operator can actually receive and monitor before deploying customer recovery flows. Sender-domain verification for `MAILER_FROM_EMAIL` proves permission to send; it does not create a receiving inbox. These support settings do not create mailboxes or confirm delivery. Email retries retain the reply address saved with the original provider request even after configuration changes. Rebuild the frontend after changing a `VITE_` setting.

Netlify edge functions (share previews and the `/sitemap.xml` proxy) read the API origin from the Netlify environment variable `HAFAPASS_API_ORIGIN`. Every domain is configuration; see [Changing the public domain](docs/DOMAIN_CUTOVER.md) for the full list of settings to change when the site moves. Moving the Render service from staging to production, the test/live payment switch and the synthetic-data purge are covered in [Production cutover](docs/PRODUCTION_CUTOVER.md).

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

The root CI workflow runs the same concerns in parallel. See the [operations runbook](docs/OPERATIONS_RUNBOOK.md) for readiness, worker, monitoring, and incident procedures; [pilot readiness](docs/PILOT_READINESS_RUNBOOK.md) for communications, support, backup/restore, alerts, accessibility, and release drills; and the [professional review register](docs/POLICY_REVIEW_REGISTER.md) for legal/privacy/accounting gates.

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
