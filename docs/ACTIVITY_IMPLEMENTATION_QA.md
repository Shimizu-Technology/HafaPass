# Organization activity and role comparison

## Context and acceptance

Implementation base: `826ae3ed` (main, PRs #152 and #153), October 24, 2026.
Sources: README.md, CLAUDE.md, docs/AUDIT_ACTION_REGISTRY.md,
docs/AUDIT_INTEGRITY.md, OrganizationAuthorization, the independent
endpoint_role_contract_spec, and the October 4 Brain Dump portfolio review.
The current user instruction establishes HåfaPass as a live Guam ticketing
marketplace; older launch-readiness notes do not establish its current rollout.
Production deployment is outside this held PR's scope.

Organizers need a readable history without exposing buyers or platform review
material. Owners see organization-visible history, managers see operations,
finance sees money, and event manager grants apply only to assigned events.
Clerk identifies people; organization membership and effective assignments govern
access. Stripe/provider history is projected through the same registry.

Use the existing quiet dashboard style: short sentences, stable day groups,
Guam time, explicit outcomes and expandable changes. Desktop filters are compact;
phone filters use a disclosure. Filter and load-more feedback stay immediate,
with no added animation needed. Role comparison stays beside invitations and
uses backend permission definitions without replacing the independent contract.

## Required cases (agent executed)

All cases start with owned local fixtures or isolated test transactions. No real
money or message delivery. Desktop width 1280 and phone viewport width 375 are
required for browser cases; native hardware/installed PWA behavior is excluded.

| ID | Starting state and actions | Expected result | Status |
| --- | --- | --- | --- |
| A01 | Owner, two organizations; list/filter/search history | Selected organization only; registry allowlists; no private data | passed |
| A02 | Manager, finance, event manager and denied roles | Audience and event grants enforced on each request | passed |
| A03 | Equal-time rows; load more; insert a new row | Stable cursor with no duplicates/skips from inserts | passed |
| A04 | Export filtered history; download; revoke/change membership and repeat | Redacted/formula-safe CSV, audited lifecycle, fresh access check | passed |
| A05 | Admin exact filters and CSV; expand detail | Exact matches, readable sentence/drilldowns, sanitized technical fields | passed |
| U01 | Owner Activity at both widths; expand, filter, clear, paginate, download | Discoverable controls, preserved event filter, saved CSV | passed |
| U02 | Loading, empty, failed request, retry at both widths | Honest state and successful recovery; marker date note | passed |
| U03 | Team invite role picker, Compare roles at both widths | Complete readable matrix and correct permission notes; keyboard access | passed |
| U04 | Event overview View activity | Opens Activity prefiltered to event; role gate preserved | passed |
| G01 | Complete CI-equivalent local gate | RSpec, RuboCop, Brakeman, dependency audits, lint, Vitest, build, Playwright, hygiene/freeze | passed |

Fixtures: local database `hafapass_activity`; test database `hafapass_activity_test`.
Ports: API 3058 and Vite 5228. Shared Docker services and ports 3011/3000/3088
are borrowed. Runtime ownership session: `01a16999-7292-7c83-9a44-8d669fd33b08`.
Evidence, tested head, retests, review and cleanup results are appended below.

## Execution evidence

The agent executed the cases above against the isolated branch from `826ae3ed`.
Backend request tests use transactional fixtures; Playwright uses the repository's
Clerk-disabled test-auth mode and isolated API routes. No real payment or message
was sent. The local stack was also created at the requested API 3058/Vite 5228
ports: schema loaded, migrations checked, demo fixtures seeded, and 80 realistic
rows created through `AuditLogger` in `hafapass_activity`. The seed-marker query
confirmed organization 1, events 1/4/7/8 and 80 visible post-marker rows.

Clerk test credentials were loaded by generated code from the canonical repo's
`.env`, without printing values. Password sign-in reached `/sign-in/factor-two`.
As authorized, signed-in live-stack journeys were skipped in favor of test-auth
Playwright. This does not establish live Clerk-to-API journey acceptance or
native phone behavior. T3 preview snapshots timed out twice; the Clerk attempt
used an owned Chrome tab, which was closed afterwards.

| Case | Result and evidence |
| --- | --- |
| A01 | Passed: cross-organization membership/header/filter isolation; private/unknown actions and payloads excluded in requests and CSV. |
| A02 | Passed: Owner, Manager, Finance, event-assigned Manager, and denied Marketer/Box office/Scanner; assignment expiry; current-member actor masking and search. |
| A03 | Passed: same-time tie-breaking, fixed snapshot, tampered/filter-changed cursor rejection, maximum page size. |
| A04 | Passed: snapshot/role redaction, formula escaping, request/generated/downloaded/failed auditing, requester/tenant/membership/grant recheck, expiry, privacy redaction at download, streamed failure recovery. |
| A05 | Passed: combined exact admin filters, legacy NULL/unknown outcomes in list and CSV, safe technical detail and links, admin revocation at download. |
| U01 | Passed at 375/1280 in test-auth: day groups, details, URL-preserved filters, load more, failed export retry and saved CSV content. |
| U02 | Passed at 375/1280 in test-auth: marker note, empty search, loading, error/retry, clear filters, refresh and reduced motion. |
| U03 | Passed at 375/1280 in test-auth: Compare roles, backend-derived rows, axe, no horizontal overflow, Escape/focus return, preserved invite email and selected Finance role. |
| U04 | Passed at 375/1280 in test-auth: event overview View activity opens the matching event filter, which remains selected. |

Screenshots are test-auth fixtures, not production account data:
[Activity phone](activity-evidence/activity-375.png),
[Activity desktop](activity-evidence/activity-1280.png),
[role comparison phone](activity-evidence/role-matrix-375.png),
[role comparison desktop](activity-evidence/role-matrix-1280.png).
The Activity title deliberately exercises a long event name; admin tests also
exercise unbreakable actor email and literal script-like text.

## Review and retests

Two independent static review rounds inspected the combined implementation.
Three material findings were fixed with regression coverage:

- Invited/revoked/expired memberships no longer expose actor contact details in
  rows, options, contact search or CSV; each uses effective membership.
- Allowed-to-allowed role/assignment scope changes clear cached rows, invalidate
  pending exports and restart pagination without the old cursor. Cursors are
  also bound to the current scope fingerprint.
- The Unknown outcome filter includes both explicit `unknown` and historical
  `NULL`, matching the displayed outcome and filtered admin CSV.

The first broad browser run found a missing accessible select name and an old
mobile test that assumed filters stayed expanded after refresh. The select
labels and test were corrected. A fresh-server affected batch passed all 26
cases, including offline scanner behavior. Cold-load interception now includes
Vite's query suffix, and the Discover layout test waits for the page's held
request before measuring, avoiding the route fallback spinner as a fixture.
The subsequent 18-case Activity/overview/cold-load batch passed. Full-gate and
final cleanup results follow below.

The broader gate also exposed low contrast in the existing pricing-tier loading
label; its text now uses the existing readable neutral tone. Admin platform-area
filtering includes unknown private actions under the same fallback area shown on
their row. The last API-focused run passed 47 examples, including this regression
and legacy unknown-outcome list/CSV coverage.

## Final engineering gate and disposition

Functional implementation: `e6db788efd92eb1d046388d3c8b8dcc8ffdb1364`.
The final documentation/evidence commit does not change application behavior.

- Full RSpec: **3,195 passed**. Later legacy filter and unavailable-human actor
  refinements: **59 final focused request examples passed**; these cover the
  changed query/presenter/export paths after the full run.
- RuboCop: **946 files, no offenses**. Brakeman: **no warnings**.
- Bundler Audit and production npm dependency audit: **no vulnerabilities**.
- ESLint: **passed**. Vitest: **170 files, 1,860 tests passed**.
- Production build: **passed**. Final browser gate: **127 passed**, one worker
  as in CI; Activity/admin/role-matrix/overview checks include 375 and 1280,
  reduced motion, keyboard/focus, saved CSV and axe checks.
- The offline scanner fixture now waits for visible Offline mode before the
  wide-layout manual-entry click. Both variants passed three consecutive runs
  (six tests) before the green complete gate. Scanner application code is unchanged.
- Matrix artifact/docs freshness, release-freeze contract, secret/debug hygiene
  and diff whitespace: **passed**. Advisory Impeccable: **no findings**.

Local API/Vite and browser resources were stopped/closed through the lifecycle
session. `dev-lifecycle status` reports no active owned resources. Both disposable
`hafapass_activity` and `hafapass_activity_test` databases were dropped; temporary
credential copies were removed. Shared services, protected ports and containers
were left unchanged. No runtime resource is handed off.

The worktree/branch remain available for the requested held PR. Production was
not deployed or changed. GitHub Actions/CodeRabbit status is recorded with the
PR and local handoff; local checks and independent review do not substitute for
those required remote gates.

## Design and CodeRabbit revision, October 24

Revision base: `fdbb034488c4c9db1ddd4c25848c7253c6d31b4c` in the same
held PR #154. `origin/main` was already an ancestor at revision start; no merge
was needed. The acceptance scope remains the organization roles and activity
journeys above. The owner’s priority for this revision is understandable activity
and efficient role comparison on phones and desktop.

Activity sentences now start with the audience-safe actor and identify the
record, including captured price/inventory changes, team roles, guest-list entry
and ticket counts, order references, refund/dispute/payout amounts, campaign
names and recipient counts, export row counts, and safe settings/status details.
The shared logger captures only registry-allowlisted display context. Older
records use stable IDs. Private actions keep empty display projections, buyer
contacts remain excluded, and both UI and CSV use the same sentence presenter.
Search can find the allowed names/references. Exact actor filters cannot reveal
platform staff or nonmember identities.

Filters show their active count, a reachable Clear button and a 44px chevron
control on phones; desktop controls stay visible. Mobile Compare roles defaults
to the invite draft’s role and shows its Can/Can’t lists, with relevant scope
notes. The desktop table has text and icons, sticky headings/first column, and a
keyboard-focusable scroll region. Role permissions and the generated matrix are
unchanged. No new motion was needed for these operational controls.

### Revision acceptance (agent executed)

All browser cases require both 375px and 1280px Chromium viewports. Cases use
isolated test-auth/API fixtures, a controlled clock and reduced motion. The live
Clerk credential attempt again reached `/sign-in/factor-two`; the extra code was
not supplied. These results do not establish live Clerk-to-API or native phone
acceptance. No real provider, payment or message delivery was exercised.

| Case | Observable outcome | Result |
| --- | --- | --- |
| R21 | Price/inventory, amount/reference, invite-role and historical sentences; private/nested values excluded; safe search and CSV agree | Passed in request/model/service regressions; full gate recorded below |
| R22 | Activity details, exact filters/count, reload, pagination, CSV failure/retry/download, empty/error recovery and clear | Passed at 375/1280, including saved CSV and axe |
| R23 | Invite draft preserved; Finance preselected; switch to Scanner; Can/Can’t and assigned-event notes; Escape/focus return; desktop keyboard scrolling | Passed at 375/1280, including axe and overflow checks |
| R24 | Admin exact filters, safe links/details, escaped text, CSV, empty/error recovery and clear | Passed at 375/1280, including saved CSV and axe |
| R25 | Event overview View activity preserves the event filter | Passed at 375/1280, including axe |

The owned local stack used API 3058/Vite 5228 and disposable databases
`hafapass_activity_r2` / `hafapass_activity_r2_test`. Demo seeding plus 65
post-marker `AuditLogger` fixtures verified the named context with no provider
calls. The captured screenshots use the browser fixtures, not account data:

- `activity-evidence/activity-375.png` (mobile filters closed)
- `activity-evidence/activity-filters-open-375.png`
- `activity-evidence/activity-1280.png`
- `activity-evidence/role-matrix-375.png`
- `activity-evidence/role-matrix-1280.png`
- `activity-evidence/admin-log-375.png`
- `activity-evidence/admin-log-1280.png`

The first browser pass found a missing keyboard focus target for the scrollable
desktop matrix; this was fixed and retested. Later broad failures exposed stale
filter locators and an admin recovery fixture that injected failure before the
preceding Clear request settled. The fixture now waits for the saved filter and
load state before injecting the next error. A broad backend run exposed legacy
expectations that treated ticket/promo display names as private; tests now allow
those named labels while still forbidding guest contacts and free text. Display
capture is restricted to each action’s allowlist, preserving private/unknown
actions. Another regression fixes numeric-looking generated export UUIDs being
redacted, which could make a failed streamed export appear ready.

### Review disposition

CodeRabbit completed its initial review of `fdbb0344`: five inline findings plus
one outside-diff finding. Each was verified against code and addressed:

| Finding | Disposition |
| --- | --- |
| Stale “later PR” statement in action registry docs | Replaced with the Activity projection reference |
| Unbounded/repeated admin filter options | First page or explicit initial request only; bounded, query-scoped IDs cached one minute; contact labels read fresh; client preserves options on later pages |
| Repeated organizer options on Load more | Options omitted on cursor pages; client preserves the initial options |
| Staff IDs exposed in actor options | Excluded; guessed exact staff IDs also return no organizer matches |
| Repeated authorization/assignment queries | Per-request permission, assignment and relation memoization |
| Outside-diff stale scope in audit-integrity docs | Clearly attributed to the earlier PR and linked to the current projection |

Final engineering results, head and resource disposition follow below.

### Final revision gate and cleanup

Tested source: the revision commit containing this section, with application
source held unchanged during the successful final gate.

- Full RSpec: **3,209 examples, 0 failures**.
- RuboCop: **949 files, no offenses**. Brakeman: **no warnings**.
- Bundler Audit and production npm audit: **no vulnerabilities**.
- ESLint and production build: **passed**.
- Vitest: **170 files, 1,860 tests passed**.
- Complete Playwright: **127 passed**, one worker; includes the expanded
  375/1280 Activity/admin/matrix/overview cases and axe checks.
- Matrix freshness, freeze contract, secret/debug hygiene and whitespace:
  **passed**. Advisory design scan: **no findings**.

Owned API/Vite processes and browser tabs/daemons were stopped or closed.
Lifecycle session `01a169c1-4d50-7850-8853-0116306c1a3a` reports no active owned
resources. Both disposable databases were dropped. Shared/protected services
and the specified Docker/3011 resources were untouched. No runtime handoff.
The worktree and branch are preserved for the held PR; `policies.yml` is unchanged.

CodeRabbit's completed initial review covered `fdbb0344`; all six verified
findings were fixed in this revision. Final-head Actions and incremental review
are separate remote gates owned by the lead after the delegated implementation
returns. No merge or production verification is claimed.

## Security revision, 2026-10-24

Starting head `c515eb21`; `origin/main` is already an ancestor. The scope is the
Activity projection for event organizers and door operators (Clerk identity,
effective organization/event grants, Rails registry; no live payments). The
current project notes still identify paid launch as gated (Brain Dump,
`work/shimizu-tech/company-positioning-and-project-review-2026-10-04.md`).

Required acceptance for this revision is agent-executed affected-flow QA:

- S01: Manager and event-assigned Manager JSON/CSV show door-sale context without
  transaction money, order identifiers or provider details; Owner/Finance retain
  full sentences. All Manager-visible registry fields are audited; configured
  ticket prices remain visible.
- S02: Event staff uses its own event-operations area and effective event scope.
  Organization membership, ownership, verification, payout/tax settings stay
  Owner-only in JSON and CSV.
- S03: Search matches only this viewer's rendered sentence and displayed labels,
  including renamed/deleted events and hidden money fields; sparse matches keep
  stable pagination, and filtered CSV uses the same predicate.
- S04: Filter actor options restrict to effective members in SQL before loading.
- U05: Role comparison accurately describes Manager activity scope at 375/1280;
  Activity event-staff labeling, recovery and CSV remain usable. Playwright's
  isolated test-auth/API fixtures execute these interface journeys; request specs
  establish backend authorization. Live Clerk/native hardware are excluded.

Disposable test database: `hafapass_activity_security_test`. Shared Docker
3000/3088 and port 3011 remain borrowed and untouched. Results follow below.

Security revision results (source changes atop `c515eb21`, committed together
with this ledger; exact pushed SHA in the local handoff and PR):

- S01–S03 passed in request/registry regressions: Manager and event-assigned
  Manager door JSON/CSV omit amounts, order references, currency, provider status
  and lifecycle details; Owner/Finance retain amount/order sentences. The full
  Manager field inventory excludes transaction-money/reference fields and keeps
  configured prices. Guest-list/waitlist/fulfillment order identifiers are absent.
- S02 passed for Owner, organization Manager, event-assigned Manager and Finance:
  event-staff area/event filter and organization security exclusion in JSON/CSV.
- S03 passed for renamed/deleted events, hidden amount/order search, filtered
  CSV and sparse cursor pagination. Search scans bounded batches of rendered
  rows; a search without matches may scan the authorized history, trading query
  time for correct per-viewer matching without unbounded record loading.
- S04 verified in source: the distinct history actor subquery is restricted by
  effective member IDs before users are loaded; existing inactive/platform-staff
  option/filter privacy regressions pass.
- U05 passed at 375/1280: Event staff tag, Manager scope in the role comparison,
  invite-draft/focus preservation, Activity filtering/recovery/saved CSV and axe.
  The first browser run had one new mobile assertion matching both mobile and
  hidden desktop text. Scoping that assertion to the mobile list fixed the test;
  the complete rerun passed. Updated screenshots are in `docs/activity-evidence/`.
- Final full RSpec: **3,219 examples, 0 failures**; focused security/activity/
  registry/matrix suite: **67 examples, 0 failures**.
- RuboCop: **950 files, 0 offenses**; Brakeman: **0 warnings**; Bundler Audit:
  **no vulnerabilities**. ESLint, production build and npm production audit pass.
- Vitest: **170 files / 1,860 tests passed**. Full Playwright: **127 passed**,
  Chromium workers=1 on owned port 4278, including axe and 375/1280 affected flows.
- Matrix freshness, release freeze, hygiene and diff checks pass; advisory
  Impeccable scan: `[]`. No migrations, dependencies or `config/policies.yml`
  changes. Live Clerk, native devices and real provider/money flows were not run.

Owned Playwright/Vite/browser children exited; port 4278 is closed. The disposable
`hafapass_activity_security_test` database was dropped and verified absent.
Lifecycle session `01a169e9-24d6-7c31-8167-2d49d58e69b1` reports no active owned
resources. No resource handoff; Docker 3000/3088 and anything on 3011 untouched.
Remote CI/review is separate from this local gate; the lead owns final-head
monitoring. This PR remains unmerged.


## Final review revision, 2026-10-24

Starting head `146d0d38`, held PR #154, existing worktree
`t3-d7dfd28a`. `origin/main` (`826ae3ed`) is already an ancestor.
This revision preserves the Activity role/security contract established above.
The app serves event organizers and admission staff; these fixes cover admin
history filtering and the team role comparison, with no live provider actions.

The GitHub REST comments API, paginated through all comments and filtered by
`original_commit_id = 146d0d38351016db9e7bf97e7102e36b7fbb9481`, returned
**four inline comments**, rather than seven. The matching review body has one
additional outside-diff finding. All five actionable findings were verified:

| Comment | Disposition |
| --- | --- |
| `4362910194`: admin options collapse | Each option query omits only its own filter and retains every other filter; bounded IDs and one-minute cache remain. Cache version changed to avoid old collapsed results. Four request cases select and switch organizations, actors, events and actions, excluding rows outside other filters. |
| `4362910220`: tracked screenshots overwritten | Normal screenshots use `testInfo.outputPath`; only explicit `CAPTURE_ACTIVITY_EVIDENCE` writes to tracked evidence. |
| `4362910235`: mobile Manager activity note | Activity note added to Manager's mobile list; Vitest and 375px browser assertion cover the full scope note. |
| `4362910252`: member comparison uses invite role | Comparison state captures the clicked member role or current invite draft role. Both entry points, reopening, draft preservation and focus return are covered. |
| Outside diff, `AdminAuditLogPage.jsx:33`: empty changes | Empty or absent projected changes fall back to sanitized admin before/after data. The fee-settings fixture now includes the real `changes: []` shape and verifies field count and changed values. |

The mobile-note comment embeds static-analysis warnings too: mapped rows already
have `key={row.key}` (no missing-key defect), and a maximum three-item constant
allowlist does not warrant a Set conversion. The bot's broad docstring-coverage
suggestion is cosmetic and deferred; no actionable behavior finding is deferred.

Agent-executed affected-flow acceptance uses owned request fixtures and the
repository's isolated test-auth/API browser fixtures. Required cases:

- F01: select and switch all four admin option values without clearing;
  remaining exact filters still constrain results/options. Request specs verify
  the real backend; the 375/1280 browser journey also switches organizations.
- F02: on a phone, select Manager and read the activity restrictions; compare an
  existing Scanner after drafting a Finance invite, close, reopen the invite
  comparison, and retain email, draft role and trigger focus. Desktop matrix
  keyboard behavior remains covered.
- F03: admin-only audit rows with `changes: []` show their recorded field changes.
- F04: ordinary full Playwright execution leaves tracked evidence unchanged.
- Preserved flows: Activity filters/recovery/pagination/saved CSV, admin exact
  filters/links/technical details/CSV/recovery, event-overview Activity link and
  axe checks at 375/1280.

The first lint pass found the new Node `process` reference needed an explicit
`node:process` import; fixed before the full frontend gate. The updated security
advisory database reported GHSA-pq4g-8rxf-4g29 against locked `crass 1.0.7`.
Verified against the upstream advisory and updated only that lockfile entry to
patched `1.0.8`; final backend validation uses the patched gem.

The first full backend run overlapped the lockfile update and produced eight
subprocess `Bundler::GemNotFound` failures for `crass 1.0.8`; its parent had
already loaded the old gem path. This was a local validation-environment error.
The entire backend suite is rerun with consistent worktree-local gem paths.

Final full-gate results and cleanup follow below. Browser
coverage is Chromium at 375/1280, not native hardware or live Clerk/provider
acceptance. No migrations or `hafapass_api/config/policies.yml` changes.


Final source (committed together with this ledger) passed:

- Full RSpec with patched `crass`: **3,223 examples, 0 failures**;
  `.codex/review-rspec-final.log`. The initial environment failure is superseded.
- RuboCop: **950 files, no offenses**. Brakeman: **0 warnings**.
- Bundler Audit and production npm audit: **no vulnerabilities**.
- ESLint, production build, role-matrix freshness, local freeze check (inactive),
  secret/debug hygiene and whitespace: **passed**. Impeccable advisory: `[]`.
- Vitest: **170 files / 1,861 tests passed**.
- Complete final Playwright: **127 passed**; Chromium, one worker, owned port
  4288. F01–F04 and the named preserved flows passed in the specified request,
  component and 375/1280 browser dimensions. Admin `changes: []` now has browser
  assertions for the field count and recorded value details as well.
- Every tracked screenshot remains byte-unchanged after ordinary test execution.
  New captures are under ignored `hafapass_frontend/test-results/`.

Both owned Playwright runners (56421 and 84206), managed Vite and browser children
exited; port 4288 is closed. The disposable
`hafapass_activity_final_review_test` database was dropped and verified absent.
Lifecycle session `01a16ac9-adb3-7380-82cc-36f0602d59f5` has no active owned
resources. No resource handoff. Docker 3000/3088, port 3011 and protected/shared
services were untouched. The held worktree/branch remain available.

Remote CI and incremental review are separate gates. This delegated worker
returns a single post-push snapshot and the exact head to the lead, who owns
remote monitoring under the T3 delegated-task rules. No merge or production
verification is claimed. Detailed remote state is in the local final-review
handoff and PR replies.
