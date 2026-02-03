# HafaPass — Future Improvements

_Code review conducted Feb 3, 2026_
_Last updated: Feb 3, 2026_

This document outlines recommended improvements for HafaPass, organized by priority and effort level.

---

## ✅ Completed Items (Feb 3, 2026)

The following high-priority items have been implemented:

| Item | Status | Notes |
|------|--------|-------|
| Background Job Processing | ✅ Done | Sidekiq + Redis, email jobs with retry logic |
| Rate Limiting | ✅ Done | rack-attack with IP/email throttling |
| API Pagination | ✅ Done | Pagy with metadata in response + headers |
| CORS Environment Config | ✅ Done | Uses `ALLOWED_ORIGINS` env variable |
| Color Palette Update | ✅ Done | Warm teal + coral-red (Guam-inspired) |

---

## Priority Legend

| Priority | Meaning |
|----------|---------|
| 🔴 High | Should address before production launch |
| 🟡 Medium | Important for scaling beyond pilot |
| 🟢 Low | Nice-to-have improvements |

---

## 1. Infrastructure & Production Readiness

### ~~🔴 Add Background Job Processing~~ ✅ COMPLETED

**Problem:** Emails are sent synchronously during checkout, which slows down the user experience and risks timeout failures.

**Solution:**
- Add Sidekiq + Redis for async job processing
- Move email sending to background jobs
- Add retry logic for failed jobs

**Files affected:**
- `Gemfile` (add `sidekiq`, `redis`)
- `config/application.rb` (configure ActiveJob adapter)
- `app/services/email_service.rb` (wrap in job)

**Effort:** ~2-4 hours

---

### ~~🔴 Implement Rate Limiting~~ ✅ COMPLETED

**Problem:** API endpoints have no rate limiting, making them vulnerable to abuse and DDoS.

**Solution:**
- Add `rack-attack` gem
- Configure limits per IP and per user
- Add stricter limits on sensitive endpoints (orders, auth)

**Example configuration:**
```ruby
# config/initializers/rack_attack.rb
Rack::Attack.throttle("requests/ip", limit: 300, period: 5.minutes) do |req|
  req.ip
end

Rack::Attack.throttle("orders/ip", limit: 10, period: 1.minute) do |req|
  req.ip if req.path == "/api/v1/orders" && req.post?
end
```

**Effort:** ~1-2 hours

---

### ~~🔴 Add API Pagination~~ ✅ COMPLETED

**Problem:** List endpoints (`/events`, `/orders`, `/attendees`) return all records, which will cause performance issues at scale.

**Solution:**
- Add `kaminari` or `pagy` gem
- Implement cursor-based or offset pagination
- Add pagination metadata to responses

**Endpoints to update:**
- `GET /api/v1/events`
- `GET /api/v1/me/orders`
- `GET /api/v1/me/tickets`
- `GET /api/v1/organizer/events/:id/attendees`
- `GET /api/v1/organizer/events/:id/orders`

**Effort:** ~2-3 hours

---

### ~~🔴 Environment-Based CORS Configuration~~ ✅ COMPLETED

**Problem:** CORS origins are hardcoded in `config/initializers/cors.rb`.

**Current code likely has:**
```ruby
origins 'http://localhost:5173', 'http://localhost:3000'
```

**Solution:**
```ruby
origins ENV.fetch('ALLOWED_ORIGINS', 'http://localhost:5173').split(',')
```

**Effort:** ~30 minutes

---

### 🟡 Add Monitoring & Error Tracking

**Problem:** No visibility into production errors or performance issues.

**Solution:**
- Add Sentry for error tracking (backend + frontend)
- Consider LogRocket or similar for frontend session replay
- Add basic health check endpoint (already exists at `/api/v1/health`)

**Effort:** ~2-3 hours

---

### 🟡 Database Performance Review

**Problem:** May need additional indexes as data grows.

**Recommended indexes to verify:**
```ruby
# Already should exist:
add_index :tickets, :qr_code, unique: true
add_index :events, :slug, unique: true
add_index :events, [:status, :starts_at]
add_index :orders, [:event_id, :status]

# Consider adding:
add_index :orders, :buyer_email
add_index :tickets, [:event_id, :status]
```

**Effort:** ~1 hour (review + add missing)

---

## 2. Security Hardening

### 🔴 Fix SSL Verification in Development

