# HafaPass Release Candidate Operations

Status: required Gate A procedure
Last verified: July 21, 2026 (Pacific/Guam)
Parent plan: [Platform Completion Audit](PLATFORM_COMPLETION_AUDIT.md)

## Purpose

Production, provider, accessibility, and pilot evidence is valid only when it points to one immutable application/database candidate. This procedure freezes that contract without placing secrets, identity documents, payment data, or private approvals in Git.

Gate A is complete only when the automated capture, protected-branch controls, private register, human approvals, and annotated tag all identify the same commit.

## Repository controls

`main` must be protected with:

- Pull requests required, including for administrators.
- Strict required status checks: backend RSpec, backend quality/security, frontend quality/build/security, browser smoke tests, repository hygiene, and the release-freeze contract.
- Greptile required on pull requests.
- Review conversations resolved before merge.
- Force pushes and branch deletion disabled.

During a release freeze, the repository variable `RELEASE_FREEZE` contains the active candidate ID. Every pull request is then blocked by `Release / Freeze contract` until a maintainer adds the `release-approved` label. Adding or removing the label reruns the contract check. The label means the change was deliberately admitted to the frozen candidate; it does not replace tests or review.

To end a freeze after the pilot is closed or deliberately abandoned, archive the evidence first and then remove the repository variable. Never disable branch protection merely to merge a change.

## Create the exact candidate

Start only after the candidate PR is merged and the exact `main` commit has green GitHub checks:

```bash
git switch main
git pull --ff-only origin main
scripts/release_candidate.rb --candidate pilot-rc-YYYY-MM-DD.N
```

The command deliberately refuses to proceed unless:

- The current branch is `main` and tracked files are clean.
- `HEAD` exactly equals the freshly fetched `origin/main`.
- `HEAD` is a GitHub PR merge commit.
- The full local `scripts/gate.sh` succeeds on that exact checkout.
- Every required check passed on the exact merge commit.
- The source PR has all required checks, a successful Greptile review, and no unresolved thread.
- No open issue is labeled or titled P0/P1.
- Branch protection enforces the required contract.

It writes two mode-`0600` files beneath `.release-evidence/<candidate-id>/`:

- `candidate.json`: commit, backend/frontend release IDs, schema version/hash, dependency-lock hashes, local gate result, CI/review state, blocker state, and branch-protection state.
- `evidence-register.md`: private Gate A–J owners, due dates, evidence IDs, approvals, references, exceptions, and issues.

The directory is gitignored. Store its approved copy in the restricted operations system chosen by the founder. Do not attach it wholesale to a public issue or PR.

## Human approval and tag

The engineering lead confirms the exact commit/schema. The founder confirms the release freeze and scope. Every later gate must have a named primary/backup and due date. Any exception requires an owner, expiry, risk statement, and issue/reference.

Only after those fields are complete:

```bash
git tag -a pilot-rc-YYYY-MM-DD.N -m "HafaPass pilot release candidate YYYY-MM-DD.N"
git push origin pilot-rc-YYYY-MM-DD.N
gh variable set RELEASE_FREEZE --body "pilot-rc-YYYY-MM-DD.N"
```

Verify the tag cannot drift:

```bash
test "$(git rev-list -n 1 pilot-rc-YYYY-MM-DD.N)" = "$(git rev-parse HEAD)"
gh variable get RELEASE_FREEZE
```

## Change admission during the freeze

1. Open a focused PR from the frozen `main`.
2. Explain which Gates B–J it affects and what evidence, pilot run, or closeout decision it invalidates.
3. A maintainer adds `release-approved` only after reviewing that impact.
4. Run the normal CI and Greptile loop.
5. Merge, capture a new candidate ID, update every affected evidence reference, and retire—not move—the old tag.

Never retag an existing candidate. An immutable failed or superseded candidate remains useful audit history.

## Exit evidence

- Candidate JSON and private register exist with restrictive permissions.
- Human Gate A approvals, Gate B–J owners, and due dates are recorded.
- `main` protection and the release-freeze check are active.
- The annotated tag, `main`, manifest commit, release IDs, and schema version agree.
- Exact-commit local gate, CI, Greptile, P0/P1, and review-thread evidence is retained.
- Any exception has explicit ownership, expiry, risk, and traceable remediation.
