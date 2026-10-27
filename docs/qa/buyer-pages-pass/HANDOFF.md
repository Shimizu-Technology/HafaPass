# Handoff: buyer pages pass design

**Updated:** 2026-10-27T22:49:34+00:00
**Objective:** Carry the approved pass design through buyer discovery, My tickets and Saved in one held PR.
**Status:** Held for the lead; browser/unit gates passed with the documented local timing allowance; strict standalone PWA passed 2/2. CodeRabbit and database cleanup remain pending.

## Workspace

- Repository: https://github.com/Shimizu-Technology/HafaPass
- PR: https://github.com/Shimizu-Technology/HafaPass/pull/170
- Worktree: `/Users/leonshimizu/.t3/worktrees/HafaPass/t3-1ff03b0c`
- Branch: `codex/buyer-pages-pass`
- Base: fetched `origin/main` `3882764da0fc6adfed9c209a4c3d705671709f9d`
- Production source: `91d503eb903be509ae75b49a78bc2cc7e9668981`; later changes are evidence only. Read the actual PR head before continuing.
- Final evidence commit is being prepared; all production code and QA configs are committed. Verify actual final head and clean status.

## Completed and decisions

Short teal bands/light content; shared Home empty ticket on Events/Discover; collections; compact My tickets passes, segmented tabs, truthful recovery guidance; useful Saved instructions/cards/rows. Public header/theme follows scrolling. Confirmation only reserves loading space and removes capitalization. Filters/query/pagination/status/transfer/install/account behavior retained.

Shared edits: Navbar public routing/44px targets; Home empty-content extraction; opt-in PendingTransfer portal (only BuyerTicketPass uses it); English locale. Index CSS, workspace/admin/support/scanner, backend, pricing and policies untouched.

Independent review found the masked transfer dialog; `9a08ecc3` fixes it. Round 2 found no material issues. English expiry de-duplication and an assertion followed in `58e76d5f`; hidden results H2 and heading-order coverage followed in `91d503eb`. No third cosmetic review round.

## Verification

[QA ledger](README.md) includes raw logs. Reviewed units: 2022 passed, 3 pre-existing skips. Lint/build passed. Frozen-source standalone PWA: 2/2 with original timeouts. WebKit buyer interactions: 12/12. Visual matrix: 84/84, both engines at 375/390/1280; zero axe; max Chromium CLS .0369458128 (WebKit observer unavailable). 78 stress combinations and six Saved journeys passed. Real Rails search/filter → choose ticket → guest checkout/reload passed without an order. Real Clerk and physical devices not run.

Frozen-source full Chromium is 164/164 with 15s assertions/60s budgets, no retries/skips. Default-timeout failures in unchanged organizer flows remain documented. Frozen-source units are 2022 passed/3 skipped. Heading-order and portal regression pass in both engines. Preserve the raw history.

## Remaining

1. Verify actual final PR head and required CI. The full local Chromium result is 164/164 with the documented timing allowance; stock-timeout runs remain non-green.
2. CodeRabbit hit its OSS limit. Requested once at https://github.com/Shimizu-Technology/HafaPass/pull/170#issuecomment-6454711017. Its success-labelled status was skipped/rate-limited; required review remains incomplete. Handle eventual findings.
3. Clean the owned invalid DB record when shared checkpoints recover.
4. **The lead merges; this agent must not merge.**

## Local resources

Rails 3066, Vite 5236, T3 QA tab and fixture contexts are stopped/closed. Final harnesses are stopped; lifecycle cleanup/status shows no active owned resources and all five task ports have no listeners. No running-resource handoff is authorized. Preserve held worktree/branch.

**Unresolved cleanup:** synthetic `hafapass_buyer_pages_test` remains with `datconnlimit=-2`. A verified drop waited >8 minutes on PostgreSQL `CheckpointStart`, then was cancelled; a bounded retry timed out. Zero task connections/drop processes remain. Shared Postgres is protected and was never restarted/stopped.

## Start here

Verify workspace/head and read the ledger. Query from maintenance DB:

```sh
psql postgres://localhost/postgres -c "SELECT datname, datconnlimit FROM pg_database WHERE datname = 'hafapass_buyer_pages_test'"
```

When checkpoints are healthy, remove only this name:

```sh
PGOPTIONS='-c statement_timeout=30000' dropdb -h localhost hafapass_buyer_pages_test
```

If still waiting, leave the protected service unchanged and coordinate with its owner. No private buyer data or credentials were used.
