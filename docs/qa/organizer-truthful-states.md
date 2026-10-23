# Organizer states and operations copy

2026-10-23 · base `677e46db` · agent-executed affected-flow QA. PR is held for the lead to merge.

HåfaPass serves Guam ticket buyers, organizers, admission staff and platform administrators. Rails owns verification, publish/sales eligibility, tax certification, finance approval and admission records; React presents those states. Clerk authenticates staff. Live Stripe is outside this local test scope.

Sources checked: `CLAUDE.md`, `.github/workflows/ci.yml`, `Event.publicly_visible`, `Event#publish_checklist`, `ConnectedAccount#payout_ready?`, `OrganizerTaxInformationUpdater`, scanner `processCredential`/`admitEntry`, and admin dashboard aggregates. Brain Dump's 2026-10-04 company review describes the event/admission/settlement system but predates the organizer verification change; the current code and supplied brief govern this task.

Acceptance: all 16 requested items agree with the actual state/transition, preserve existing money and admission behavior, and use short public language. No policy-register edits, live payments, external email delivery or production mutations. Required local gate: RSpec, RuboCop, Brakeman, Bundler Audit, ESLint, Vitest, build, npm production audit, Playwright, release freeze and hygiene. CodeRabbit and GitHub Actions remain separate PR gates.

Local UI fixtures: dedicated `hafapass_org_truth` database seeded from this checkout; API 3053, Vite 5223; separate empty RSpec database `hafapass_org_truth_test`. Authentication uses the repository's Clerk test account without exposing credentials. Email rendering captures HTML only; outbound email and Stripe keys are disabled for the local server.

| Case | Actions and expected result | Required dimensions | Result |
| --- | --- | --- | --- |
| Q1 organizer tax/payout setup | Open Settings; inspect W-9 timing and choices, save isolated check details, reload to verify saved review state | 375 / 1280 | Passed |
| Q2 admin verification/suspension | Open queue and user controls, inspect conditional paid-ticket warning, suspend a local organizer and restore it; reload saved state | 375 / 1280 | Passed |
| Q3 admin financial summaries/accounts | Inspect payment/proceeds tiles, readable account requirements and check-vs-bank paid-outcome text | 375 / 1280 | Passed |
| Q4 event draft/edit/fees/agreement | Inspect capacity requirement and all-in fee hint; save event capacity and verify reload; inspect agreement key points | 375 / 1280 | Passed |
| Q5 scanner admission | Inspect saved ticket list and manual action, admit a local ticket and verify persisted admission | 375 / 1280 | Passed |
| Q6 box office/refund recovery | Inspect disabled platform card capability and saved-operation recovery guidance; no new money actions | 375 / 1280 | Passed |
| Q7 organizer finances | Inspect requested-but-unconfirmed funds and method-specific paid definitions | 375 / 1280 | Passed |
| Q8 rendered emails | Render verification request/decision and fee changes for both processing bearers and all fee policies; inspect HTML | HTML / browser | Passed |

Browser resizing establishes responsive web behavior, not physical mobile hardware, native keyboard or installed-PWA behavior. Unknown-save network failures and server validation are covered by component tests with isolated simulated responses.

Execution evidence (source tree committed with this record):

- Q1: saved pickup check details, reloaded and confirmed `Truth QA Payee`; opened tax form at both widths; pending/processing payout fixtures disabled tax editing with the new explanation. No tax certification or real identity data entered.
- Q2: suspended and restored local profile 48 through the admin queue and verified saved status. Inspected user and organization detail suspension dialogs at both widths. Verification eligibility and pending-request version checks remain covered by RSpec and Playwright.
- Q3: inspected both dashboard tiles and readable account requirements. Opened check payout 3 and bank payout 4 outcome dialogs at both widths without recording an outcome or initiating payment.
- Q4: changed event 49 capacity from 100 to 101 through the editor and reloaded to verify 101. Checked new-event helper, all-in fee hint and updated-agreement key points. Drafts may omit capacity; publishing may not.
- Q5: local ticket 188 admitted through manual entry; confirmed `first_admitted_at` and exactly one accepted admission action. Checked result and saved-list language at both widths. Physical camera/scanner hardware was not tested.
- Q6: inspected box office at both widths with merchant setup missing, then restarted only the task API with the production launch-scope capability disabled and confirmed the platform-unavailable message. Viewed refunds at both widths. Lost sale/refund response recovery is simulated in unit tests; no live payments or real refunds.
- Q7: local processing payout fixtures show `$2.00 has been requested for payout. Payment hasn't been confirmed yet.` and the check-clearance distinction at both widths.
- Q8: rendered verification request/decision plus all six fee-choice/processing-bearer combinations. Checked HTML and browser renderings at both widths; no delivery transport invoked.

