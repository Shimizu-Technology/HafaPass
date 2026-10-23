# Team permission fixes — execution record

Baseline: main `b4679ad021a4e73e780a44dba033f6edb9352f1d`, October 23, 2026 Guam time. Branch `codex/hafapass-team-permission-fixes`. Hold for lead merge.

HåfaPass serves Guam organizers, event staff and ticket buyers. Clerk authenticates accounts; effective database memberships and event assignments authorize actions. Stripe is live, so this task uses isolated local fixtures and no real payments or outbound email. Sources: `CLAUDE.md`, `app/services/organization_authorization.rb`, `docs/ROLES_AND_ROADMAP.md`, recent main history. Brain Dump `work/shimizu-tech/future-builds.md` confirms purpose but its May launch status is historical; this task uses the supplied live-marketplace context. Deployment remains unchanged until the lead merges.

Acceptance: each of the twelve verified findings has a regression test, role descriptions match enforced permissions, and an independent endpoint-by-role matrix catches permission drift. Organizer actions cannot clear platform restrictions, cross the selected organization's boundary, revoke the effective owner after a transfer, or proceed on lapsed admission/campaign authority. Offline admission stays available with explicit bounded leases. No policies.yml edits or audit-logging refactor.

QA execution owner: agent. Affected-flow scope covers team settings, event team, invitation acceptance and scanner device management at 375 and 1280 CSS pixels, plus saved state and recoverable errors. Browser resizing does not establish physical-device keyboard/gesture behavior. API 3056, Vite 5226, dedicated local database `hafapass_team_fix`; test database `hafapass_team_fix_test`. Existing services, especially 3000/3088/3011, are borrowed.

| Case | Required outcome | 375 | 1280 |
|---|---|---|---|
| TEAM-1 | Invite with role description; save and see pending invite; quota error retains email and role | Passed | Passed |
| TEAM-2 | Change role; show expired access separately; removal explains offline scanner window | Passed | Passed |
| STAFF-1 | Assign event staff, show effective expiry, remove and preserve context | Passed | Passed |
| INVITE-1 | Accept authenticated email invitation, correct organization and assigned-event destination | Passed | Passed |
| SCAN-1 | Register device, see lease/revocation explanation, revoke and reject reconnect/sync | Passed | Passed |

The local gate passed on the complete implementation source tree (committed with this record). The final PR head and remote check/review state are recorded in the implementation handoff and PR. No production deploy was performed.

## Automated evidence

- RSpec: 2,988 examples, 0 failures, including 522 independent endpoint/role contract cases. Log: `/tmp/hafapass-team-rspec-final.log`.
- RuboCop: 906 files, no offenses. Brakeman: no warnings. Bundler Audit and production npm audit: no vulnerabilities.
- ESLint passed. Vitest: 1,817 tests passed in 166 files. Production build passed. Playwright: 110 tests passed. Logs: `/tmp/hafapass-team-vitest-final.log`, `/tmp/hafapass-team-build-final.log`, `/tmp/hafapass-team-playwright-final.log`.
- Tracked secret/debug hygiene and release-freeze contract passed. Impeccable 4.6.0 advisory scan returned `[]` for changed screens.

## Real UI evidence

Chromium, actual Clerk development account and actual Rails API; all data belonged to dedicated local databases. The password flow required MFA, so a short-lived Clerk development sign-in token authenticated the same configured test account without sending an MFA message or changing account settings. No application-auth mock was used. Email transport and payment credentials were disabled; no real money or external invitation email was sent.

The T3 preview snapshot timed out twice (`Preview automation snapshot timed out after 15000ms.`); standalone Playwright was used after the documented fallback threshold. Browser processes were claimed and closed per phase.

