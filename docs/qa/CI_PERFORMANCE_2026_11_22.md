# CI performance measurement, 2026-11-22

Scope: CI-only changes against main `df5deb6aeecd523b3d3113d12e8442013be2242e`.
HafaPass serves event organizers and ticket buyers and processes live payments
(README, Production cutover). No application, payment, secret, or deployment
configuration changes are included. Agent acceptance covers workflow syntax,
conservative documentation filtering, test partitioning and failure propagation.
Full-suite execution and measured improvement remain CI acceptance for the lead.

## Baseline

Measured with `gh run list` and `gh run view --json jobs`; these are the latest
three successful main push runs, excluding scheduled checks and failed runs.
Workflow elapsed includes scheduling delay; job elapsed starts at job start.

| Run | Workflow elapsed | RSpec job | Browser job |
| --- | --- | --- | --- |
| [44236044557](https://github.com/Shimizu-Technology/HafaPass/actions/runs/44236044557) | 10m52s | 10m49s | 8m15s |
| [44233867369](https://github.com/Shimizu-Technology/HafaPass/actions/runs/44233867369) | 14m21s | 11m20s | 8m19s |
| [41791554934](https://github.com/Shimizu-Technology/HafaPass/actions/runs/41791554934) | 11m58s | 11m55s | 8m56s |

Sample median workflow elapsed: **11m58s**, compared with the task's broader
10.9-minute baseline. Median RSpec job: **11m20s**. The latest run spent 10m14s
in RSpec itself, 6m54s in browser tests, and 38s in the PWA step. Other latest-run
jobs took 8–171 seconds. On the two preceding main runs Docker took 113/101
seconds, so it is not currently the critical path.

The latest `rspec-results/rspec.xml` supplies per-file durations in
`scripts/ci_rspec_timings.json`: 3,755 examples across 321 spec files, no failures
or pending examples, 607.5 seconds summed testcase time. Two greedy longest-first
partitions estimate 303.4253 and 303.4255 seconds. Unknown/new files always run
and receive a two-second balancing estimate. Refresh this timing input from a
new complete JUnit result when suite balance changes.

## Changes and coverage proof

- Run two RSpec processes inside the existing required job, each with a separate
  localhost test database. No new dependencies or matrix jobs.
- Discover the full RSpec suite with `--dry-run` before running the partitions.
  Compare its example IDs with the combined worker JSON reports; missing,
  additional, or duplicate IDs fail CI. Worker failures also fail the job.
  Upload discovery, partition, worker JSON and JUnit XML as `rspec-results`.
- Run the existing fully parallel Playwright suite with two workers. Local
  discovery confirms the same **203 unique test IDs** at one and two workers.
  The two production PWA tests stay serial; frontend unit tests are unchanged.
- Preserve every required job name. `gh api` confirmed six required CI names
  plus required CodeRabbit; no protection/ruleset changes. A scope job skips
  heavy jobs only for root/docs Markdown changes; hygiene and release freeze
  still run. Unknown bases and scope failures run the full suite. Rename
  detection is disabled so moving code into a Markdown path cannot hide it.
- Keep existing npm/Bundler caches, cancel superseded PR runs, and bound every
  CI/scheduled job with a timeout. Eight total CI jobs, at most seven concurrently.

Local checks passed: five helper tests (including a fake-bundle subprocess
integration exercising database isolation and failure exit codes), Actionlint
1.7.7, workflow YAML timeout inventory, hygiene, and `git diff --check`.
No application journeys were changed, so browser interaction QA was not run.
No local servers or databases were started.

## Expected result and lead acceptance

Projection: **about 6–7 minutes** without org queueing, allowing setup, serial
discovery, CPU contention and runner variance over the 5m03s partition estimates.
This is not an after measurement. Do not call the target achieved until actual
runs support it.

The lead should verify on the final head:

1. All required full-suite checks and required CodeRabbit complete successfully.
2. RSpec discovery and combined worker reports both contain 3,755 IDs exactly
   once (or explain legitimate changes if main advances). Inspect JUnit totals:
   zero failures/errors and the same total/pending counts as discovery.
3. Browser discovery still contains 203 tests and the PWA suite contains two;
   compare passed/skipped totals with baseline, accounting for existing skips.
   Frontend baseline: 2,237 tests, 2,234 passed and three skipped.
4. Record job and step timings, including queue delay separately. Compare the
   median over several successful runs with the baseline above. Report any
   contention, order dependency, or parallelism failure before merging.

The implementation worker does not watch CI or merge. The branch/worktree is
retained for lead follow-up; no runtime-resource handoff is needed.