Screenshots and rendered HTML are local at `/tmp/hafapass-org-truth/screens/` and `/tmp/hafapass-org-truth/emails/`. Representative files: `users-suspend-375.png`, `tax-locked-375.png`, `edit-event-saved-375.png`, `box-office-disabled-375.png`, `check-outcome-1280.png`, `bank-outcome-375.png`, `finances-inflight-1280.png`, `scanner-admitted-375.png`, `agreement-1280.png`, `email-fees-organizer-split_fees-375.png`. Each changed screen has 375px and 1280px captures; no horizontal page overflow observed in the seven-page responsive sweep.

Local gate:

- RSpec: 2,416 examples, zero failures. A prior full run failed one unchanged schema-rollback concurrency example with `PreparedStatementCacheExpired`; its isolated retry passed, followed by the clean full run. The final email service suite also passed 30 examples after removing an unrelated invitation time-label change.
- Vitest: 162 files, 1,738 tests passed.
- Playwright: 88 passed on isolated port 4273. Initial runs exposed stale copy assertions and interference on shared default port 4173; both were resolved without touching another task's resources. Temporary port configuration was removed.
- RuboCop: 895 files, no offenses. Brakeman: no warnings. Bundler Audit: no vulnerabilities. ESLint, production build, npm production audit, release-freeze check and hygiene passed.
- Impeccable advisory scan: no findings (`[]`). UI interaction and saved outcomes above provide separate acceptance evidence.

All requested items 1–16 were confirmed and addressed. Existing accurate suspension copy was retained. The matching false suspension/verification/W-9 claims in `AdminOrganizationPage` were corrected as part of items 1, 2 and 4. No edits to `config/policies.yml`, buyer flows, boot/loading behavior or the general time-zone sweep.

Resource cleanup and PR review status are recorded in the final handoff.

## Independent review fixes — 2026-10-23

Refreshed the existing brief against `dd1d55ba`, `PayoutReconciler`, `Payout#disbursement_cents`, the admin payout serializer, and the saved box-office operation state. Merged `origin/main` (`6c1c5b2b`, including PR #147) with merge commit `b40ed7d8`; no conflicts. This follow-up changes frontend behavior and tests only. The policy register remains unchanged.

Acceptance: free-only organizers see tax/payout instructions explicitly conditional on selling paid tickets; a zero-disbursement check payout requests withholding evidence without claiming a check exists; unresolved saved sales never suggest collecting cash. Existing check/bank evidence and saved-operation recovery must remain intact. Agent-executed affected-flow QA, using Clerk's test account and owned synthetic fixtures on API 3053 / Vite 5223.

| Case | Actions and expected result | 375px | 1280px |
| --- | --- | --- | --- |
| R1 conditional organizer setup | Open the checklist for the free-event organizer without finance approval; inspect conditional instruction and follow its Settings link | Passed | Passed |
| R2 withholding-only payout | Open outcome dialog for $42 gross, $10.08 withholding plus $31.92 prior shortfall, $0 disbursement; inspect evidence labels and no-check explanation | Passed | Passed |
| R3 saved sale while cards disabled | Interrupt a free cash-sale request through browser network abort; inspect recovery, reload, and confirm saved operation persists, Cash stays disabled, and “Use cash” stays absent | Passed | Passed |

R2 also completed through the mobile UI: entered a withholding ledger reference, reason and `0.00`, recorded the outcome, then reloaded. Rails independently confirmed payout #1 is `paid`, disbursement is zero, the reference is `withholding_only_1`, and reconciliation audit evidence contains `actual_check_amount_cents: 0`. No check, bank/provider transfer or email transport was invoked. R3's aborted request never reached the API; no sale was saved to the database. The saved recovery state was verified through the actual interface, not inserted into browser storage.

Screenshots: `/tmp/hafapass-org-truth-fix/screens/{checklist,withholding,box-office-pending}-{375,1280}.png`. No horizontal page overflow observed. This is resized desktop Chrome, not physical-phone acceptance. T3 preview snapshots timed out twice; the fallback used the repository's agent-browser workflow with an isolated session and installed Chrome. Authentication and fixtures were limited to the test account and dedicated `hafapass_org_truth_fix` database.

Regression coverage adds five cases: conditional setup; withholding-only submission with and without a tax snapshot, including positive-amount rejection; saved cash and card operations surviving reload without cash instructions. The zero-net form keeps the required special reference fixed, uses withholding confirmation/evidence labels, and requires a zero actual amount. Missing-W-9 payouts already covered by withholding follow PayoutReconciler's existing evidence rules. Ordinary check and transfer tests continue to pass.

Final local gate: RSpec 2,416 examples; Vitest 1,751 tests in 163 files; Playwright 91 tests; RuboCop 895 files; Brakeman zero warnings; Bundler Audit zero vulnerabilities; ESLint; production build; npm production audit; release-freeze and hygiene checks. Impeccable advisory returned `[]`. An inherited `BUNDLE_PATH=.cache/bundle` initially prevented backend commands from loading dependencies; unsetting that override used the installed gem set and all backend checks passed. Vitest prints existing jsdom network-error diagnostics while all suites pass.

The held-PR handoff records the final head, CI/review snapshot, and exact cleanup. The original 16-item QA above remains historical evidence; this follow-up accepted the three review fixes against the integrated tree.