- TEAM-1: invited a scanner at each width; saved pending membership verified through authenticated API reads; immediate resend showed the real one-minute cooldown and retained choices.
- TEAM-2: changed a staff member to Box office, verified the saved role, checked ended membership access and Guam-time expiry, read the offline-scanner removal note, removed access and verified saved revocation at each width.
- STAFF-1: checked expired assignment display, assigned accepted event staff, removed the assignment and verified its saved status at each width. Organization context remained intact.
- INVITE-1: accepted a real email-bound invitation, verified the resulting organization selection and assigned-event scanning destination; inspected the same saved success at both widths. Stale account/token/selection/visit outcomes and StrictMode replay are covered separately by Vitest.
- SCAN-1: registered real devices and verified leases no longer than 24 hours plus the event/access bounds. Inspected device guidance at both widths. For reconnect, prepared a scanner, went offline, revoked the owned membership through the real team service, verified the prepared cache remained usable offline, then reconnected: cached trust was withdrawn and a manifest request returned 403 immediately. Reconnect refusal was inspected at both widths. Backend specs also reject queued offline scans after revocation.

Screenshots are local, ignored artifacts under `screenshots/`:

- `team-settings-375.png`, `team-settings-1280.png`
- `team-remove-note-375.png`, `team-remove-note-1280.png`
- `event-team-375.png`, `event-team-1280.png`
- `invitation-accepted-375.png`, `invitation-accepted-1280.png`
- `scanner-device-375.png`, `scanner-device-1280.png`
- `scanner-offline-before-reconnect-375.png`
- `scanner-revoked-reconnect-375.png`, `scanner-revoked-reconnect-1280.png`

Physical-device camera/keyboard/gesture behavior, actual email delivery, live-money actions and production deployment were not run. Resized Chromium establishes browser layout and interaction at the requested widths only.

## Finding disposition

All twelve findings were reverified against the baseline and fixed:

1. Organizer and platform pauses use separate columns; pilot-pause/resume and layered-pause regression specs pass.
2. Ownership mutations and invitation acceptance share the organization lock; stale-target and competing-transfer invariants pass.
3. Guest-list ticket type resolution and model validation reject foreign events/organizations on create and update.
4. Reconciliation mutations are scoped to the selected organization; explicit admin/system operation remains available.
5. Online admission and Undo recheck their exact permissions after lock acquisition.
6. Offline scanning remains available; manifest/device caps and removal/reconnect wording are explicit, and reconnect/sync refusal is verified.
7. Scheduled execution checks current marketing authority; failure persists a visible reason and send-now attribution records the actual sender.
8. Clone/recurrence require organization-wide event management and are hidden from event-only managers.
9. Invitation responses are bound to account, token, route visit and selection; stale outcomes are discarded.
10. Effective expiry and invitation expiry are distinct in team/event UI and API serialization.
11. Membership-free authorized admins receive an event/hard-limit device lease.
12. Durable per-actor/per-team quotas and recipient cooldowns have service and UI regression coverage.

Role descriptions and the supporting role document were corrected. `config/policies.yml` and the audit-logging refactor were left untouched. Existing ambiguous sales-pause records remain platform-protected until an administrator reviews them; the migration deliberately does not guess their origin.

## Review fixes, October 24, 2026

Starting head: `456e03d5a4dfedb20cfe9c2cd2015b3a79a961a5`, PR #152. Verified `origin/main` is already an ancestor, so no merge commit was needed. This round remains held for the lead: **do not merge**. `hafapass_api/config/policies.yml` is unchanged.

The affected users are organization owners, event managers, marketers and invitation recipients. The relevant authority comes from current effective memberships/assignments, not the role the request had before waiting for a lock. Refreshed sources: `OrganizationAuthorization`, `OrganizationTeam`, the campaign sender/delivery job, organizer controllers, and the affected React pages. Brain Dump `work/shimizu-tech/company-positioning-and-project-review-2026-10-04.md` describes HåfaPass as ticketing, admission/offline, refunds/settlements, roles and operations software; its launch gates are historical context, not evidence of deployment in this task.

Acceptance for this round: a completed transfer/revocation prevents later unauthorized team changes or campaign dispatch; event managers retain event-scoped staff operations; open pages update expired access; invitation settlement ends loading while preserving a newer organization; authorized campaign recovery preserves saved content and recipients, can save a draft or a new schedule, and requires a separate action to send immediately.

