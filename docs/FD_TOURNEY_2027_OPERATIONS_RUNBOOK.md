# FD Alumni Tournament 2027 — Operations Runbook

Operator runbook for the FD Class of 2017 Host Year (Bryan Ho 5K / Beer Mile pilot through June–July 2027 tournament closeout).

Related contracts:
- [Event-Day Operations](EVENT_DAY_OPERATIONS.md) — scanner safety invariants, offline journal recovery, door sales
- [Operations Runbook](OPERATIONS_RUNBOOK.md) — probes, deploy order, rollbacks, CGNAT rate limits, Neon settings
- [Settlement and Payout Operations](SETTLEMENT_AND_PAYOUT_OPERATIONS.md) — statement finalization, manual check payout evidence
- [Single-Service Runtime](SINGLE_SERVICE_RUNTIME.md) — `embedded` vs `solid_queue` worker cutover
- [render.tournament.yaml](../render.tournament.yaml) — June–July peak Render topology template (Leon-gated)
- [load_tests/README.md](../load_tests/README.md) — k6 championship-rush load suite and safety rails

---

## 1. 3-Phone Offline Gate Drill Script (Pre-June 1 Physical Rehearsal at The Jungle)

Run this physical rehearsal at Father Dueñas Memorial School ("The Jungle") before June 1, 2027 using the staging/rehearsal environment and real venue Wi-Fi / Guam cellular networks. Automated tests do not substitute for this drill.

### 1.1 Hardware and Network Setup

| Device | Role | Network Mode | Account & Registration |
|---|---|---|---|
| **Phone A** | Gate 1 (Primary Online Scanner) | Venue Wi-Fi or Guam LTE/5G | Dedicated HåfaPass scanner account #1; registered as `Jungle Gate 1` |
| **Phone B** | Gate 2 + Door Cash Box Office | Venue Wi-Fi or Guam LTE/5G | Dedicated HåfaPass scanner/box-office account #2; registered as `Jungle Gate 2` |
| **Phone C** | Gate 3 (Offline Conflict Phone) | Online for manifest download, then **Airplane Mode** | Dedicated HåfaPass scanner account #3; registered as `Jungle Gate 3 Offline` |

Device prep on all three phones:
- Never share one browser profile or Clerk login across staff accounts.
- Open `/dashboard/scanner` (`ScannerPage`), verify camera permission, tap **Start camera**, confirm **Sound** is unmuted and audible at gym volume, and set Auto-Lock (iPhone) / Screen timeout (Android) to **Never** for the drill.

### 1.2 Pre-Drill Checklist

- [ ] Create rehearsal **Pass Event** with a **Season Pass** (multi-night) and a **2-Night Championship Pass**.
- [ ] Create rehearsal **Daily Night** events (at least Night N and Night N+1) with **Adult Daily**, **Student Daily**, and **Free `$0` Alumni/Kids QR** ticket types.
- [ ] Complete test orders across all four ticket types (Adult Daily, Free `$0`, Season Pass, Championship Pass) plus **1 extra unused Season Pass** reserved for the refund/revocation drill (Step 7).
- [ ] Register Phones A, B, and C for Night N from the Admissions control page and download a fresh signed offline manifest on all three phones.
- [ ] Record baseline manifest state on all three phones before starting:
  - Manifest version: `____________`
  - Manifest downloaded at (`+10:00`): `____________`
  - Eligible unadmitted ticket count: `____________`
  - Queued local scans on Phones A / B / C: `0 / 0 / 0`

### 1.3 Step-by-Step Timed Drill