**Problem:** `ClerkAuthenticator` disables SSL verification in development mode, which could accidentally leak to production.

**Location:** `app/services/clerk_authenticator.rb`

**Solution:** Use environment variable check that's explicit:
```ruby
if Rails.env.development? && ENV['DISABLE_SSL_VERIFY'] == 'true'
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE
end
```

**Effort:** ~15 minutes

---

### 🟡 Add Webhook Signature Verification

**Problem:** Stripe webhooks should verify the signature to prevent spoofing.

**Location:** `app/controllers/webhooks/stripe_controller.rb`

**Solution:**
```ruby
def verify_signature
  payload = request.body.read
  sig_header = request.env['HTTP_STRIPE_SIGNATURE']
  endpoint_secret = ENV['STRIPE_WEBHOOK_SECRET']
  
  Stripe::Webhook.construct_event(payload, sig_header, endpoint_secret)
rescue Stripe::SignatureVerificationError
  head :bad_request
end
```

**Effort:** ~1 hour

---

### 🟡 Add Request Validation

**Problem:** Some controllers may not fully validate input parameters.

**Solution:**
- Review all controller actions for proper strong parameters
- Add parameter type validation
- Consider `dry-validation` for complex validations

**Effort:** ~2-3 hours (audit + fixes)

---

## 3. Frontend Improvements

### 🟡 Migrate to TypeScript

**Problem:** No compile-time type safety leads to potential runtime errors and harder refactoring.

**Migration strategy:**
1. Rename `.jsx` → `.tsx` incrementally
2. Start with `src/api/client.ts` and API types
3. Add types for API responses
4. Convert components file by file

**Priority order:**
1. `src/api/client.js` → `client.ts`
2. Create `src/types/` folder with API types
3. Convert pages that handle complex data (CheckoutPage, DashboardPage)
4. Convert remaining components

**Effort:** ~8-16 hours (full migration)

---

### 🟡 Add Data Fetching Library

**Problem:** Manual `useEffect` + `useState` for API calls leads to inconsistent loading states, no caching, and no automatic refetching.

**Solution:** Add React Query (TanStack Query)

**Benefits:**
- Automatic caching and background refetching
- Consistent loading/error states
- Request deduplication
- Optimistic updates for mutations

**Example:**
```typescript
// Before
const [events, setEvents] = useState([]);
const [loading, setLoading] = useState(true);
useEffect(() => {
  apiClient.get('/events').then(res => {
    setEvents(res.data);
    setLoading(false);
  });
}, []);

// After
const { data: events, isLoading } = useQuery({
  queryKey: ['events'],
  queryFn: () => apiClient.get('/events').then(res => res.data)
});
```

**Effort:** ~4-6 hours

---

### 🟡 Add Error Boundaries

**Problem:** React errors crash the entire app with a white screen.

**Solution:**
```jsx
// src/components/ErrorBoundary.jsx
class ErrorBoundary extends React.Component {
  state = { hasError: false };
  
  static getDerivedStateFromError(error) {
    return { hasError: true };
  }
  
  componentDidCatch(error, errorInfo) {
    // Log to Sentry
  }
  
  render() {
    if (this.state.hasError) {
      return <ErrorFallback />;
    }
    return this.props.children;
  }
}
```

**Effort:** ~1-2 hours

---

### 🟡 Add Code Splitting / Lazy Loading

**Problem:** Entire app loads upfront, slowing initial page load.

**Solution:**
```jsx
// src/App.jsx
const DashboardPage = lazy(() => import('./pages/dashboard/DashboardPage'));
const ScannerPage = lazy(() => import('./pages/dashboard/ScannerPage'));

// Wrap routes in Suspense
<Suspense fallback={<LoadingSpinner />}>
  <Routes>...</Routes>
</Suspense>
```

**Effort:** ~2-3 hours

---

### 🟡 Fix location.state Dependency

**Problem:** Some pages rely on `location.state` for data, which is lost on page refresh.

**Affected pages:**
- `CheckoutPage` - receives event data from navigation
- `OrderConfirmationPage` - receives order data

**Solution:**
- Always fetch data from API as fallback
- Use URL params for essential data
- Consider React Query for automatic caching

**Effort:** ~2-3 hours

---

### 🟢 Add Form Validation Library

**Problem:** Manual form validation is verbose and inconsistent.

**Solution:** Add React Hook Form + Zod