| GitHub comment | Verified finding and disposition |
|---|---|
| 4360282782 | Fixed. Campaign queueing locks organization before campaign. Delivery dispatch rechecks `requested_by` under that same organization lock through the bounded provider call; revoked senders are cancelled without erasing prior provider uncertainty. Event assignment mutations share the organization boundary because event-manager assignments can confer marketing access. |
| 4360282802 | Fixed. Invite, resend, revoke and role change recheck authority after the organization lock. Staff invitations/resends retain event-scoped `manage_staff`; other membership mutations require `manage_members`. Latch-based PostgreSQL tests exercise all four ownership-transfer interleavings. |
| 4360282820 | Fixed. Event staff schedules the next expiry update, reschedules on assignment changes and clears timers on cleanup. Long expiry delays are capped to the browser timer limit. |
| 4360282831 | Fixed. Removed the render-time `latestVisit` ref mutation. Effect cleanup rejects responses from older committed visits; StrictMode retains single-use submission behavior. |
| 4360282842 | Fixed. Both success and failure after a stored organization change produce a terminal explanation and preserve the new selection. |
| 4360282852 | Fixed. Failed campaigns offer “Review and reschedule.” The editor restores content and segment, supports saving a draft or a future schedule, and keeps send-now separate. Authorization checks, mutation recovery and draft preservation apply. A failed campaign can also recover when the reviewer keeps its existing future time. |

Agent-executed QA uses isolated local data. The real stack was prepared/seeded with database `hafapass_team_fix_r2`, API 3056 and Vite 5226. T3 snapshot failed twice with `Preview automation snapshot timed out after 15000ms.`; the documented agent-browser fallback used an isolated Chrome session. Password sign-in with the configured Clerk test credentials reached an email verification challenge. Per the task instruction, signed-in invitation and Sales tools acceptance at **both 375 and 1280 is blocked by Clerk verification**; no alternative sign-in token or account-setting change was used.

Separate browser contracts use the existing Clerk-free CI development configuration and synthetic API fixtures. At 375 and 1280 they exercise success/failure invitation settlement after switching organizations, terminal loading state, preserved selection, campaign content/segment restoration, focus, draft save, explicit send-now, and absence of horizontal overflow. They establish frontend interaction/layout with fixtures, not authenticated Rails integration. Vitest additionally covers rescheduling, validation recovery, permission-restricted actions, StrictMode and timed expiry. Request/service specs cover saved outcomes and real PostgreSQL lock ordering. Physical-device input and production deployment were not run.

Final frontend gate: ESLint passed; Vitest **1,823 tests in 166 files passed**; production build passed; production npm audit found no vulnerabilities; Impeccable 4.6.0 returned `[]`. The full Playwright gate passed **116 tests** with two workers, including all six new review-recovery browser contracts. One earlier full parallel run had an unrelated existing empty-inventory timeout at 1280; the complete two-worker rerun passed. Logs: `/tmp/hafapass-r2-{lint,vitest,build}-final.log`, `/tmp/hafapass-r2-playwright-verified.log`, `/tmp/hafapass-r2-impeccable.log`, `/tmp/hafapass-r2-npm-audit.log`.

RuboCop inspected **907 files without offenses**; Brakeman reported **no warnings**; Bundler Audit found **no vulnerabilities**. Secret/debug hygiene, release-freeze contract and whitespace checks passed. The final full RSpec gate passed **3,000 examples with no failures**, including the independent endpoint-by-role contract. Log: `/tmp/hafapass-pr152-9b5c5666-r2-rspec-verified.log`. A previous run before the extra unchanged-schedule regression passed 2,999 examples; an interrupted follow-up is not counted as a completed gate.

The final focused sales-tools request check passed **10 examples**, including the unchanged-schedule recovery using full timestamp precision. Log: `/tmp/hafapass-pr152-r2-sales-recovery-final.log`. Both dedicated databases were dropped and absence verified. Task-owned servers, browser/daemon processes and the T3 tab were cleaned; copied credential files were removed. Lifecycle session `01a16913-3894-7472-ba84-ba3034eac0f5` reports no active owned resources. Shared Docker/services and other worktrees were left unchanged.