| Step | Est. Time | Action | Expected Result (Pass Criteria) | Result |
|---|---|---|---|---|
| **1. Paid Adult Daily (Online)** | 1 min | Scan an **Adult Daily** paid QR on **Phone A** (online). | Green full-screen **Admitted** flash + high tone; server-confirmed check-in count increments by `1`. | [ ] Pass / [ ] Fail |
| **2. Free `$0` QR (Online)** | 1 min | Scan a **Free `$0` Alumni/Kids** QR on **Phone A** (online). | Green **Admitted** flash; server-confirmed check-in count increments by `1`. | [ ] Pass / [ ] Fail |
| **3. Season Pass Child vs Parent (Online)** | 2 min | Open the buyer's **Parent Pass** summary, confirm no door QR is shown for the container, and test entering/scanning the raw parent code on **Phone A**. Then scan the **Night N child** QR on **Phone A**. | Parent Pass summary displays no scannable door QR; raw parent code is rejected with `pass_container` ("Multi-night pass containers cannot be scanned directly; scan the ticket for tonight's event"). Night N child QR flashes green **Admitted**. | [ ] Pass / [ ] Fail |
| **4. Championship Pass Child (Online)** | 1 min | Scan the **Championship Pass Night 1 child** QR on **Phone B** (online). | Green **Admitted** flash; count increments by `1`. | [ ] Pass / [ ] Fail |
| **5. Walk-Up `$0` + Cash Box Office** | 3 min | On **Phone B**, open `BoxOfficePage` (`/dashboard/events/:id/box-office`), issue one walk-up **`$0` free QR** and one **`door_cash` Adult Daily** ticket. Scan both newly issued QRs on **Phone A** (online). | Both QRs issue cleanly, `door_cash` appears in the box-office summary, and Phone A flashes green **Admitted** for both (triggering a bounded fresh-list check if not yet in Phone A's manifest). | [ ] Pass / [ ] Fail |
| **6. Offline Duplicate-Scan Conflict** | 4 min | Put **Phone C** into **Airplane Mode**. Scan a fresh **Season Pass Night N child** QR on **Phone A** (online — succeeds). Scan the **exact same Night N child QR** on **Phone C** (offline — queues locally as provisional admit). Reconnect **Phone C** and tap **Sync now**. | Phone A wins admission. Upon sync, Phone C flags a duplicate conflict (`already_admitted`, amber warning "Already admitted on another device"), local queue drains to `0`, and total server-confirmed check-in count for that ticket stays exact `1`. | [ ] Pass / [ ] Fail |
| **7. Revoked / Refunded Pass Child** | 4 min | Keep **Phone C** in **Airplane Mode**. Refund the reserved unused Season Pass from the organizer dashboard. Refresh manifest on **Phone A** and scan that pass's Night N child QR. Then scan the **same refunded pass child QR** on offline **Phone C**; reconnect **Phone C** and tap **Sync now**. | Phone A rejects immediately after manifest refresh (red **Do not admit**). Offline Phone C queues locally, then on reconnect sync flags the action as rejected/conflict (`cancelled` / `refund_pending`) and does **not** increment confirmed check-ins. | [ ] Pass / [ ] Fail |
| **8. Storm Delay Simulation *(Optional)*** | 5 min | Reschedule **Night N+1** to a later date/time in the organizer dashboard. | Pass Event `ends_at` auto-extends to cover the new Night N+1 end time. An informational `pass_event_change` email delivery is logged for pass holders with **no** Accept/Refund CTA. | [ ] Pass / [ ] Fail / [ ] Skipped |

Post-drill verification:
- Confirm all three phones show `0` queued scans, download a fresh manifest, and verify final confirmed check-ins, conflicts, and rejections on the Admissions dashboard match the drill tally.

### 1.4 Printable Go / No-Go Sign-Off Scorecard

| Field | Recorded Value |
|---|---|
| Rehearsal Date & Time (ChST / `+10:00`) | |
| Staging API Revision (`GET /api/v1/health`) | |
| Venue Network Tested (Wi-Fi SSID / Carrier) | |
| Devices Tested (Models & Browsers) | A: ____________________ / B: ____________________ / C: ____________________ |
| Mandatory Steps Passed (Steps 1–7) | ____ / 7 *(7/7 required for Go)* |
| Optional Step 8 (Storm Delay) | [ ] Pass / [ ] Fail / [ ] Deferred |
| Open Issues / Follow-Ups | |
| **Final Decision** | **[ ] GO** &nbsp;&nbsp;&nbsp; **[ ] NO-GO** *(If NO-GO, invoke Section 3 Fallback or schedule re-test)* |
| **Leon (Shimizu Technology) Sign-Off** | Name/Signature: ____________________________ Date: ____________ |
| **CO2017 Gate Lead Sign-Off** | Name/Signature: ____________________________ Date: ____________ |

---

## 2. Sat Mar 6, 2027 — Bryan Ho 5K / Beer Mile Pilot Runbook (First Live CO2017 Event)

**Why this pilot matters:** The Bryan Ho 5K / Beer Mile is the first live Class of 2017 event on HåfaPass. Running it end-to-end 3.5 months before June tip-off proves live Shimizu Stripe collection, custom registration questions and waivers (Slice 3), expanded CSV export (`expand_questions=true`), door cash, QR check-in, and the Shimizu-to-CO2017 Bank of Guam check payout before tournament traffic arrives.

### T-3 Weeks (Mid-Feb 2027 — Leon-Gated)
- [ ] Confirm HåfaPass is unpaused and the `CO2017` organization is active.
- [ ] Verify Stripe live mode, Resend delivery approval, and Clerk production domains (`GET /api/v1/readiness` with `X-Readiness-Token`).
- [ ] Create the **Bryan Ho 5K / Beer Mile** event under `CO2017`.
- [ ] Configure ticket types:
  - **5K Runner**
  - **Beer Mile**
  - **Virtual / Supporter**
- [ ] Configure custom registration questions (shirt size, emergency contact name/phone, Beer Mile 21+ attestation) and attach the event waiver.
- [ ] Assign CO2017 scanner and box-office staff memberships for the event.

### T-1 Week (Late Feb 2027)
- [ ] Run one live `$1` (or isolated test-mode) smoke order → verify confirmation email → test QR check-in → process refund and verify refund confirmation.
- [ ] Test expanded registration CSV export from `AttendeesPage` (`/dashboard/events/:id/attendees`) or `POST /api/v1/organizer/events/:id/sales_exports` with `expand_questions=true` and confirm shirt sizes, emergency contacts, and 21+ attestations export in clean columns for race bib and shirt fulfillment.

### T-1 Day (Fri Mar 5, 2027)
- [ ] Export the final Registration CSV (`expand_questions=true`) and hand off to the race bib / shirt fulfillment lead.
- [ ] Download and print the emergency door list (`GET /api/v1/organizer/events/:id/admissions/door_list` or `GET /api/v1/organizer/events/:id/sales_exports/door_list`) and keep it with the event lead (restricted attendee data).
- [ ] Confirm all race-morning scanner phones are signed into their individual HåfaPass accounts, registered for the event, charged, and have fresh offline manifests downloaded.

### Race Morning (Sat Mar 6, 2027)
- [ ] Run attendee check-in on `ScannerPage` (`/dashboard/scanner`).
- [ ] Process walk-up registrations on `BoxOfficePage` (`/dashboard/events/:id/box-office`) using `door_cash` (or `door_card` **only** if the BOH Clover account shows `verified` and `payment_ready`; otherwise leave card disabled).
- [ ] If cellular signal drops at the start/finish area, continue scanning against the verified offline manifest and tap **Sync now** once connectivity returns.
- [ ] Reconcile the physical cash box against the box-office summary before leaving the site.

### T+1–3 Days (Mar 7–9, 2027)
- [ ] Confirm the event status is `completed` (manual complete in dashboard, or automatic 6 hours after `ends_at` via `CompletePastEventsJob`).
- [ ] Resolve any pending refunds, open disputes, or reconciliation exceptions (`/admin/reconciliation_exceptions`).
- [ ] Finalize the settlement statement (`POST /api/v1/organizer/events/:id/finance/finalize`) and export the sales and finance reports (`orders_export`, `statement_export`).
- [ ] Issue the Shimizu Technology check to the **Class of 2017 Bank of Guam** account and record the confirmed payout via `PATCH /api/v1/admin/payouts/:id` with:
  - `status`: `"paid"`
  - `provider_payout_id`: `CHK-<num>-E<event_id>`
  - `evidence`: `{ reference, confirmed_at, reason }` (matching exact cents)
- [ ] Write a short post-pilot notes list (any check-in, export, registration-form, or payout friction) and resolve items before **April 15, 2027** team registration opens.

---

## 3. Zero-Code Fallback Playbook (Daily + Championship Tickets on HåfaPass, Physical Season Passes at the Door)

### 3.1 Trigger Criteria

Invoke this fallback **before June 1, 2027** if either of the following holds:
1. FDMSAA / CO2017 leadership decides they prefer physical Season Pass wristbands/cards sold at the door instead of digital multi-night passes; or
2. A blocking defect or rehearsal failure affects multi-night passes and cannot be fixed and re-verified on staging before June 1.

This playbook requires **zero code changes** and uses only shipped HåfaPass features.

### 3.2 Zero-Code Setup Steps

1. **Create the tournament series and bulk-clone all nights:**
   - Create the `EventSeries` (`slug: fd-tourney-2027`) in `/dashboard/series` with the agreed 16% FDAA revenue-share settings (`revenue_share_bps`, `revenue_share_base`, `revenue_share_includes_door_cash`).
   - Create one template General Admission regular-night event with **Adult Daily**, **Student Daily**, and **Free `$0` Alumni/Kids/Senior QR** ticket types.
   - Use **Bulk Clone** (`POST /api/v1/organizer/events/:id/bulk_clone`) to generate all **15 regular nights** and **2 championship nights**, and attach them to `fd-tourney-2027`.
2. **Reserve physical Season Pass capacity on every night:**
   - Set a hard physical Season Pass / wristband cap (for example, `150` wristbands).
   - Lower each night's online `max_capacity` in HåfaPass by that exact cap (`venue_limit - physical_pass_cap`, e.g., `venue_limit - 150`) so combined physical + digital headcount never exceeds gym safety capacity.
3. **Track physical Season Pass sales (choose one before doors open):**
   - **Option A (Inside HåfaPass reporting):** Create one dedicated `$0`-fee / `door_cash` tracking event (e.g., *FD 2027 Physical Season Passes*) linked to `fd-tourney-2027` with series membership role `pass_sale` (`Pass Sales`). Record door wristband sales via `BoxOfficePage` (`door_cash`) so they roll directly into `EventSeriesReport`.
   - **Option B (Outside HåfaPass):** Track physical wristband sales offline on the CO2017 board ledger and add that total to the FDAA revenue-share worksheet at tournament closeout.
4. **Reconcile the 16% FDAA revenue share:**
   - Pull `EventSeriesReport` (`GET /api/v1/organizer/event_series/:id/report` and CSV `GET /api/v1/organizer/event_series/:id/report_export`).
   - Use `door_cash_retained_cents` and `net_platform_payable_cents` to reconcile cash retained by CO2017 at the gate against net platform proceeds payable by Shimizu Technology.
5. **Run dual-lane gate operations:**
   - **Physical pass holders:** Visual wristband/card check by gate staff (plus clicker count if tracking live gym occupancy).
   - **Online Daily, Free `$0` QR, and Championship ticket holders:** Standard HåfaPass QR scan on `ScannerPage` with offline manifest fallback ready.

---

## 4. Production Activation & Release Checklist (Leon-Gated Handoff)

> **LEON-GATED ONLY — NEVER RUN AUTOMATICALLY.** Every deployment, production database change, environment variable change, Render tier upgrade, and Netlify publish below requires explicit execution or approval by Leon.

### 4.1 Deploy Order (`docs/OPERATIONS_RUNBOOK.md`)

1. **Fast-forward staging/deploy branch:** Push the target `main` release SHA to `hafapass-staging` (fast-forward only from `05a81ddb`):
   ```bash
   git push origin <release-sha>:hafapass-staging
   ```
2. **Verify staging deploy and migrations:**
   - Confirm pre-deploy `bin/release-migrate` succeeds cleanly.
   - Verify `GET /up` returns `200`, `GET /api/v1/health` reports the new `revision`, and `GET /api/v1/readiness` returns `200` (check full detail with `-H "X-Readiness-Token: $READINESS_TOKEN"`).
3. **Run staging championship-rush load test:**
   - Execute `load_tests/fd_championship_rush.js` against the isolated staging target (see Section 5) and confirm all thresholds pass with zero oversells.
4. **Deploy production API (`hafapass-api` on Render):**
   - Pre-deploy `bin/release-migrate` applies the `event_series` and `multi_night_passes` migrations while the previous release continues serving.
   - Confirm `GET /api/v1/health` reports the new `revision` and `GET /api/v1/readiness` returns `200`.
5. **Publish matching Netlify frontend:**
   - In Netlify → Deploys (currently locked at `3c348b06`), publish the build matching the deployed API commit, confirm `/release.json`, and **unlock auto-publishing**.

### 4.2 Organization & Event Activation

- [ ] **Unpause HåfaPass** before mid-Feb 2027.
- [ ] **By Feb 2027 (for Sat Mar 6 pilot):** Create/verify the `CO2017` organization, owner/manager memberships, and Bank of Guam manual-check payout setup.
- [ ] **By Apr 10, 2027 (for Apr 15 team registration open):** Create/verify the `FDAA` organization and staff permissions.
- [ ] **Providers & auth:** Verify Stripe live mode (`STRIPE_LIVE_*` + live webhook), Clerk production domains (`CLERK_AUTHORIZED_PARTIES`), and Resend delivery/webhook approvals.
- [ ] **FDAA 16% revenue share:** Confirm `revenue_share_bps` (`1600`), `revenue_share_base` (`admissions_net_proceeds` / `admissions_gross` / `admissions_net_after_processing` / `all_net_proceeds`), `revenue_share_includes_door_cash`, and payout direction with FDAA/CO2017 treasurers before opening sales.

### 4.3 June–July Peak Topology & August Scale-Down (`render.tournament.yaml`)

Before June 1, 2027 (peak tournament window):
- [ ] **Enable multi-worker Puma if using `WEB_CONCURRENCY=2`:** Update `hafapass_api/config/puma.rb` from pinned `workers 0` to `workers ENV.fetch("WEB_CONCURRENCY", 0).to_i` before setting `WEB_CONCURRENCY=2` live.
- [ ] **Scale `hafapass-api`:** Upgrade plan to `standard` (1 CPU / 2 GB RAM; use `pro` 2 CPU / 4 GB RAM if Section 5 k6 results show CPU saturation). Set `HAFAPASS_RUNTIME=solid_queue`, `WEB_CONCURRENCY=2`, `RAILS_MAX_THREADS=5`, `DB_POOL=15`.
- [ ] **Add dedicated `hafapass-worker`:** Create `starter` (`0.5c-512mb`) background worker running `bundle exec bin/jobs` with `HAFAPASS_RUNTIME=solid_queue` and `DB_POOL=10`. Confirm Neon pool headroom covers `2 * 15 + 10 = 40` max connections across web + worker.
- [ ] **Apply Guam CGNAT / gym Wi-Fi ceilings** from `render.tournament.yaml`:
  - `HAFAPASS_MAX_HELD_TICKETS_PER_IP=250`
  - `RACK_ATTACK_REQ_PER_IP_5M=3000`
  - `RACK_ATTACK_ORDERS_PER_IP_1M=200`
  - `RACK_ATTACK_MARKETPLACE_LANDING_PER_IP_1M=600`
  - `RACK_ATTACK_MARKETPLACE_FUNNEL_PER_IP_1M=600`
  - `RACK_ATTACK_USERS_SYNC_PER_IP_1M=120`
  - `RACK_ATTACK_PAYMENT_RESUME_PER_IP_1M=120`
- [ ] **Neon PostgreSQL:** Disable scale-to-zero for the June–July tournament window so cold compute starts do not stall championship-rush checkouts. Confirm paid plan PITR (>= 7 days) and run the quarterly restore drill in `docs/OPERATIONS_RUNBOOK.md`.

Post-tournament scale-down (August 2027):
- [ ] Wait for all events to complete, 30-day reserve release, and final check payout recorded with `CHK-<num>-E<event_id>`.
- [ ] Confirm Solid Queue ready/claimed/failed backlog is `0` (`solid_queue_ready_executions`, `solid_queue_failed_executions`).
- [ ] Remove `hafapass-worker`, switch `hafapass-api` back to `HAFAPASS_RUNTIME=embedded` (`DB_POOL=10`, `RAILS_MAX_THREADS=3`, `0.5c-512mb` per `render.yaml`), and re-enable baseline Neon compute settings.

---

## 5. Championship-Rush Load Test Results (Staging k6 Benchmark)

**Status:** _Pending — populate with Slot A k6 benchmark output once `main` is deployed to an isolated staging target._

### Re-Run Command (Isolated Staging Target Only)

`load_tests/fd_championship_rush.js` refuses production hostnames and any API reporting `payment_mode == "live"`. Seed `[LOAD TEST]` free and paid fixtures on staging first (see `load_tests/README.md`), then run:

```bash
ISOLATED_LOAD_TARGET_ACK=I_ACKNOWLEDGE_THIS_CREATES_TEST_ORDERS_IN_AN_ISOLATED_ENVIRONMENT \
SCENARIO=both \
BASE_URL=https://<isolated-staging-host> \
ORG_SLUG=<staging-org-slug> \
SERIES_SLUG=<staging-series-slug> \
DIST_CODE=<staging-dist-code> \
EVENT_SLUG=<load-test-free-event-slug> \
TICKET_TYPE_ID=<free-ticket-type-id> \
PAID_EVENT_SLUG=<load-test-paid-event-slug> \
PAID_TICKET_TYPE_ID=<paid-ticket-type-id> \
FREE_VUS=150 \
PAID_VUS=40 \
SHARED_NAT=true \
SUMMARY_OUT=fd-rush-staging-summary.json \
k6 run load_tests/fd_championship_rush.js
```

### Recorded Benchmark Summary

| Run Metadata | Value |
|---|---|
| Run Date & Time (ChST / `+10:00`) | _TBD_ |
| Candidate Commit SHA | _TBD_ |
| Target Environment & Topology (`embedded` / `solid_queue` + plan) | _TBD_ |
| Scenario & Concurrency (`FREE_VUS` / `PAID_VUS` / `SHARED_NAT`) | _TBD_ |
| Summary JSON Artifact | _TBD_ |

| Metric / Gate | Target Threshold | Measured Value | Pass / Fail |
|---|---|---|---|
| `http_req_failed` | `0%` | _TBD_ | _TBD_ |
| `rush_unexpected_422` | `0` | _TBD_ | _TBD_ |
| `rush_throttled_429` | `0` | _TBD_ | _TBD_ |
| `rush_server_errors_5xx` | `0` | _TBD_ | _TBD_ |
| `rush_free_order_success` | `> 0` | _TBD_ | _TBD_ |
| `rush_paid_hold_success` | `> 0` | _TBD_ | _TBD_ |
| `rush_events_index_latency` (`p95`) | `<= 300ms` | _TBD_ | _TBD_ |
| `rush_free_order_latency` (`p95`) | `<= 1500ms` | _TBD_ | _TBD_ |
| `rush_paid_hold_latency` (`p95`) | `<= 1500ms` | _TBD_ | _TBD_ |
| Render Peak CPU / RAM (`hafapass-api` / `hafapass-worker`) | Zero OOM / bounded CPU | _TBD_ | _TBD_ |
| Neon Peak Active Connections | `< 40` (`standard` + worker) | _TBD_ | _TBD_ |
| Zero-Oversell SQL Check (`quantity_sold <= quantity_available`) | `0` oversells | _TBD_ | _TBD_ |
| Post-Run Hold Expiry & Solid Queue Drain (10+ min) | `0` stuck holds / `0` failed jobs | _TBD_ | _TBD_ |
