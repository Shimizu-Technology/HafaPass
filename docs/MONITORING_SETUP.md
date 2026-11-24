# Monitoring setup: alerts on your phone, a daily summary, webhook watch

Written 24 November 2026 for the Copa de Marianas on-sale (about 4 January 2027). The code is in the repository. The Sentry rules, the Sentry phone app and the tokens are yours to create; this page lists exactly what to create and how to prove each piece works before sales open.

## What exists

| Piece | Where | What it does |
|---|---|---|
| Sentry, backend and frontend | `config/initializers/sentry.rb`, `src/monitoring.js` | Errors, release, request id. No PII (`TelemetryPrivacy`). Both projects now tag checkout, scanner and box-office paths with `area` (below). |
| `OperationalAlertJob` | every 5 minutes (`config/recurring.yml`) | Turns database counts into Sentry messages with a stable fingerprint `operational-alert/<signal>` and tag `operational_signal`. Counts are kept in `runtime_alert_states`. |
| Stripe webhook watch (new) | `Operations::StripeWebhookHealth` | Two new signals, `stripe_webhook_failures` and `stripe_webhooks_silent`, plus a recovery notice. Uses the existing `webhook_events`, `payments` and `payment_events` tables. |
| Daily summary (new) | `GET /api/v1/ops/summary`, `scripts/fetch_ops_summary.py` | Guam-day sales and health, no buyer data, for the morning brief. |
| Admin page (new) | `/admin/monitoring` | Webhook health, the current summary and a **Send test alert** button. |
| Test alert (new) | admin page, `POST /api/v1/admin/monitoring/test_alert`, `bin/rails "hafapass:monitoring:test_alert[kind]"` | One `[TEST]` event to Sentry, tagged like the real alert. |
| Older checks | `hafapass:daily_summary` rake task (#220), `GET /api/v1/readiness`, the daily production drift check (#189) | Unchanged. The rake task needs a server shell; the new endpoint replaces it for the morning brief. |

## 1. Set these on Render (API service `hafapass-api`)

You set these in the Render dashboard; this change does not touch `render.yaml`.

| Variable | Value | Needed? |
|---|---|---|
| `SENTRY_DSN` | already set for production; set it on staging too | Required for any alert |
| `SENTRY_ENVIRONMENT` | `production` / `staging` | Already used; confirm it is set, the rules filter on it |
| `OPS_SUMMARY_TOKEN` | A long random token **you** create (below) | Only for the daily summary |
| `HAFAPASS_WEBHOOK_FAILURE_THRESHOLD` | default `3` failed receipts | Optional |
| `HAFAPASS_WEBHOOK_FAILURE_WINDOW_MINUTES` | default `15` | Optional |
| `HAFAPASS_WEBHOOK_SILENCE_MINUTES` | default `30`: no receipt of any kind for this long | Optional |
| `HAFAPASS_WEBHOOK_SILENCE_LOOKBACK_MINUTES` | default `360`: how far back to look for paid-but-unconfirmed payments | Optional |
| `HAFAPASS_WEBHOOK_SILENCE_MIN_ATTEMPTS` | default `10` payments started inside the silence window | Optional |

Invalid or zero values fall back to the default. Changing one needs a restart.

Create the token yourself and store it in your password manager. Never paste it into chat or a ticket:

```sh
openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-48
```

To **rotate**, set `OPS_SUMMARY_TOKEN` to `new,old`, update the morning brief, then remove `old`. Tokens shorter than 32 characters are ignored, and with no usable token the endpoint answers 404, as if it did not exist.

## 2. Sentry alert rules

Create these in Sentry, **Alerts → Create Alert**. Sentry's screens change names now and then; the conditions below are what matters. Create them on the backend project unless a rule says otherwise, with `environment` set to `production`. The same rules in a `staging` copy are how you test.

Every rule's action is: **Send a notification to** yourself (member), with the Sentry phone app (section 3). Add a second contact as backup when you have one.

### Tags the code emits

| Tag | Values | Set by |
|---|---|---|
| `area` | `checkout`, `webhook`, `scanner`, `box_office` | API request scope (`MonitoringArea`) and, for the three page areas, the frontend (`checkout`, `scanner`, `box_office`) |
| `integration` + `operation` | `stripe_webhook` + `webhook_processing` | The webhook controller on any processing exception (#220) |
| `operational_signal` | `stripe_webhooks_silent`, `stripe_webhook_failures`, `failed_payment_webhooks`, `open_reconciliation_exceptions`, `failed_background_jobs`, `exhausted_message_deliveries` | `OperationalAlertJob` |
| `operational_state` | `recovered` | Recovery notices (level `info`) |
| `monitoring_test` | `true` | Test alerts only |

### Rules

| # | Rule | Type | Conditions | Frequency |
|---|---|---|---|---|
| R1 | **Stripe webhooks silent or failing** | Issue alert | When: a new issue is created, **or** an issue changes from resolved to unresolved, **or** an issue escalates. If: tag `operational_signal` is one of `stripe_webhooks_silent`, `stripe_webhook_failures`; level is `error`. | Notify at most once every 30 minutes |
| R1b | Same, repeat-proof | Metric alert | Dataset Errors, query `operational_signal:[stripe_webhooks_silent,stripe_webhook_failures]`. Critical when count is above `0` in a 2 hour window. | Fires, and sends **Resolved** two hours after the last event |
| R2 | **Stripe webhook processing exception** | Issue alert | New issue or regression, tags `integration:stripe_webhook` and `operation:webhook_processing` | At most once every 15 minutes (as in the runbook) |
| R3 | **New error on checkout, webhook, scanner or box office** | Issue alert | New issue or regression, level `error` or `fatal`, tag `area` is one of `checkout`, `webhook`, `scanner`, `box_office`. Create it once on the **backend** project and once on the **frontend** project. | At most once every 5 minutes |
| R4 | **Error spike on those paths** | Metric alert | Dataset Errors, query `area:[checkout,webhook,scanner,box_office]`, critical above `5` events in `5 minutes` (warning above `2`). Frontend project: above `20` in `10 minutes`. | Resolves when it drops |
| R5 | **Other operational signals** | Issue alert | New issue or regression, tag `operational_signal` is one of `failed_payment_webhooks`, `open_reconciliation_exceptions`, `failed_background_jobs`, `exhausted_message_deliveries`, level `error` | At most once every 6 hours (the app already repeats at 6 hours) |
| R6 | **Recovered** | Issue alert | Tag `operational_state:recovered` | Email only, not a phone push |
| R7 | Readiness and uptime | Uptime monitor | See `OPERATIONS_RUNBOOK.md`, External alert and uptime setup | Already documented |

**Why R1 has a twin.** One fingerprint means one Sentry issue per signal for all time. An issue rule only notifies when that issue is new, escalates or regresses. If you leave the issue unresolved after the first incident, a second incident next week would stay silent. R1b counts events instead, so it fires every time and sends a Resolved message when it ends. Also set **Project Settings → General → Auto Resolve** to `1 day`, and resolve the issue after you handle an incident. R1 and R1b together mean you get the push either way.

### What the app does so you aren't spammed

- No alert for a quiet night. The silence signal needs evidence: a payment recorded as paid with no `payment_intent.succeeded` webhook after 30 minutes, **or** at least 10 payments started in the last 30 minutes and no webhook of any kind. A few abandoned carts never trip it.
- A standing incident repeats once an hour, not every five minutes. More evidence during the same incident does not send another.
- One `info` recovery message when the count returns to zero. Its fingerprint is separate, so it cannot reopen the alert's issue.

## 3. Getting alerts on your phone

1. Install **Sentry** from the App Store and sign in with the same account that owns the organization.
2. In the app: **Settings → Notifications**, allow push, and turn on **Issue alerts** and **Metric alerts**.
3. In the browser: **User Settings → Notifications → Alerts**. Set **Issue alerts** to email for the HåfaPass projects (email is your backup if push fails).
4. On the iPhone: **Settings → Notifications → Sentry**, allow Time Sensitive Notifications. If a Focus mode silences it, add Sentry as an allowed app so a 3 AM alert gets through.
5. Check it: do section 4 on staging.

## 4. Test every rule safely (staging)

The test alert sends one event titled `[TEST] HafaPass monitoring test alert: <kind>` with the same tag the real alert carries, `monitoring_test=true`, and its own fingerprint `monitoring-test-alert/<kind>`. It never changes `runtime_alert_states`, never touches a real issue, and sends nothing to Stripe or buyers. It needs `SENTRY_DSN`, is admin only, is limited to one send per 30 seconds, and is written to the audit log (`monitoring.test_alert_sent`).

**From the app:** sign in as a platform admin on the staging site, open **Admin → Monitoring & alerts**, pick a kind, press **Send test alert**.

**From a shell** (Render shell on the staging API service):

```sh
bin/rails "hafapass:monitoring:test_alert[stripe_webhooks_silent]"
```

| Test this | Pick kind | Should trigger | Pass when |
|---|---|---|---|
| R1 and R1b | `stripe_webhooks_silent`, then `stripe_webhook_failures` | R1, R1b | Phone push within about two minutes. R1b shows Resolved about two hours later. |
| R2 | `webhook` | R2 and R3 | Push for each (or one, if throttled) |
| R3 | `checkout`, `scanner`, `box_office` | R3 | Push per kind. Backend rule only; test the frontend copy by throwing a test error on staging. |
| R4 | send `checkout` six times, 30 seconds apart | R4 | Push once the sixth lands inside 5 minutes |
| R5 | `failed_payment_webhooks` and the other signal kinds | R5 | Push or email as set |
| Phone path only | `sentry_connectivity` | none (no rule) | Event appears in Issues. Use it to confirm the DSN works before anything else. |

A test issue is a **new issue only the first time** you send that kind. To test the same rule again, resolve the `[TEST]` issue in Sentry first, or the rule will correctly stay quiet. When finished, **resolve and archive the `[TEST]` issues**, so they don't hide a real regression.

For a true end-to-end check of the webhook alert on staging, you can also stop the Stripe test webhook destination for 40 minutes while making 10 test purchases. The silence alert will fire from the real database state. Re-enable the destination and wait for the recovery message.

**Before sales open, do this once on production:** send `sentry_connectivity` from the admin page, then `stripe_webhooks_silent`, and watch your phone. Production tests are clearly labelled `[TEST]`; tell anyone else who gets these alerts first.

## 5. The daily summary for the morning brief

**Mechanism and why.** A read-only HTTPS endpoint with its own token, and a script that prints Markdown.

- The brief runs on your MacBook and has no access to the Render shell, so the old rake task can't serve it, and a shell on production is a bigger key than a summary needs.
- A dedicated bearer token (`OPS_SUMMARY_TOKEN`) opens **only** this endpoint. A leaked token can read aggregate numbers and cannot sign in, sell, refund or change anything.
- No email or SMS leaves the system, and no new outbound integration is needed.

**How it is protected.**

| Control | Detail |
|---|---|
| Auth | `Authorization: Bearer <token>` only. A token in the query string is refused. Missing or wrong → 401. |
| Comparison | SHA-256 digests compared with `secure_compare` against every configured token, so timing reveals nothing. |
| Off by default | No usable token configured → 404. |
| Rate limit | 10 requests per minute per address (`ops-summary/ip`), valid or not. |
| Read-only | Reads run with database writes blocked. `Cache-Control: no-store`. |
| Audit | One JSON log line per request: `ops_summary_read`, outcome (`ok`, `unauthorized`, `not_configured`, `bad_request`), request id, date, client address. Never the token. This is a log line and not an `audit_logs` row because the token has no user to attribute a row to. Search Render logs for `ops_summary_read`. |
| No PII | Counts, money, event titles, ticket type names. No buyer or attendee names, emails, phones, order references, payment or event ids from Stripe. A spec fails if any appear. |

**What it contains** for one Guam day (default yesterday; `?date=YYYY-MM-DD` or `?date=today`): orders, tickets, gross, refunds, fees by kind, door cash against online, the same by event, capacity left on events selling now, readiness checks, Stripe webhook health (last received and processed, failures, silent), job queue depth and age, and the operational signal counts. Orders count on the Guam day they completed; refunds on the day they succeeded. In production, test and simulated Stripe payments are excluded, the same rule as the admin dashboard. Sentry error counts are not included, because that needs a Sentry API token; the brief points you to the Sentry app instead.

**Run it.**

```sh
export OPS_SUMMARY_URL=https://hafapass-api.onrender.com
export OPS_SUMMARY_TOKEN_FILE=~/.config/hafapass/ops-summary-token   # a file you create, mode 600
python3 scripts/fetch_ops_summary.py                 # yesterday, Markdown
python3 scripts/fetch_ops_summary.py --date today    # so far today
python3 scripts/fetch_ops_summary.py --json          # raw
python3 scripts/fetch_ops_summary.py --strict        # exit 1 if anything needs attention
```

Use `OPS_SUMMARY_TOKEN_FILE` rather than putting the token on a command line. The script needs only Python 3, refuses a non-https URL, and never prints the token. For the morning brief, run it once each morning after 06:00 Guam and include the "Needs attention" section first.

## 6. What to do when an alert fires

See **First three actions** in `INCIDENT_RESPONSE.md` and the signal table in `OPERATIONS_RUNBOOK.md`.

## Setup checklist for Leon

- [ ] Create `OPS_SUMMARY_TOKEN` (section 1), store it in your password manager, set it on the production and staging API services.
- [ ] Put the token in a mode-600 file on the MacBook and point the morning brief at `scripts/fetch_ops_summary.py`.
- [ ] Create rules R1, R1b, R2, R3 (backend and frontend), R4, R5, R6 in Sentry, production environment. Copy them to staging for testing.
- [ ] Set Sentry **Auto Resolve** to 1 day on the backend project.
- [ ] Install the Sentry iPhone app, allow push and time-sensitive notifications.
- [ ] Run every test in section 4 on staging, then the two production tests.
- [ ] Record the owner and date next to each rule in the OPERATIONS_RUNBOOK checklist.
- [ ] Confirm `SENTRY_DSN` and `SENTRY_ENVIRONMENT` are set on both API services.
