# Payout approval review fixes — 24 October 2026

PR #156 remains held for the lead; do not merge. Worktree: `/Users/leonshimizu/.t3/worktrees/HafaPass/t3-d74bfd7a`, branch `codex/hafapass-simple-payout-approval`. Starting head: `41d3126f`. `git fetch origin` followed by `git merge --no-ff origin/main` reported “Already up to date”: main was `87c3e21d` and already an ancestor. PR #155 was not on main at that check. No policy-register changes are included.

This record supersedes the original acceptance document where it describes bank entry or bank approval. HåfaPass currently pays organizers by check. The product purpose, users and sources in that document still apply: organizers choose their destination, the admin reviews the exact payee and certified W-9, and finance later records a check. Approval never sends money.

The organization now stores one `payout_connected_account_id`. Payout readiness and reservation use only that destination, including the withholding fallback. Saving check details selects the check in the same transaction; an existing check has an explicit selection action. Selection changes audit both account IDs. Switching is blocked during a pending, processing or held payout. The migration preserves only an unambiguous supported, enabled destination; ambiguous organizations must explicitly select their check. The database foreign key and model tenant validation protect the reference.

`ConnectedAccount::BANK_TRANSFERS_ENABLED` is false. Bank entry, selection and both simple/detailed approval are blocked; bank accounts cannot satisfy payout readiness. Existing encrypted bank data is retained. Organizers see “Not available yet — HåfaPass currently pays by check.” Admins see the same reason beside disabled approval. Historical provider integrations retain their existing advanced review path.

Bank transfers require a separate implementation before this constant can be enabled: collect and validate routing information; encrypt routing/account data; design a restricted finance-only retrieval path with access controls, explicit purpose and immutable access audits; verify ownership and the executable destination; define issuance, failure, reconciliation and change-locking behavior. Review the security design and complete end-to-end acceptance before enabling it. Retained data alone is not sufficient to execute a transfer.

The canonical v2 approval snapshot includes keyed HMAC fingerprints of the current decrypted TIN and complete check payee/delivery identity. The TIN fingerprint reuses the existing application-key derivation. Full TINs never enter review snapshots, ordinary responses or approval audits. Active manual approvals compare the current canonical digest, so direct updates bypassing revision callbacks also invalidate approval. Older manual approvals without the v2 snapshot require fresh review. Existing append-only history is preserved.

The dialog displays payout and W-9 details before the checklist, note and review date. Initial focus goes to the heading so a narrow viewport starts with the details. Disabled accounts are excluded from the waiting count and labeled Disabled on the organization page. The existing brand, 44px targets, native scrolling and quiet operational feedback are retained.

## Agent-executed affected-flow QA

Local fixture database: `hafapass_payout_r2`; test suite database: `hafapass_payout_r2_test` (the suffix is required by concurrency isolation guards). API 3059 / Vite 5229. Synthetic organization 1, check account 1, legacy bank fixture 3 and missing-W-9 organization 2. Clerk's configured test user authenticated using a short-lived test sign-in ticket; no extra-verification fixture or authentication bypass was needed. Mail used the test queue; external payment/email providers were disabled. No real money or external messages were sent.

| Case | Expected and observed outcome | Coverage/result |
| --- | --- | --- |
| R1 | Queue shows waiting checks, missing-W-9 reason; dialog details are expanded above confirmations. Heading focus, keyboard traversal, Escape/return focus and retry retain context. | Live 375/1280 and Playwright/axe: passed |
| R2 | Admin checks three confirmations and approves. Queue drops the approved account; database stores submission + approval, approval audit and queued notification. Organizer shows selected check and approved state after reload. | Live approval at 375; organizer at 375/1280: passed |
| R3 | Legacy bank selection exposes an explicit Use this check payout method action. Clicking it persists check ID 1 and audits bank ID 3 → check ID 1. Reload retains the selection. | Live desktop and responsive browser fixtures: passed |
| R4 | Bank entry/selection unavailable; admin approval disabled with a clear reason; existing bank data remains masked. API rejects bank writes/approval and model readiness stays false. | Live 375/1280 and server tests: passed |
| R5 | Both account creation orders, switching, disabled selection, cross-tenant selection and in-flight switching enforce one destination. Payout reservation uses exactly the selected account, never a different ready account. | Server request/service tests; final gate below |
| R6 | Changed TIN with identical last four and raw payee updates invalidate approval without revision tracking. Disabled accounts do not inflate waiting count. | Server tests; final gate below |

Screenshots refreshed: `admin-queue-{375,1280}.png`, `approval-dialog-{375,1280}.png`, `organizer-approved-{375,1280}.png` (check-only section), and `admin-organization-{375,1280}.png` (bank-blocked reason). Other images in this directory are historical evidence from the original implementation, not the current bank-transfer UX.

T3 preview opened but snapshot timed out twice with `Preview automation snapshot timed out after 15000ms.` The owned preview was closed; the repository agent-browser workflow used an isolated Chrome session. Screenshots were visually inspected. Coverage is resized desktop Chrome, not physical-device keyboard/gestures, native/PWA installation, actual email delivery, check issuance, bank execution or production deployment.

Final source commit, engineering gate results and lifecycle cleanup are recorded below after execution. CodeRabbit and GitHub Actions remain separate from local acceptance; this implementation sub-agent does not merge or monitor the PR after handing it back to the lead.
