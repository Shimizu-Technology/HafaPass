# Monitoring setup: alerts on your phone, a daily summary, webhook watch

Written 24 November 2026 for the Copa de Marianas on-sale (about 4 January 2027); revised after independent review. The code is in the repository. The Sentry rules, the phone delivery choice and the tokens are yours to create. This page lists exactly what to create and how to prove each piece works before sales open.

**Things I could not verify.** I could not test against a real Sentry project or an iPhone from this environment. Sentry's alert screens change names; the rule recipes below were checked against Sentry's current docs (linked in section 3), and every rule still needs the test in section 5 before you trust it.

## What exists

| Piece | Where | What it does |
|---|---|---|
| Sentry, backend and frontend | `config/initializers/sentry.rb`, `src/monitoring.js` | Errors, release, request id. No PII (`TelemetryPrivacy`). Checkout, webhook, scanner and box-office errors carry the tag `area` (API, including the webhook controller, and frontend). |
| `OperationalAlertJob` | every 5 minutes (`config/recurring.yml`) | Turns database counts into Sentry messages with a stable fingerprint `operational-alert/<signal>` and tag `operational_signal`. State is kept in `runtime_alert_states`. One failing check never stops the others. |
| Stripe webhook watch | `Operations::StripeWebhookHealth`, `Operations::WebhookRejections` | Three signals: `stripe_webhook_failures`, `stripe_unverified_deliveries`, `stripe_webhooks_silent`. Live mode in production, test mode elsewhere. |
| Daily summary | `GET /api/v1/ops/summary`, `scripts/fetch_ops_summary.py` | Guam-day sales and health, no buyer data, for the morning brief. |
| Admin page | `/admin/monitoring` | Webhook health, the current summary and a **Send test alert** button. |
| Test alert | admin page, `POST /api/v1/admin/monitoring/test_alert`, `bin/rails "hafapass:monitoring:test_alert[kind]"` | One `[TEST]` event to Sentry, tagged like the real alert. |
| Older checks | `hafapass:daily_summary` rake task (#220), `GET /api/v1/readiness`, the daily production drift check (#189) | Unchanged. |

## 1. Set these on Render (API service `hafapass-api`)

You set these in the Render dashboard; this change does not touch `render.yaml`.

| Variable | Value | Needed? |
|---|---|---|
| `SENTRY_DSN` | already set for production; set it on staging too | Required for any alert |
| `SENTRY_ENVIRONMENT` | `production` / `staging` | Confirm it is set; the rules filter on it |
| `SENTRY_ENABLED_ENVIRONMENTS` | default `production,staging` | The SDK sends nothing from an environment missing here. The test alert reports this failure instead of pretending it sent. |
| `OPS_SUMMARY_TOKEN` | A long random token **you** create (below) | Only for the daily summary |
| `HAFAPASS_WEBHOOK_FAILURE_THRESHOLD` / `_WINDOW_MINUTES` | default `3` failed receipts in `15` minutes | Optional |
| `HAFAPASS_WEBHOOK_UNVERIFIED_THRESHOLD` | default `3` rejected deliveries in the same window (pages only with missing-delivery evidence) | Optional |
| `HAFAPASS_WEBHOOK_REJECTION_FLUSH_SECONDS` | default `10`: at most one database write per this many seconds per process for rejected-delivery counts; `0` writes through | Optional |
| `HAFAPASS_WEBHOOK_SILENCE_MINUTES` | default `30`: no receipt of any kind for this long | Optional |
| `HAFAPASS_WEBHOOK_SILENCE_LOOKBACK_MINUTES` | default `360`: how far back to look for paid-but-unconfirmed payments | Optional |
| `HAFAPASS_WEBHOOK_SILENCE_MIN_ATTEMPTS` | default `10` payments started inside the silence window | Optional |

Invalid or zero values fall back to the default. Changing one needs a restart.

Create the token yourself and store it in your password manager. Never paste it into chat or a ticket:

```sh
openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-48
```

To **rotate**, set `OPS_SUMMARY_TOKEN` to `new,old`, update the morning brief, then remove `old`. Tokens shorter than 32 characters are ignored, and with no usable token the endpoint answers 404, as if it did not exist.

## 2. What the code watches, and what the alert means

### Tags and signals the code emits

| Tag | Values | Set by |
|---|---|---|
| `area` | `checkout`, `webhook`, `scanner`, `box_office` | API request scope (`MonitoringArea`), the webhook controller's own scope, and the frontend for its checkout, scanner and box-office pages |
| `integration` + `operation` | `stripe_webhook` + `webhook_processing` | The webhook controller on any processing exception (#220) |
| `operational_signal` | `stripe_webhooks_silent`, `stripe_webhook_failures`, `stripe_unverified_deliveries`, `failed_payment_webhooks`, `open_reconciliation_exceptions`, `failed_background_jobs`, `exhausted_message_deliveries` | `OperationalAlertJob` |
| `operational_state` | `recovered`, `quiet`, `check_failed` | Lifecycle notices (level `info`) and a failed check (an exception event) |
| `monitoring_test` | `true` | Test alerts only. Real events never set this tag. |

### The three Stripe webhook signals

Failures and silence look at one Stripe mode: **live in production, test everywhere else**, matched on the `livemode` flag Stripe signs into each event and on each payment's `provider_environment`. Test-mode traffic cannot hide, or cause, a live incident.

- **`stripe_webhook_failures`**: 3 or more receipts failed in 15 minutes, or hung in `processing` for over 10 minutes.
- **`stripe_webhooks_silent`**: both of these count, independently.
  - A payment recorded as paid has no `payment_intent.succeeded` receipt 30 minutes later (looking back 6 hours). Other webhooks arriving does **not** hide it.
  - 10 or more payments started in the last 30 minutes and no webhook of any kind arrived.
  - A quiet night with no buyers has neither, so it never alerts.
- **`stripe_unverified_deliveries`**: **unverified** deliveries were rejected, and real deliveries look missing. A rejected delivery proves nothing about who sent it or in which mode (the signature failed, so its contents can't be trusted, and anyone can post to the public URL). So rejections alone **never page**. It pages only when 3 or more were rejected in 15 minutes **and** no verified receipt has arrived for 30 minutes **while payments were started or a paid payment is still waiting for its success webhook**. That pattern is what a wrong or rotated signing secret looks like. Otherwise the job records one `info` note (`operational_state:note`, at most every 6 hours) and nothing pages. A header that is not Stripe-shaped, or no header, is counted as noise on every code path and never counts toward this.
  - No receipt is stored for rejections, so the app keeps a counter per five-minute bucket (table `webhook_rejection_counts`: a provider, a reason, a time and a number; never a payload, header or address; purged after 7 days).
  - **Write budget.** Counting happens in memory and is written in one statement at most every 10 seconds per process (`HAFAPASS_WEBHOOK_REJECTION_FLUSH_SECONDS`), so a flood of junk costs one small write per interval, not one per request, and cannot take database capacity from real deliveries.

### Incident lifecycle (so the phone stays useful)

- **Opening:** one alert. A new incident that opens after the previous one was closed (a "recovered" or "quiet" message went out) pages again, because you were told it was over. A short storm guard (10 minutes since the last page) defers a very quick re-open, and a deferred incident pages as soon as the guard passes if it still stands.
- **Standing:** a reminder once an hour. More evidence in the same incident does not send another.
- **Clearing:** exactly one `info` message, and it says which of three things happened:
  - **Recovered** (`operational_state:recovered`): the thing that opened the incident was put right after it opened.
    - *Failures:* a receipt was processed after the incident opened **and** none of the incident's failed or hung receipts is still failed.
    - *Silence:* a `payment_intent.succeeded` receipt was processed after the incident opened (a `charge.updated` or other event type does not count) **and** no paid-but-unconfirmed payment from the last 7 days is still waiting for its success receipt. A payment that merely aged out of the 6-hour alert window does not count as fixed.
    - *Unverified deliveries:* a verified delivery (a stored receipt) arrived after the incident opened.
  - **Quiet, not confirmed recovered** (`operational_state:quiet`): the evidence aged out of its window but the cause was not confirmed fixed. The message lists the rows that still need a person. Look at them.
  - **Quiet, cleared before it could be paged** (`operational_state:quiet`, `paged: false`): new evidence appeared and went away inside the storm guard, so it never paged. You are told anyway.
- None of these messages can reopen the alert's Sentry issue (separate fingerprints) or match a `level: error` rule.

## 3. Sentry alert rules

Create these in Sentry under **Monitors > Alerts > Create Alert** ([Sentry docs: Creating an Alert](https://docs.sentry.io/product/monitors-and-alerts/alerts/create-alerts/#if-filters), [Alerts overview](https://docs.sentry.io/product/monitors-and-alerts/alerts/)). The recipe is the same for every rule:

- **Source:** all issues in the HåfaPass API project (a rule per project; the frontend rules use the frontend project).
- **Environment:** `production`. Copy each rule to `staging` for testing (see the one difference below).
- **When (trigger):** only *A new issue is created* and *An event or issue activity is captured* work with tag, level and frequency filters; the Sentry docs say "Frequency and event attribute filters only work with" those two triggers ([If: Filters](https://docs.sentry.io/product/monitors-and-alerts/alerts/create-alerts/#if-filters)). So every rule below uses one of those two, never *A resolved issue regresses* or *An issue escalates* (those can't be combined with tag or level filters).
  - **`operational_signal` rules and W4 use *An event or issue activity is captured*.** The app sends one message per incident hour on a fixed fingerprint, which is **one Sentry issue forever**. A new-issue trigger would notify only the very first incident and stay silent on a second one next week unless you remembered to resolve the issue.
  - **A1 to A4 (the "new error" rules) use *A new issue is created***. This trades coverage: an old issue that was resolved and returns does not re-trigger these. Repeats are covered by the S1 spike rules (event-captured trigger with a frequency filter), and a resolved issue that regresses still sends Sentry's own regression email to project members ([Sentry Notifications](https://docs.sentry.io/product/notifications/)).
- **If (all):** the tag and level filters in the table. Match types available are listed in the same docs (`equals`, `is set`, `is not set`, `is one of`, `does not equal` and others).
- **Then:** *Notify* yourself (member), plus the chat action you choose in section 4. Use *Send Test Notification* on the block to check the integration.
- **Throttling:** per the table. Throttling is per issue.

Every incident rule has the same two exclusions so recovery messages and drills never count as incidents:

- `Event level equals error` (recovery and quiet notices are `info`, so they can't match).
- `Tagged event monitoring_test is not set` (every test alert sets it; real events never do). Use *is not set*, not *does not equal*: it is unambiguous when the tag is missing.

### Production rules (each signal and area has its own rule)

| # | Rule | Extra If filters (on top of the two exclusions) | Throttle |
|---|---|---|---|
| W1 | **Stripe webhooks silent** | tag `operational_signal` equals `stripe_webhooks_silent` | 30 minutes |
| W2 | **Stripe webhook failures** | tag `operational_signal` equals `stripe_webhook_failures` | 30 minutes |
| W3 | **Stripe deliveries rejected while real ones look missing** | tag `operational_signal` equals `stripe_unverified_deliveries` | 30 minutes |
| W4 | **Stripe webhook processing exception** | tag `integration` equals `stripe_webhook` and tag `operation` equals `webhook_processing`. Trigger: *An event or issue activity is captured* (every processing exception notifies, at most once per 15 minutes per issue, as in the runbook). | 15 minutes |
| O1 | Failed payment updates | tag `operational_signal` equals `failed_payment_webhooks` | 6 hours |
| O2 | Open reconciliation exceptions | tag `operational_signal` equals `open_reconciliation_exceptions` | 6 hours |
| O3 | Failed background jobs | tag `operational_signal` equals `failed_background_jobs` | 6 hours |
| O4 | Exhausted email deliveries | tag `operational_signal` equals `exhausted_message_deliveries` | 6 hours |
| A1 | **New error on checkout** | tag `area` equals `checkout`. Trigger: *A new issue is created* only (see above). Create it on the API project and again on the frontend project. | 5 minutes |
| A2 | **New error in the webhook controller** | tag `area` equals `webhook`, API project. Trigger: *A new issue is created* | 5 minutes |
| A3 | **New error on the scanner** | tag `area` equals `scanner`, API and frontend projects. Trigger: *A new issue is created* | 5 minutes |
| A4 | **New error in box office** | tag `area` equals `box_office`, API and frontend projects. Trigger: *A new issue is created* | 5 minutes |
| S1 | **Error spike on checkout** | tag `area` equals `checkout`, trigger *An event or issue activity is captured*, plus *Number of events is more than 5 in 5 minutes* (the issue-level frequency filter). Repeat for `webhook`, `scanner`, `box_office`. On the frontend project use 20 in 10 minutes. | 30 minutes |
| N1 | Recovered / quiet / note messages (not an incident) | Trigger *An event or issue activity is captured*; tag `operational_state` is one of `recovered`, `quiet`, `note` and level equals `info` (this rule does **not** use the two exclusions). **Email only**, not chat push. | 30 minutes |
| D1 | **Drill** (test alerts only) | tag `monitoring_test` equals `true` | none |
| U1 | Readiness and uptime | An external uptime monitor as in `OPERATIONS_RUNBOOK.md` (not a Sentry rule) | n/a |

**The one difference between production and staging:** the staging copy of W1 to O4, A1 to A4 and S1 leaves out the `monitoring_test is not set` filter, so a test alert can drive the real rule. Everything else is identical.

An error rule fires per Sentry issue; a flood of many different errors on one path produces many first-seen alerts, throttled per issue. The S1 spike rules use the *Number of events* frequency filter with a sub-filter on the `area` tag ([Filter by Frequency](https://docs.sentry.io/product/monitors-and-alerts/alerts/create-alerts/#if-filters)); the docs describe it as the issue's event count, so it counts repeats of one issue, not a whole area. I could not verify how it interacts with throttling, so test S1 with the `checkout` kind (section 5).

**Re-checked against the current docs (24 November 2026):** triggers and which filters they allow, the *Tagged event* and *Event level* filters, the match types (`equals`, `is set`, `is not set`, `is one of`, `does not equal`), the "all / any / none" qualifier, *Send Test Notification*, per-issue throttling, the Notify-a-member, Slack and Discord actions. Not verified: how long a rule takes to start matching after you save it, and any plan limits on the number of alerts.

## 4. Getting alerts on your phone: your choice

**Do not use the Sentry mobile app.** Sentry's own repository for it, `getsentry/sentry-mobile-release-health-app`, says in its README "this project is currently not actively maintained. PRs will not be merged." (note added February 2023, last release 2022; see the [repository](https://github.com/getsentry/sentry-mobile-release-health-app)). It is an old Release Health viewer, and nothing in Sentry's current notification docs describes it as an alert channel.

What Sentry's docs do describe: the *Notify a member* action "delivers via each recipient's notification settings" ([Creating an Alert](https://docs.sentry.io/product/monitors-and-alerts/alerts/create-alerts/#if-filters)), set in **User Settings > Notifications** ([Sentry Notifications](https://docs.sentry.io/product/notifications/)); and chat actions for Slack and Discord ([Slack](https://docs.sentry.io/organization/integrations/notification-incidents/slack/), [Discord](https://docs.sentry.io/organization/integrations/notification-incidents/discord/)). The docs do not tell you the default channel for *Notify a member*, so check your own settings and rely on the test, not on a guess.

You need at least one path to your phone. Choose, then run section 5 against it:

**A. Email to your phone (no new accounts, no extra cost).**

1. In Sentry, open **User Settings > Notifications** and confirm alerts go to an email address you read on your iPhone.
2. Send the first test alert (section 5). When the email arrives, open it and **add its sender to your Contacts and mark it VIP** in iOS Mail. I did not verify Sentry's sending address; use the one you actually receive.
3. On the iPhone, allow VIP notifications. Apple: [Set email notifications on iPhone](https://support.apple.com/guide/iphone/set-email-notifications-iphc13a970c8/ios) (Mail notifications for VIPs) and [VIP alerts](https://support.apple.com/en-al/104971). Menu names vary by iOS version; the test is the check.
4. VIP mail pushes to your lock screen like any other mail. Whether it breaks through a Focus mode depends on your Focus settings; check that one yourself.

**B. Slack (a free workspace has an iPhone app with push).**

1. Create or pick a Slack workspace only you (and a backup person) are in. In Sentry, **Settings > Integrations > Slack > Add Workspace**, then in each rule add the Slack action (workspace and channel) next to *Notify member*.
2. In the Slack iPhone app, turn on push for that channel (All messages), and allow Slack notifications on the iPhone.
3. I have not verified Slack's current free-plan limits or Focus behavior; the test is the check.

**C. Discord (free).** Same idea: **Settings > Integrations > Discord**, then the *Send a Discord notification* action in each rule. The channel field needs a channel **ID or URL**, not a name ([Discord docs](https://docs.sentry.io/organization/integrations/notification-incidents/discord/)).

**What you must choose:** A, B, C or a combination (my suggestion: A plus one chat app, so a failed integration does not leave you silent), and who the backup contact is. Tell the agent which, and the rules above get the matching action.

## 5. Test every rule safely (staging, then one production drill)

The test alert sends one event titled `[TEST] HafaPass monitoring test alert: <kind>` with the same tag the real alert carries, plus `monitoring_test=true`, and its own fingerprint `monitoring-test-alert/<kind>`. It never changes `runtime_alert_states`, never touches a real issue, and sends nothing to Stripe or buyers. It needs `SENTRY_DSN`, is admin only, and is limited to one send per 30 seconds.

- **If it fails it says so.** The test alert is sent **synchronously**, not through the SDK's background queue (sentry-ruby returns an event object even when that queue is full and drops the event, so a queued send proves nothing). The admin page says "Sentry accepted the test alert" only after Sentry's server answered success. A network error, a rejected response, an environment not in `SENTRY_ENABLED_ENVIRONMENTS`, or a rate-limited project shows a failure, writes **no audit row** and does not use up the 30-second cooldown. "Accepted" means Sentry has the event; the phone is still the proof the rule and your delivery path work.
- **Button:** sign in as a platform admin, open **Admin > Monitoring & alerts**, pick a kind, press **Send test alert**. Each send is audited (`monitoring.test_alert_sent`).
- **Shell** (Render shell on the staging API service): `bin/rails "hafapass:monitoring:test_alert[stripe_webhooks_silent]"`. Same cooldown and the same failure behavior. One difference: a shell has no signed-in user, so it writes a log line (`monitoring_test_alert`) instead of an audit row.

| Test this | Pick kind | Should fire | Pass when |
|---|---|---|---|
| W1 | `stripe_webhooks_silent` | W1 (staging copy), D1 | Push or email within about two minutes |
| W2 | `stripe_webhook_failures` | W2 (staging copy), D1 | same |
| W3 | `stripe_unverified_deliveries` | W3 (staging copy), D1 | same. To exercise the real path: on staging, put a wrong signing secret, make a test purchase, send a Stripe test event, then restore it. |
| W4 + A2 | `webhook` | W4 and A2 (staging copies), D1 | A push for each, or one if throttled |
| A1, A3, A4 | `checkout`, `scanner`, `box_office` | the matching A rule (staging copy), D1 | Push per kind. For the frontend copies, throw a deliberate test error on staging. |
| S1 | `checkout`, six times 30 seconds apart | S1 (staging copy) | Fires once the sixth lands inside 5 minutes. If it does not, tell the agent so the rule can be changed. |
| O1 to O4 | the matching signal kind | the matching O rule (staging copy), D1 | Push or email |
| Phone path only | `sentry_connectivity` | D1 | Event appears in Issues and reaches your phone |

A test issue notifies on every send with the *event captured* trigger; with a new-issue trigger it notifies only the first time. **Resolve and archive the `[TEST]` issues when finished** so they never get confused with a real incident.

**Production drill, once, before sales open:** send `sentry_connectivity`, then `stripe_webhooks_silent`. Only D1 should reach your phone. W1 must **not** (the exclusion works). Production tests are clearly labelled `[TEST]`; tell anyone else who gets these alerts first.

For an end-to-end check on staging: pause the Stripe test webhook destination for 40 minutes while making 10 test purchases. The silence alert fires from real database state. Re-enable the destination and wait for the "recovered" message. To test W3 for real, put a wrong signing secret on staging, send a Stripe test event, then restore it.

## 6. The daily summary for the morning brief

**Mechanism and why.** A read-only HTTPS endpoint with its own token, and a script that prints Markdown.

- The brief runs on your MacBook and has no access to the Render shell, so the old rake task can't serve it, and a shell on production is a bigger key than a summary needs.
- A dedicated bearer token (`OPS_SUMMARY_TOKEN`) opens **only** this endpoint. A leaked token can read the summary and cannot sign in, sell, refund or change anything.
- No email or SMS leaves the system.

**Treat the token as confidential.** The summary holds no names or emails, but it is confidential sales data. On a small event, a day with one order and one refund reveals that single order. Keep the token in your password manager, never in a repository, chat or ticket, and rotate it (section 1) if it may have been seen.

**How it is protected.**

| Control | Detail |
|---|---|
| Auth | `Authorization: Bearer <token>` only. A token in the query string is refused. Missing or wrong → 401. |
| Comparison | SHA-256 digests compared with `secure_compare` against every configured token, so timing reveals nothing. |
| Off by default | No usable token configured → 404. |
| Rate limit | 10 requests per minute per address, for GET and HEAD alike (`ops-summary/ip`), valid or not. |
| Read-only | The whole read runs with database writes blocked. `/readiness` is not changed; the summary uses a read-only readiness path that skips one check (`provider_policy_controls`, which can activate a due fee change) and reports `health.skipped_checks` so it never claims that check passed. |
| Audit | One JSON log line per request: `ops_summary_read`, outcome (`ok`, `unauthorized`, `not_configured`, `bad_request`), request id, date, client address. Never the token. A log line and not an `audit_logs` row because the token has no user to attribute a row to. Search Render logs for `ops_summary_read`. |
| No PII | Counts, money, event titles, ticket type names. No buyer or attendee names, emails, phones, order references or provider ids. A spec fails if any appear. |

**What it contains** for one Guam day (default yesterday; `?date=YYYY-MM-DD` or `?date=today`): orders, tickets, gross, refunds, fees by kind, door cash against online, the same by event, capacity left on events selling now, readiness checks, Stripe webhook health, job queue depth and age, and the operational signal counts. Orders count on the Guam day they completed; refunds on the day they succeeded. In production, test and simulated Stripe payments are excluded, the same rule as the admin dashboard. Sentry error counts are not included (that needs a Sentry API token).

**Run it.**

```sh
export OPS_SUMMARY_URL=https://hafapass-api.onrender.com
export OPS_SUMMARY_TOKEN_FILE=~/.config/hafapass/ops-summary-token   # a file you create, mode 600
python3 scripts/fetch_ops_summary.py                 # yesterday, Markdown
python3 scripts/fetch_ops_summary.py --date today    # so far today
python3 scripts/fetch_ops_summary.py --json          # raw
python3 scripts/fetch_ops_summary.py --strict        # exit 1 if anything needs attention
```

The script needs only Python 3. It accepts an `https://` URL (plain `http://` only for `localhost`, `127.0.0.1` or `::1`), refuses a URL with a username, password, query or fragment, and **refuses every redirect**, so the token only ever goes to the host you configured. It never prints the token. For the morning brief, run it once each morning after 06:00 Guam and put the "Needs attention" section first.

## 7. Cost of the checks

At 50,000 receipts and 50,000 payments on a test database, each signal's queries took 1 to 11 ms and the whole five-minute job about 30 ms, all by sequential scan; no extra index is needed. Revisit only if the job's duration climbs well past a second.

## 8. What to do when an alert fires

See **Monitoring alerts: what they mean and the first three actions** in `INCIDENT_RESPONSE.md` and the signal table in `OPERATIONS_RUNBOOK.md`.

## Setup checklist for Leon

- [ ] Create `OPS_SUMMARY_TOKEN` (section 1), store it in your password manager, set it on the production and staging API services. Put it in a mode-600 file on the MacBook for the morning brief.
- [ ] Confirm `SENTRY_DSN`, `SENTRY_ENVIRONMENT` and `SENTRY_ENABLED_ENVIRONMENTS` on both API services.
- [ ] Choose your phone path (section 4: email + VIP, Slack, Discord, or a mix) and a backup contact.
- [ ] Create the rules W1 to W4, O1 to O4, A1 to A4, S1, N1 and D1 in Sentry, production environment, with the two exclusions. Copy them to staging without the `monitoring_test` exclusion.
- [ ] Run every test in section 5 on staging, then the production drill.
- [ ] Resolve and archive the `[TEST]` issues.
- [ ] Record the owner and date next to each rule in the OPERATIONS_RUNBOOK checklist.
