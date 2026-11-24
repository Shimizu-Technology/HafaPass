# Single-service durable runtime

Status: implementation and local verification are separate from hosted deployment and provider acceptance. The initial target is one Render `0.5c-512mb` API ($7/month), using the separate managed PostgreSQL database. No paid Redis, worker or clock is created by `render.yaml`.

## Select the owner

`HAFAPASS_RUNTIME=embedded` uses pinned Solid Queue 1.7.0, `plugin :solid_queue` and `solid_queue_mode :async`. These APIs are present in the released gem, not only its main branch. One Puma process shares its heap with Solid Queue's supervised worker, dispatcher and scheduler; job concurrency is one. Queue/delayed/retry state is persisted in the normal application database. This is not Active Job's in-memory async adapter or an untracked thread.

`HAFAPASS_RUNTIME=solid_queue` keeps the same queue/backend but starts no supervisor inside Puma. A later separately supervised `bundle exec bin/jobs` consumes those records and owns scheduling. `HAFAPASS_RUNTIME=sidekiq` retains the explicit Redis/Sidekiq/separate-clock alternative. The old clock refuses to start in either SQL mode. Do not run two authorities, silently switch adapters with undrained jobs, or enable a second cron.

The default remains Sidekiq for existing environments; the initial Render contract explicitly opts into embedded staging. All production provider, policy, organizer, event and financial gates remain enforced. Staging isolation and controlled Stripe/Resend rehearsal rules remain enforced.

## Capacity and progress

Start with three request threads, one job thread and `DB_POOL=10`, covering shared web/job work, polling, dispatch, scheduling and heartbeats. Polling is five seconds, dispatcher batches are 50. Ordinary queue operations and expiry may keep Neon compute active; $7 is the Render API price, not the entire infrastructure bill.

Recurring jobs expire inventory/seats and recover the outbox every minute, reconcile pending Stripe fees every five minutes, and perform daily retention. Startup schedules the four critical jobs once. PostgreSQL recurring execution uniqueness prevents duplicate scheduled ticks during deployment overlap. Financial/domain locks and immutable provider identities remain the side-effect protection.

Readiness checks real current-release actor heartbeats, successful current-release expiry/recovery ticks (three-minute window), successful fee recovery (seven-minute window), inventory that remains overdue, and ready/claimed work older than five minutes. Embedded checks also bind actors to the current Puma instance so an old process's heartbeat cannot stand in for its replacement. Progress is keyed by task and release; older deployments cannot overwrite the new release's markers. A heartbeat alone does not establish usable execution.

`/up` bypasses database-backed throttles and does not query dependencies. The deeper readiness endpoint can return 503 while `/up` remains 200. The supervisor itself requires database access on boot; a failed queue boot is not a usable release.

## Puma processes and event-week settings

`WEB_CONCURRENCY` sets the number of Puma processes and defaults to 1. With 1, Puma runs in single mode exactly as before: the right setting for the 512 MB plan. With 2 or more, Puma runs in cluster mode with `preload_app!`. Each process has its own GVL, so a 2-CPU plan runs requests in parallel, and the service has `WEB_CONCURRENCY × RAILS_MAX_THREADS` request threads in total. Extra processes do **not** isolate lock waiters. Checkouts for one event wait on that event's inventory lock, each waiting checkout holds a request thread, and Puma's shared listening socket hands checkouts to every worker, so a rush can still fill every thread in every process. Bounding concurrent checkouts per event (admission control or a waiting room) is the fix for that, and is not built yet.

The embedded Solid Queue supervisor runs **once per Puma instance**. In single mode the plugin's `after_booted` hook starts it in the only process, as before. In cluster mode `config/puma.rb` starts it in request worker 0 (`before_worker_boot`) and stops it in that worker's `before_worker_shutdown`; the master runs no job threads. That matters on worker respawn: when a worker dies (OOM, timeout, `SIGKILL`), Puma forks the replacement from the master, and `fork()` copies only the calling thread. A master running Solid Queue threads could pass the new worker a mutex (connection pool, logger, libpq) held by a thread that no longer exists, and the worker would hang. With no job threads in the master, every respawn forks cleanly. The master also closes its preload connections in `before_fork`; each worker's pools are discarded at fork by Active Record's fork tracker and reconnect on first use.

If worker 0 dies, jobs pause until Puma respawns it (normally seconds). The replacement starts a new supervisor. The dead one's rows stop counting for readiness after 90 seconds and are pruned with their claimed jobs, the same as after a crash in single mode. There is still one worker, one dispatcher and one scheduler, so no duplicate recurring ticks. `config/puma.rb` fixes `RuntimeConfiguration.instance_id` before forking, so every request worker's readiness check matches the supervisor's heartbeats. `spec/config/puma_cluster_spec.rb` boots two workers, checks both, then kills each worker and checks the respawn. For a long-term clustered setup, prefer `HAFAPASS_RUNTIME=solid_queue` with a dedicated `bin/jobs` worker (`render.tournament.yaml`), which keeps job threads out of the web service entirely.

