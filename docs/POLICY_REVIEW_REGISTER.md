# HåfaPass Policy and Professional Review Register

Status: **not approved for production**. The served text is `2026-10-launch-draft` (`status: draft-pending-legal-review` in `config/policies.yml`): substantially fuller drafts written by engineering for counsel to review. No document below has legal, accounting or privacy approval. Professionals must supply or confirm the governing language and sign off. Open points for counsel and the accountant are listed below under **Outstanding legal-review items**, not in the public text. See [Legal and Tax Briefing](LEGAL_AND_TAX_BRIEFING.md) for the open questions.

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
- Policy text names the platform, operator (Shimizu Technology), support contact, current fee schedule and payout timing through placeholders (`{{platform_name}}`, `{{operator_name}}`, `{{support_contact}}`, `{{fee_schedule}}`, `{{payout_schedule}}`) filled from admin settings when served. An unknown placeholder fails loudly instead of being served.
- Digests never hash the rendered text. They cover the unrendered templates plus a digest of the material terms only: service fee percent, flat fee, card-processing bearer and payout timing. Editing the platform name, support email or phone leaves every digest, organizer acceptance and policy-register approval intact. Changing a material term changes the organizer-agreement and buyer-terms digests and the registry digest, so organizers must accept again and the policy register needs a new approval; the admin settings screen says so before saving.
- While the YAML `status` is anything other than `approved`, an admin can still approve the policy register for launch, but only after ticking: "I'm approving these draft policies for launch before legal review. HåfaPass will update them after counsel reviews." The acknowledgment is stored as the approval's reason and in the audit log metadata (`draft_policies_acknowledged`, `policy_version`). Approval is blocked only for technical problems: an unknown or unfilled template placeholder, or a bracketed drafting note left in the public text. Public pages keep the "Draft pending legal review" banner while the status is draft.
- Acceptance snapshots: buyers accept buyer terms, privacy, refunds, acceptable use and retention at every checkout (version checked; version and digest stored on the order). Organizers accept the organizer agreement (version and digest). The cookie notice and accessibility statement are notices, not part of either acceptance snapshot, but they are part of the registry digest the policy-register approval binds to.
- Changing the version from `2026-07-pilot-draft` to `2026-10-launch-draft` makes every earlier organizer acceptance stale (re-accept from the organizer dashboard) and invalidates any policy-register approval recorded for the old digest.
- The snapshot digest covers the exact served document content and version; replacing policy text therefore changes the digest and requires a deliberate version/reacceptance decision.
- Approval evidence belongs in the controlled legal/operations record system. Do not commit signatures, phone numbers, private legal advice, or personal identity documents to this repository.

The content-bound digest is technical evidence of which text was served, not proof of legal approval. Before launch, replace draft copy with approved text, update the version, run checkout/publication regression tests, and record the approval evidence.

After professional approval, submit the controlled record reference and SHA-256 digest through `/admin/provider-readiness` under **Production policy register**. An administrator (the submitter may approve) must approve the exact snapshot. While policies are still drafts, the approval requires the explicit draft-launch acknowledgment; the one-click **Approve now** on the admin dashboard asks for the same acknowledgment. The resulting application approval expires and is automatically invalidated by any policy version or content change. See [Gate D Provider and Policy Evidence](GATE_D_PROVIDER_POLICY_EVIDENCE.md).

## Outstanding legal-review items

These are kept out of the public text. The same list lives under `review_notes` in `config/policies.yml`, and the admin register shows it (for information; it does not block approval). Update both together.

| Policy | Section | Item |
|---|---|---|
| Buyer Terms | Limits on our responsibility | Lawyer to confirm limitation wording and any consumer-law carve-outs. |
| Buyer Terms | Governing law and disputes | Lawyer to confirm governing law and venue. |
| Privacy Policy | How long we keep it | Lawyer and accountant to confirm the retention period (at least 7 years proposed). |
| Organizer Agreement | Our role as your limited agent | Lawyer to confirm agency and funds-handling language. |
| Organizer Agreement | Tax information | Accountant to confirm tax treatment and reporting. |
| Organizer Agreement | Chargebacks and negative balances | Lawyer to confirm payment terms and dispute-fee allocation. |
| Organizer Agreement | Indemnity and limitation of liability | Lawyer to confirm indemnity and the 12-month fee liability cap. |
| Organizer Agreement | Governing law and changes | Lawyer to confirm governing law and venue. |
| Data Retention Schedule | Financial, order, and audit records | Lawyer and accountant to confirm the retention period (at least 7 years proposed). |

## Agent-of-payee and tax safeguards review (2026-10-21)

These points mirror `review_notes` in `config/policies.yml`. The public drafts
keep their existing version and draft banner; this work is not professional approval.

- Counsel: confirm the limited appointment solely to accept ticket payments, buyer
  discharge, organizer as seller, and exclusion of HåfaPass from the ticket contract.
  Confirm check disbursements under FinCEN FIN-2014-R009 and Guam 11 GCA Ch. 109;
  the wording alone does not establish a licensing exemption. Review custody,
  segregated accounts, withholding, offsets, refund shortfalls, and indemnity.
- Accountant: confirm fee-only BPT treatment, the current rate, organizer gross
  receipts, form/filer/thresholds for 1099 reporting, Guam filing, and backup withholding.
- Counsel/accountant: review the electronic substitute W-9, signer authority,
  certification wording, U.S.-person eligibility, disregarded LLC treatment,
  tax-record retention, and handling of people subject to backup withholding or
  needing another form. The product validates nine digits, not the TIN/name match.
- Privacy counsel: confirm collection of organizer TINs, encryption, audited admin
  reveals and full-TIN exports, legally required tax-authority sharing, retention,
  and breach response. Current W-9 identity can differ from historical check payees.

Reference for the substitute-form review: [IRS requester instructions](https://www.irs.gov/instructions/iw9),
including electronic submission and certification requirements (checked 2026-10-21).
