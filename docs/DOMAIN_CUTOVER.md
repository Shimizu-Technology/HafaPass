# Changing the public domain

Every domain HåfaPass uses is configuration. Moving the site (for example from
`hafapass.netlify.app` to `https://hafapass.shimizu-technology.com`, or later to
a purchased domain) means changing the environment variables below and
redeploying. No code change is needed. If you find a hardcoded domain, treat it
as a bug.

## What reads which setting

| Where | Variable | Carries | Used for |
|-------|----------|---------|----------|
| Render (API) | `FRONTEND_URL` | Web app origin | Ticket, order, transfer, waitlist, referral and distribution links; Google Wallet origin. Must be HTTPS. Staging and production refuse to boot without it. |
| Render (API) | `PUBLIC_WEB_URL` | Canonical public site | Sitemap entries, share-preview (OG) pages, `/config` `public_web_url`. Must be HTTPS. Staging and production refuse to boot without it. |
| Render (API) | `ALLOWED_ORIGINS` | Comma-separated browser origins | CORS. Required in every deployed environment and must include `FRONTEND_URL`. Only development and test fall back to localhost. |
| Render (API) | `CLERK_AUTHORIZED_PARTIES` | Comma-separated browser origins | Clerk session `azp` check. Optional on staging (falls back to `ALLOWED_ORIGINS`); must be a subset of `ALLOWED_ORIGINS` and include `FRONTEND_URL`. |
| Render (API) | `PUBLIC_API_URL` | API origin | Rails host authorization on staging, readiness checks. Changes only if the API moves. |
| Render (API) | `MAILER_FROM_EMAIL` | Verified sender address | Every outbound email. Required whenever email sending is enabled in a deployed environment. The domain must be verified in Resend. |
| Render (API) | `MAILER_REPLY_TO` | Receiving mailbox | Optional reply-to on outbound email. |
| Render (API) | `PROVIDER_REHEARSAL_EMAIL_RECIPIENTS` | Rehearsal inboxes | Staging email allowlist (only when rehearsal is on). |
| Netlify (build) | `VITE_PUBLIC_WEB_URL` | Canonical public site | Static `og:image`/`twitter:image` and JSON-LD in `index.html`, the `robots.txt` `Sitemap:` line, per-page canonical/`og:url` tags, and in-app share/copy links. Without it, the static absolute tags are left out and the app falls back to the browser origin. |
| Netlify (build) | `VITE_API_URL` | API base including `/api/v1` | Every API call and the PWA "never cache the events list" rule. |
| Netlify (build) | `VITE_SUPPORT_EMAIL` | Support mailbox | Optional override. Normally support links use the admin-managed `SiteSetting` `platform_email`/`platform_phone`, exposed through `/api/v1/config`. With neither set, support links open the in-app ticket recovery page. |
| Netlify (edge functions, runtime) | `HAFAPASS_API_ORIGIN` | API origin without `/api/v1` | Share previews (`/events/:slug` for social crawlers) and the `/sitemap.xml` proxy. Without it, crawlers get the plain SPA and `/sitemap.xml` returns 404. Scope it to the Functions/Edge Functions runtime. |

Data, not environment: the support email and phone are `SiteSetting.platform_email`
and `platform_phone`, which admins manage through the admin settings API.

Outside environment variables, these also carry the domain and must be updated
in their dashboards: Netlify custom domain and HTTPS certificate, DNS records,
Clerk allowed origins/redirect URLs (and a Clerk production instance domain when
live keys are used), Resend sender-domain verification for `MAILER_FROM_EMAIL`,
and Google Wallet allowed origins if Wallet is enabled. The Stripe and Resend
webhook URLs point at the API, so they change only if the API moves.

`config/policies.yml` still names `privacy@hafapass.com` in the privacy policy
text. That text is bound to policy-acceptance digests, so it changes only
through a reviewed policy version.

## Cutover checklist

1. Add the domain in Netlify, wait for HTTPS, and keep the old Netlify URL working.
2. Render: set `FRONTEND_URL` and `PUBLIC_WEB_URL` to the new origin. Add it to
   `ALLOWED_ORIGINS` (and `CLERK_AUTHORIZED_PARTIES` if set), keeping the old
   origin until traffic has moved. Redeploy the API.
3. Netlify: set `VITE_PUBLIC_WEB_URL` to the new origin. Confirm `VITE_API_URL`
   and `HAFAPASS_API_ORIGIN`, then trigger a fresh build. `VITE_` values are baked
   in at build time.
4. Clerk: add the new origin to allowed origins and redirect URLs.
5. Check: `curl -A facebookexternalhit https://<domain>/events/<slug>` returns
   the OG page; `https://<domain>/sitemap.xml` lists `https://<domain>/...`
   URLs; `https://<domain>/robots.txt` names the new sitemap; the rendered
   page's canonical tag uses the new origin; an order email links to the new origin.
6. Once nothing uses the old origin, remove it from `ALLOWED_ORIGINS` and
   `CLERK_AUTHORIZED_PARTIES`.

## Why there is a repository-root `netlify.toml`

The Netlify site builds from the repository root. Netlify only reads a
`netlify.toml` from the base directory or the root, so the frontend's own
config and edge functions were never deployed. The root file sets
`build.base = "hafapass_frontend"`. Netlify then reloads
`hafapass_frontend/netlify.toml` as the effective configuration and finds the
edge functions in `hafapass_frontend/netlify/edge-functions/`. The SPA fallback
stays in `hafapass_frontend/public/_redirects`.