Each process has its own pool of `DB_POOL` connections, opened only as needed. Request workers use up to `RAILS_MAX_THREADS` connections each, and worker 0's supervisor about six more. The master holds none after forking. Peak use is about `WEB_CONCURRENCY × RAILS_MAX_THREADS + 6`; the pool ceiling is `WEB_CONCURRENCY × DB_POOL` in cluster mode. `DB_POOL` must still cover `RAILS_MAX_THREADS + 6` (boot refuses less). During a Render zero-downtime deploy, the old and new instances overlap briefly, so the ceiling doubles for that window, plus one direct connection for `bin/release-migrate`.

| Use | Render plan | `WEB_CONCURRENCY` | `RAILS_MAX_THREADS` | `DB_POOL` | Peak / ceiling connections |
| --- | --- | --- | --- | --- | --- |
| Normal weeks (`render.yaml`) | Starter `0.5c-512mb` | unset (1) | 3 | 10 | ~9 / 10 |
| Sales open and event week | Standard (1 CPU, 2 GB) | 2 | 5 | 11 | ~16 / 22 (44 during a deploy) |
| Sales open, if Standard is CPU-bound | Pro / `2c-4g` (2 CPU, 4 GB) | 3 | 5 | 11 | ~21 / 33 (66 during a deploy) |

Keep `HAFAPASS_RUNTIME=embedded` for all three. On a 1-CPU plan, a second process adds request threads but no CPU. Move to the 2-CPU plan if Render shows CPU pinned during the rush. Check Neon's `max_connections` for the minimum compute size in the console and keep the ceiling well below it. Use the pooled endpoint for the service. For the sales-open window, raise Neon's minimum compute and turn off scale-to-zero, so the first buyers do not wait for a cold start. Return to the Starter row after the event. In cluster mode, restart with a redeploy or `SIGTERM`; do not rely on `bin/rails restart` (`tmp/restart.txt`).

Rollback: unset `WEB_CONCURRENCY` (or set it to 1) and redeploy. The service returns to single mode with no data or queue migration. `HAFAPASS_PUBLIC_EVENT_CACHE=off` turns the public event cache off with an environment change and restart, without a code change.

## Recovery boundaries

Confirmation, refund, transfer, waitlist offer/notification, guest-list and event-change outbox records commit with their domain state. Their operation keys prevent duplicate intent creation. Enqueue can still be interrupted after that commit; the bounded recovery job locates missing entries using the journal. Scheduled reminder/campaign recovery matches the current scheduled timestamp, so an obsolete future job cannot suppress an earlier reschedule.

Solid Queue records jobs killed while claimed as failed. Recovery retries only the enumerated idempotent/read-only job classes interrupted by process pruning, missing processes or terminated threads. It does not requeue arbitrary failed charges, refunds or payouts. The immutable MessageDelivery request/provider/key, lease, original acceptance marker and 23-hour replay fence remain authoritative. Expired uncertainty requires reconciliation; disabling real transport cannot turn it into simulated success. Automatic outbox recovery stops after five recorded attempts; support must investigate exhausted entries.

Eligibility is filtered before the 50-row recovery limit. Unmatched delivery receipts, expired replay fences and ordinary failed jobs cannot block later eligible work. Accepted provider receipts reconcile without sending another message. Pending payment/refund/cancellation uncertainty and financial reconciliation items retain their existing request/provider-driven or operator resolution paths; this runtime does not invent automatic money replay.

## Deployment and verification

Run the normal release migration through `bin/release-migrate` and the direct database URL matching the pooled endpoint. Preserve the same persistent application/RSA secrets on restart. Do not run sample seeds or copy production data into staging. `render.yaml` configures only the existing API in isolated staging; optional provider rehearsal must be configured privately and explicitly. `render.sidekiq.yaml` is a future alternative, not authorization to create its additional billed resources.

Before acceptance, test queued and delayed work across restart; SIGKILL after a provider accepted but before its response persisted; SIGKILL after domain/outbox commit before enqueue; current-schedule recovery; expired provider fences; overlapping releases; stale/stalled health; and concurrent API traffic during slow provider work. Record the actual Docker limit, peak memory and latency. Local provider-stub proof is not inbox, bank or hosted acceptance evidence.

Local Docker proof used an explicit 512 MB memory/swap limit and 0.5 CPU quota: peak observed memory was 206,594,048 bytes (about 197 MiB). During a 20-second provider SDK stub stall, twelve health requests at concurrency three all returned 200; maximum measured latency was 224 ms. Actual SIGKILL/restart recovered queued and delayed jobs, retained one provider acceptance identity across two attempts, and recovered a completed free order whose confirmation journal committed before enqueue was killed. The private test accelerated the send lease and dead-process heartbeat windows; it did not wait out production timing or contact a real provider. These measurements are bounded local results, not hosted capacity guarantees.

A 512 MB shared process has a common failure domain and only half a CPU. Large exports, manifests, PDFs, campaigns or provider stalls can delay requests and backlog jobs. It is suitable only for bounded testing/pilots after measured acceptance; it is not evidence for large on-sales. Keep alerts for queue age, failed/exhausted deliveries, progress, memory, restarts and API latency. Physical devices, actual network/provider transport and realistic peak traffic remain separate proof.

When growth requires a worker, first extract the same PostgreSQL queue into one dedicated SQL worker, with current-release heartbeats and a coordinated cutover. Switching to Sidekiq is a different queue migration: drain scheduled/ready/claimed jobs, preserve domain journals, verify the new Redis authority and reconcile unresolved provider operations before enabling its scheduler.
