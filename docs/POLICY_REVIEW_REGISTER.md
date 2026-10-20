# HåfaPass Policy and Professional Review Register

Status: **not approved for production**. The served text is `2026-10-launch-draft` (`status: draft-pending-legal-review` in `config/policies.yml`): substantially fuller drafts written by engineering for counsel to review. No document below has legal, accounting or privacy approval. Professionals must supply or confirm the governing language and sign off. Points still open are marked `[Lawyer to confirm]` / `[Accountant to confirm]` in the text. See [Legal and Tax Briefing](LEGAL_AND_TAX_BRIEFING.md) for the open questions.

| Artifact | App route | Engineering version | Required approver | Evidence required | Current state |
|---|---|---|---|---|---|
| Buyer terms | `/policies/buyer-terms` | `2026-10-launch-draft` | Guam/US counsel | approved document, effective date, reviewer | Draft pending legal review |
| Organizer agreement | `/policies/organizer-agreement` | `2026-10-launch-draft` | Counsel + accounting | signed terms, liability/fees/reserves/tax review | Draft pending legal review |
| Privacy policy | `/policies/privacy` | `2026-10-launch-draft` | Privacy counsel | data map, processor list, rights/breach review | Draft pending legal review |
| Refund/cancellation | `/policies/refunds` | `2026-10-launch-draft` | Counsel + accounting + provider | fee/refund/dispute timing and liability | Draft pending legal review |
| Acceptable use | `/policies/acceptable-use` | `2026-10-launch-draft` | Counsel + trust/safety owner | prohibited-event and enforcement review | Draft pending legal review |
| Data retention | `/policies/retention` | `2026-10-launch-draft` | Counsel + privacy + accounting | approved schedule and deletion/legal-hold procedure | Draft pending legal review |
| Cookie notice | `/policies/cookies` | `2026-10-launch-draft` | Privacy counsel | cookie/local-storage inventory review | Draft pending legal review |
| Accessibility statement | `/policies/accessibility` | `2026-10-launch-draft` | Counsel + accessibility reviewer | WCAG conformance claim and contact process | Draft pending legal review |

## Engineering controls

- Public checkout rejects an absent or stale buyer-terms version and stores version, digest, and acceptance time on the order.
- Organizer publication requires acceptance of the current organizer-agreement version and digest.
- Policy content is loaded from the backend's authoritative `config/policies.yml` registry and rendered as React text, never raw HTML.
- Policy text names the platform, operator (Shimizu Technology), support email, current fee schedule and payout timing through placeholders (`{{platform_name}}`, `{{operator_name}}`, `{{support_email}}`, `{{fee_schedule}}`, `{{payout_schedule}}`) filled from admin settings when served. Digests cover the rendered text, so changing the platform name, support email, fee terms or payout timing changes the organizer-agreement digest and organizers must re-accept before publishing again. An unknown placeholder fails loudly instead of being served.
- Acceptance snapshots: buyers accept buyer terms, privacy, refunds, acceptable use and retention at every checkout (version checked; version and digest stored on the order). Organizers accept the organizer agreement (version and digest). The cookie notice and accessibility statement are notices, not part of either acceptance snapshot, but they are part of the registry digest the policy-register approval binds to.
- Changing the version from `2026-07-pilot-draft` to `2026-10-launch-draft` makes every earlier organizer acceptance stale (re-accept from the organizer dashboard) and invalidates any policy-register approval recorded for the old digest.
- The snapshot digest covers the exact served document content and version; replacing policy text therefore changes the digest and requires a deliberate version/reacceptance decision.
- Approval evidence belongs in the controlled legal/operations record system. Do not commit signatures, phone numbers, private legal advice, or personal identity documents to this repository.

The content-bound digest is technical evidence of which text was served, not proof of legal approval. Before launch, replace draft copy with approved text, update the version, run checkout/publication regression tests, and record the approval evidence.

After professional approval, submit the controlled record reference and SHA-256 digest through `/admin/provider-readiness` under **Production policy register**. A second administrator must approve the exact snapshot. The resulting application approval expires and is automatically invalidated by any policy version or content change. See [Gate D Provider and Policy Evidence](GATE_D_PROVIDER_POLICY_EVIDENCE.md).