```typescript
const schema = z.object({
  email: z.string().email(),
  name: z.string().min(2),
});

const { register, handleSubmit, formState: { errors } } = useForm({
  resolver: zodResolver(schema)
});
```

**Effort:** ~3-4 hours

---

## 4. Testing

### 🔴 Add Frontend Testing Setup

**Problem:** No frontend tests exist.

**Solution:**
1. Add Vitest + React Testing Library
2. Add jsdom for DOM testing
3. Start with critical paths: checkout, auth, scanner

**Files to add:**
```
hafapass_frontend/
├── vitest.config.ts
├── src/
│   └── __tests__/
│       ├── setup.ts
│       ├── CheckoutPage.test.tsx
│       └── components/
│           └── EventCard.test.tsx
```

**Effort:** ~4-6 hours (setup + initial tests)

---

### 🟡 Expand Backend Test Coverage

**Missing test coverage:**
- Stripe webhook handling
- Email service delivery
- Refund flow
- Guest list redemption
- S3 upload presigning

**Effort:** ~4-6 hours

---

## 5. Feature Gaps (From Competitive Analysis)

### 🟡 Offline QR Scanner

**Problem:** Guam venue WiFi is unreliable. Scanner requires network connection.

**Solution:**
- Cache event attendee list in IndexedDB/localStorage
- Queue check-ins locally when offline
- Sync when connection restored
- Use service worker for offline capability

**Effort:** ~8-12 hours

---

### 🟡 Apple Pay / Google Pay

**Problem:** Competitive research showed wallet payments reduce checkout to 10-15 seconds.

**Solution:**
- Add Stripe Payment Request Button
- Already supported by `@stripe/react-stripe-js`

```jsx
import { PaymentRequestButtonElement } from '@stripe/react-stripe-js';

// Check if available
const [paymentRequest, setPaymentRequest] = useState(null);
useEffect(() => {
  const pr = stripe.paymentRequest({
    country: 'US',
    currency: 'usd',
    total: { label: 'Total', amount: totalCents },
  });
  pr.canMakePayment().then(result => {
    if (result) setPaymentRequest(pr);
  });
}, []);
```

**Effort:** ~4-6 hours

---

### 🟢 Dark Mode

**Problem:** Design spec calls for dark mode (nightlife focus) but not implemented.

**Solution:**
- Tailwind already supports dark mode
- Add `dark:` variants to components
- Add toggle in navbar/settings
- Respect system preference

**Effort:** ~4-6 hours

---

### 🟢 Social Proof on Event Pages

**Problem:** Research showed "38 people going" messaging drives conversions.

**Solution:**
- Display attendee count on event pages
- Show profile pictures of attendees (if public)
- "X friends are going" for logged-in users

**Effort:** ~3-4 hours

---

## 6. Developer Experience

### 🟢 Add API Documentation

**Problem:** No API documentation for frontend developers or future integrations.

**Solution:**
- Add `rswag` gem for OpenAPI/Swagger docs
- Generate from RSpec request specs
- Host at `/api-docs`

**Effort:** ~4-6 hours

---

### 🟢 Add Husky + lint-staged

**Problem:** No pre-commit hooks to enforce code quality.

**Solution:**
```bash
npx husky-init && npm install
npx husky add .husky/pre-commit "npx lint-staged"
```

```json
// package.json
"lint-staged": {
  "*.{js,jsx,ts,tsx}": ["eslint --fix", "prettier --write"],
  "*.{json,md}": ["prettier --write"]
}
```

**Effort:** ~1 hour

---

## Summary: Recommended Priority Order

### Before Production Launch (Week 1)
1. ~~🔴 Add background job processing (Sidekiq)~~ ✅ DONE
2. ~~🔴 Implement rate limiting~~ ✅ DONE
3. ~~🔴 Add API pagination~~ ✅ DONE
4. ~~🔴 Fix CORS to use environment variables~~ ✅ DONE
5. 🔴 Add frontend testing setup

### Before Scaling (Weeks 2-4)
1. 🟡 Add monitoring (Sentry)
2. 🟡 Webhook signature verification
3. 🟡 TypeScript migration (start)
4. 🟡 React Query for data fetching
5. 🟡 Error boundaries

### Future Enhancements
1. 🟡 Offline QR scanner
2. 🟡 Apple Pay / Google Pay
3. 🟢 Dark mode
4. 🟢 API documentation
5. 🟢 Form validation library

---

_Last updated: Feb 3, 2026_
