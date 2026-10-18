# Independent release review evidence

The normal release capture uses a completed, authenticated, current-head GitHub CodeRabbit review. When the user explicitly authorizes independent review, a repository maintainer may instead supply truthful completed agent or CodeRabbit CLI reports. A skipped GitHub status remains a skipped review. This path changes review provenance, not CI, branch protection, conversation resolution, local QA, launch acceptance, or human/provider approvals.

## Trusted operator boundary

The capture verifies the currently authenticated `gh` user's live repository `admin` or `maintain` permission. That identity must match the bundle's operator. The operator explicitly attests the user's independent-review authorization and inspects the actual report authors, outcomes, findings, and limits. Software verifies source, scope, timestamps and bytes; it cannot establish that a report's author honestly performed the review. Possessing a JSON file or setting a boolean is not that approval.

Keep the bundle and reports in a restricted local directory. Reports must be nonempty text `.md`, `.txt`, `.log`, `.json`, or `.jsonl` files inside that directory (including subdirectories), at most 2 MB each. Do not include secrets, customer data, private legal advice, or provider payloads. The capture archives verified report bytes beneath the private candidate directory with mode `0600`; it never uploads the reports.

## Bundle contract (format version 1)

Every field below is required; missing completion, findings, or limits never defaults to a pass.

| Field | Required value |
|---|---|
| `format_version` | Integer `1` |
| `repository`, `source_pr` | Exact repository name and integer source PR number |
| `head_sha`, `head_tree` | Actual source PR head and its Git tree digest, not the later main merge digest |
| `outcome` | `no_unresolved_material_findings`, after inspecting all component findings and the integrated result |
| `authorization.operator_login` | Current authenticated maintainer's GitHub login |
| `authorization.reference` | Traceable reference to the user's explicit independent-review instruction |
| `authorization.approved_at` | Actual ISO-8601 approval timestamp, never future dated |
| `authorization.statement` | `I accept these reviews under the user's independent-review authorization.` |
| `reviews` | Nonempty array of completed report records described below |

Each report has:

| Field | Required value |
|---|---|
| `id` | Unique lowercase letter/number/underscore/hyphen identifier, at most 64 characters |
| `kind` | `independent_agent` or `coderabbit_cli` |
| `status` | `completed`; pending, unavailable, skipped and rate-limited runs do not qualify |
| `outcome` | `no_material_findings`, `nonblocking_findings`, or `material_findings_resolved` |
| `scope` | `changed_files` |
| `reviewer_ids` | Actual named reviewer identities, including agent identifiers or CLI reviewer identity; no empty list |
| `completed_at` | Actual ISO-8601 completion timestamp, never future dated |
| `reviewed_sha`, `reviewed_tree` | Immutable commit/tree actually reviewed |
| `covered_files` | Nonempty explicit list of repository-relative reviewed paths |
| `report_path`, `report_sha256` | Report path relative to bundle directory and exact SHA-256 of its original bytes |
| `limitations` | Array of actual scope/verification limits; use an empty array only when there are none |
| `findings` | Array of actual findings; use an empty array only when there are none |

A finding requires `reference` and `disposition`, plus either `severity: material` / `status: resolved`, or `severity: nonblocking` / `status: documented`. An unresolved, unclassified or contradictory material finding blocks capture. A report with material findings cannot claim `no_material_findings`.

The union of covered paths must equal the actual paginated source PR file list. One reviewed component does not cover the rest of the PR. Report authors must review the changed code and relevant interactions; path coverage is a provenance check, not automatic proof of correctness.

A report may cover the exact head or an ancestor commit. For ancestor reuse, every covered path's mode, object type and blob must be identical at the current head. A later change to any covered file requires fresh review of that file. The capture retains both reviewed and source SHA/tree bindings and verified file objects. Deleted paths are explicitly recorded as deleted. Do not rewrite an older report's reviewed SHA to imply it reviewed later code.

For CLI reports, retain the actual JSONL `--agent` output. Its final event must be `type: complete`, `status: review_completed`, with `reviewedFiles` matching the declared scope and `findings` matching the triaged finding records. A connection/setup event or capacity failure is not completion. The CLI's output does not independently authenticate a Git SHA; the trusted operator must verify its execution commit and record that binding truthfully.

## Capture

After the candidate PR is safely merged and the exact main merge commit has passed its complete local and GitHub gates:

```sh
scripts/release_candidate.rb --candidate pilot-rc-YYYY-MM-DD.N \
  --independent-review-evidence /restricted/review-bundle/bundle.json \
  --accept-independent-review
```

The concise acknowledgement is required together with the bundle; neither option silently selects a fallback. The unchanged GitHub CodeRabbit status/App protection must still pass. The manifest records `provider: independent`, the operator authorization, original report digests, exact coverage/bindings, and observed GitHub status/review payloads. It never represents the skipped bot as a submitted review.

Capture leaves engineering-lead and founder approvals pending. All Gate B–J evidence, required hosted acceptance, production capability approvals, actual provider permissions and physical/device/drill evidence remain separate. Complete Gate A human approvals and owner assignments before the matching tag/freeze. Complete the applicable later gates before production activation under their operating procedures.
