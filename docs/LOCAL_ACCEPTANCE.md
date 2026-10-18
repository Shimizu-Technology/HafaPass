# Repeatable local acceptance

Use synthetic data in a separate local PostgreSQL database. The normal `db/seeds.rb` is destructive and is not the acceptance setup. The fixture task below refuses production, staging, remote hosts, a database outside `hafapass_qa_*`, non-simulated payments, and real email transport.

```sh
createdb hafapass_qa_readiness
cd hafapass_api
DATABASE_URL=postgresql://localhost/hafapass_qa_readiness RAILS_ENV=development bundle exec rails db:schema:load
DATABASE_URL=postgresql://localhost/hafapass_qa_readiness HAFAPASS_QA_FIXTURES=1 bundle exec rails qa:seed
```

The fixture task is additive and repeatable. It creates two organizations, 21 paginated events in the first organization, an additional free-registration event, an event in the second organization, 21 simulated purchases, and one organizer-collected cash purchase. The oldest main event has the order history and a scanner assignment. The JSON output gives the relevant event IDs, cash order reference, free-event slug and local user IDs. It contains no passwords or access tokens. Existing fixtures are preserved; use another fixture name or a fresh owned database when a previous journey has changed them.

The five platform users are ordinary organizer/attendee accounts. Owner, scanner and finance permissions come from organization memberships; none is a platform administrator. The scanner is assigned only to the oldest event. This permits a positive assigned-event check and a negative unassigned-event check.

To use actual Clerk authentication, create or select distinct accounts in the existing Clerk **test** instance and supply their subjects before seeding:

```sh
HAFAPASS_QA_ORGANIZER_CLERK_ID=user_your_test_organizer \
HAFAPASS_QA_ATTENDEE_CLERK_ID=user_your_test_attendee \
HAFAPASS_QA_SCANNER_CLERK_ID=user_your_test_scanner \
HAFAPASS_QA_FINANCE_CLERK_ID=user_your_test_finance \
HAFAPASS_QA_OTHER_ORGANIZER_CLERK_ID=user_your_other_test_organizer \
DATABASE_URL=postgresql://localhost/hafapass_qa_readiness \
HAFAPASS_QA_FIXTURES=1 bundle exec rails qa:seed
```

Omitted subjects use synthetic local IDs and cannot sign into Clerk. The task neither creates Clerk accounts nor changes credentials. It rejects a subject reused across roles or an existing account whose platform role differs from the fixture role. Seed before first sign-in, disable first-user admin bootstrap for acceptance, and keep Clerk credentials in the existing private environment. A mocked session does not prove Clerk authentication.

Run the API and Vite on unoccupied task-specific ports. Point `DATABASE_URL` at the fixture database, set `ALLOWED_ORIGINS` and `CLERK_AUTHORIZED_PARTIES` to the exact Vite origin, set `VITE_API_URL` to that API's `/api/v1`, and use `HAFAPASS_LAUNCH_SCOPE=general_admission`. Set `REDIS_URL` empty for development's async queue. Claim each server and browser tab through `dev-lifecycle`; clean only the resources and database created by the task.

## Required journey record

Record commit, environment, role, fixture, device/input method, expected visible and saved outcome, actual result and evidence for each case. Use passed, failed, blocked or not-run. After integration or review fixes, repeat affected cases against the final source.

| Case | Expected outcome |
| --- | --- |
| Organizer event discovery | Find the oldest event through page 2 and search; open a workspace and return with filters/page retained. |
| Scanner context | Open the assigned oldest-event link directly; prepare scanning; search the event picker without changing the prepared event; reload the selected context. |
| Role isolation | Scanner cannot access refunds or unassigned events; the other organizer cannot read the first organization's buyer records. |
| Older refund order | Locate a purchase beyond the newest ten by pagination, reference and buyer search; preserve filters on retry. |
| Cash return record | Record cash already returned with reference, time and reason; reload history and independently verify one refund, actor/evidence, ticket state and cash custody offset. |
| Event editor | Invalid submit focuses an accessible summary; new drafts recover after reload; save/preview/publish use the visible saved version; failed saves retain edits. |
| Free attendee journey | Sign in as an attendee, register, reload the order, view/download tickets, admit once, reject a duplicate and verify the saved admission. |
| Recovery | Exercise a lost/read-failed response and retry without a duplicate order/refund or lost context; simulated email history proves journal behavior only. |
| Layout/accessibility | Repeat relevant cases on desktop and phone widths, keyboard/focus, long content, reduced motion and failure/empty states. |

Browser resizing proves responsive layout. Native keyboard/gesture/camera/installed-app behavior requires a simulator or physical device, and physical venue connectivity requires venue testing. Record those dimensions separately. Simulated messages and payments never establish inbox delivery or bank/provider acceptance.

## Release source and runtime proof

`GET /api/v1/health` returns the backend's validated full `revision`, or `null` when unavailable. This remains a lightweight liveness check. The frontend production build emits `/release.json` with the full revision, or `null`; Netlify's `COMMIT_REF` takes precedence over manual fallback values. The same revision tags frontend error reports. A local build can use Git metadata; source archives may supply `VITE_APP_REVISION` explicitly. An invalid authoritative hosting value stays unknown rather than falling back to a different commit.

After delivery, fetch both artifacts from the actual deployed origins and compare them to the intended commits. A passing CI run or successful deploy command is not evidence that the user-facing build is current. Keep dependency readiness, provider approval and source delivery as separate checks.

The existing [single-service runtime](SINGLE_SERVICE_RUNTIME.md) defines durable-job restart and uncertainty recovery. The [pilot runbook](PILOT_READINESS_RUNBOOK.md) defines backup/restore, alert and load acceptance. Run these against an owned isolated runtime and database; do not restore production data locally or manufacture external approvals. Retain measured limits, failed/not-run cases and actual provider/device boundaries in the release record.
