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
