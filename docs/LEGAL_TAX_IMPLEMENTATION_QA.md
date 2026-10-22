# Legal and tax safeguards implementation / acceptance

Date: 2026-10-21. Starting commit: `7c77bb6` (production-operations merge).
Branch: `codex/hafapass-legal-tax-safeguards`. Integration owner: lead agent;
this branch is pushed without a PR or merge, as requested.

## Product brief and scope

HåfaPass sells Guam event tickets through a Rails API and React frontend.
Buyers pay Shimizu Technology's Stripe account; organizers are the sellers and
receive checks after events. The existing implementation has independently
approved payout methods, check payee snapshots, organization permissions,
policy content digests, immutable financial allocations and audit logs.

Sources: `docs/LEGAL_AND_TAX_BRIEFING.md`, `docs/POLICY_REVIEW_REGISTER.md`,
`config/policies.yml`, `ConnectedAccount`, `PayoutCreator`,
`ConnectedAccounts::Manager`, `PolicyRegistry`, and `Settlements::Calculator`.
The task brief supplies current launch and owner decisions. Brain Dump's
project index was searched; repository code and the task brief govern this slice.
No external service configuration or production data is changed.

Acceptance: explicit agent-of-payee policy drafts; encrypted, certified organizer
TIN collection; W-9 payout gating and approval invalidation; edit locks during
check payouts; admin-only audited full-TIN disclosure; live-only annual and
monthly reports and protected CSVs; additive migration; complete automated gates.
The legal and accounting questions remain for professional confirmation.

## QA execution and limits

Agent-executed affected-flow checks use synthetic identities and payment data.
Request/model/service tests use the isolated `hafapass_legal_test` database.
Browser checks use the actual React screens with an in-memory synthetic API
adapter; they do not establish authenticated end-to-end API acceptance. Tested
source is the working branch after the new UI and safeguards, before its final
commit. No real TINs, payments, messages, or production records are used.

| Scenario | Expected saved/observable outcome | Coverage / result |
|---|---|---|
| Organizer signs tax information | Name, classification, nine-digit TIN, address, certification and typed signature save; server records date; only last four returned | Request/model tests; browser form completed on desktop with synthetic adapter: passed |
| Encryption and disclosure | Database ciphertext differs from TIN; normal JSON and inspection do not expose it; ordinary serialization does not decrypt | Model/config/request tests |
| Payout readiness and changes | Missing W-9 blocks readiness; tax save invalidates all approval revisions | Model/request tests |
| In-flight checks | Pending/processing checks reject tax edits; completed check permits edits | Request tests; browser lock state pending integration QA |
| Role boundaries | Managers/other organizations/non-admins cannot access sensitive operations | Request tests; auth-bound hooks retained |
| Admin reports | Select year; live collections/refunds/paid payouts and masked identity shown | Service/request/Vitest tests; synthetic browser year selection, masked identity and desktop/mobile report layout: passed |
| Reveals and CSVs | Admin POST audits before disclosure; normal CSV masked and formula-safe; amounts reconcile | Request/Vitest tests; synthetic browser reveal/hide and all three download actions: passed |
| Period math | Guam year boundaries, prior-year refund, negative month, absorbed/refunded fees, actual card costs, test-only payouts excluded | Service tests |
| Responsive tax form | Fields remain reachable, TIN blank and checkbox reset on edit, no horizontal page overflow | Desktop 1280px and mobile viewport 390px: passed with synthetic adapter |

Remaining integration QA on **phone and desktop**: sign in as organizer, save and
reload a W-9 against the API; verify approval invalidation in admin; attempt tax
edits while a real fixture check is pending/processing; verify manager denial and
organization-switch cancellation; select report years, reveal/hide and inspect
audit rows; download all CSV types and reconcile fixture amounts and leading
zeroes. Test native phone keyboard, focus, screen reader, and recovery from a
network failure. Resized desktop checks do not establish real-device behavior.

Local Vite uses the requested shared node_modules symlink. Font file requests
returned 403 under Vite's filesystem allowlist, so visual checks used fallback
fonts. Production build bundles fonts and passes; check final typography during
integration QA. Initial health probes failed against the default local API;
subsequent UI checks used a synthetic adapter, with no API writes.

Automated results on the final working tree: frontend lint passed; Vitest
145 files / 1,473 tests passed; production frontend build passed; RuboCop 26
changed Ruby files passed; Brakeman 0 errors / 0 warnings; full RSpec 1,894
examples / 0 failures. The advisory Impeccable
scan returned no findings. Independent read-only review found no material blocker.
Its missing test-only payout fixture was added. The final commit SHA is reported
to the integrating lead.

The first complete backend run had 1,867 examples / 5 failures: four production
boot fixtures lacked the newly mandatory encryption keys, and the existing admin
payout-approval fixture lacked a W-9. Those fixtures were updated. A subsequent
focused run of 43 examples passed. A later full rerun was deliberately interrupted
early to include a final CSV consistency regression and production missing-key
boot test; it is not counted as a passing gate. The subsequent complete rerun
passed. Staging now boots without encryption keys but cannot store W-9s until
they are configured; production still refuses to boot without all three keys.

Browser evidence artifacts (local T3 browser-artifacts directory):
`browser-screenshot-127-0-0-1-mvhtw8yk-1929bf85.png` (390px tax form) and
`browser-screenshot-127-0-0-1-mvhtzknk-bc3e0c6a.png` (desktop monthly report).
Browser download tests used synthetic CSV contents; request specs verify the
real CSV headers, amounts, masking, audit records and full-TIN behavior.

The task-owned preview tab and Vite process were closed after browser QA;
`dev-lifecycle status` reported no active owned resources. The test database is
kept only until the backend gate finishes, then dropped. Shared Postgres, Redis,
other sessions' services, and devices remain untouched.

Rollout: policy content changes invalidate the digest-bound `policy_register`
capability approval even with the unchanged draft version. Check the existing
review workflow before paid launch; do not treat engineering drafts as
professional approval. The additive migration creates no W-9s or approvals.
