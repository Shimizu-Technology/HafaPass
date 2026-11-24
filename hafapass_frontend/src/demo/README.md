# Preview demo layer

Everything in `src/demo/` exists only for the Netlify **deploy-preview** (`VITE_HAFAPASS_DEMO_DATA=1`). It lets people click through buyer, organizer, admin, box-office and scanner screens with fictional data. A production build must contain none of it.

## How it works

- `src/api/client.js` swaps Axios' adapter for `demoApiAdapter.js` when the flag is on. No request ever reaches the network.
- `main.jsx` installs a fictional **demo staff** session (`staff/session.js`): a platform admin who is also owner of "Isla Demo Sports League". `ProtectedRoute`, `AdminRoute`, `SupportRoute` and `Navbar` accept it in demo mode only, so staff screens render instead of the sign-in notice. Buyer account pages (`/my-tickets`, `/saved`) still show the sign-in-is-off notice.
- State is in memory (`state.staff`, built by `staff/fixtures.js`). A reload resets it. Nothing is saved anywhere.

## Add a handler (one new file + one line)

1. Create `src/demo/handlers/<feature>.js`:

   ```js
   import { json, created, notFound } from './respond'

   // ctx = { method, path, body, params, config, state, serverNow }
   //   method  lower-case ('get', 'post', ...)
   //   path    without query string or trailing slash, e.g. '/organizer/events/101/waitlist'
   //   params  URLSearchParams from the query string
   //   body    parsed JSON body ({} when none)
   //   state   shared in-memory object; keep yours under state.<feature> = state.<feature> || {...}
   export async function handle({ method, path, body, params, state }) {
     if (method === 'get' && path === '/organizer/example') return json({ items: [] })
     return undefined // not mine: the next handler (or the built-in buyer routes) answers
   }
   ```

   Return `undefined` when the request is not yours. Return `json(data, status?)`, `created(data)`, `notFound()`, `forbidden()` or `unprocessable(message)` otherwise. Status 400 and above reject like a real API error.

2. Register it in `src/demo/handlers/index.js`: add `import * as example from './example'` and one entry in `DEMO_HANDLERS`. Handlers run in list order before the adapter's built-in routes, and `baseline` answers the staff shells (`/me`, organizer events, box office, scanner, finances, admin dashboard and payouts). Put yours before `baseline` only if you need to override one of its routes.

Unknown organizer/admin changes (`POST`, `PUT`, `PATCH`, `DELETE`) return a friendly success marked `demo: true`. Unknown reads return 404 and log `[demo-api] unhandled GET /path` in the console so you can see what to add.

## Fixture rules

- Fictional names, emails (`@example.invalid`) and amounts only. Never real Marianas Open people, real emails, phone numbers or payment details. See `~/Shared-Guidance/skills/product-demo-video/references/data-safety.md`.
- Mark demo events "(demo)" and use the demo organization from `staff/fixtures.js`.
- No real keys, no network calls, no Stripe, no email or SMS.
- Mutations only change `state`. Never `localStorage` beyond the demo session keys.

## Build guard (do not skip)

- Import demo code only behind the literal `import.meta.env.VITE_HAFAPASS_DEMO_DATA === '1'` check (or from a file that is itself only reached that way) so Rollup drops it in production. Do not hide the check behind a helper or variable.
- `src/test/demoBuildGuard.test.js` builds without the flag and fails if any demo string (fixture sentinels, `Isla Demo Sports League`, `demo_staff_user`, `[demo-api]`) is in `dist`, and it refuses a demo build outside the deploy-preview context. If you add a new fixture file, add one distinctive string from it to that list.
