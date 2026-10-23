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
| A01 | Owner, two organizations; list/filter/search history | Selected organization only; registry allowlists; no private data | not_run |
| A02 | Manager, finance, event manager and denied roles | Audience and event grants enforced on each request | not_run |
| A03 | Equal-time rows; load more; insert a new row | Stable cursor with no duplicates/skips from inserts | not_run |
| A04 | Export filtered history; download; revoke/change membership and repeat | Redacted/formula-safe CSV, audited lifecycle, fresh access check | not_run |
| A05 | Admin exact filters and CSV; expand detail | Exact matches, readable sentence/drilldowns, sanitized technical fields | not_run |
| U01 | Owner Activity at both widths; expand, filter, clear, paginate, download | Discoverable controls, preserved event filter, saved CSV | not_run |
| U02 | Loading, empty, failed request, retry at both widths | Honest state and successful recovery; marker date note | not_run |
| U03 | Team invite role picker, Compare roles at both widths | Complete readable matrix and correct permission notes; keyboard access | not_run |
| U04 | Event overview View activity | Opens Activity prefiltered to event; role gate preserved | not_run |
| G01 | Complete CI-equivalent local gate | RSpec, RuboCop, Brakeman, dependency audits, lint, Vitest, build, Playwright, hygiene/freeze | not_run |

Fixtures: local database `hafapass_activity`; test database `hafapass_activity_test`.
Ports: API 3058 and Vite 5228. Shared Docker services and ports 3011/3000/3088
are borrowed. Runtime ownership session: `01a16999-7292-7c83-9a44-8d669fd33b08`.
Evidence, tested head, retests, review and cleanup results are appended below.
