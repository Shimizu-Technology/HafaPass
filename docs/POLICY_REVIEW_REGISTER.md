# HåfaPass Policy and Professional Review Register

Status: **not approved for production**. Engineering has created versioned surfaces and acceptance snapshots; professionals must supply the governing language and sign-off.

| Artifact | App route | Engineering version | Required approver | Evidence required | Current state |
|---|---|---|---|---|---|
| Buyer terms | `/policies/buyer-terms` | `2026-07-pilot-draft` | Guam/US counsel | approved document, effective date, reviewer | Pending |
| Organizer agreement | `/policies/organizer-agreement` | `2026-07-pilot-draft` | Counsel + accounting | signed terms, liability/fees/reserves/tax review | Pending |
| Privacy policy | `/policies/privacy` | `2026-07-pilot-draft` | Privacy counsel | data map, processor list, rights/breach review | Pending |
| Refund/cancellation | `/policies/refunds` | `2026-07-pilot-draft` | Counsel + accounting + provider | fee/refund/dispute timing and liability | Pending |
| Acceptable use | `/policies/acceptable-use` | `2026-07-pilot-draft` | Counsel + trust/safety owner | prohibited-event and enforcement review | Pending |
| Data retention | `/policies/retention` | `2026-07-pilot-draft` | Counsel + privacy + accounting | approved schedule and deletion/legal-hold procedure | Pending |

## Engineering controls

- Public checkout rejects an absent or stale buyer-terms version and stores version, digest, and acceptance time on the order.
- Organizer publication requires acceptance of the current organizer-agreement version and digest.
- Policy content is rendered as React text, never raw organizer HTML.
- Replacing a policy changes its version/digest and therefore requires new acceptance.
- Approval evidence belongs in the controlled legal/operations record system. Do not commit signatures, phone numbers, private legal advice, or personal identity documents to this repository.

The current digest is a technical content-family fingerprint, not proof of legal approval. Before launch, replace draft copy with approved text, update the version/canonical digest input, run checkout/publication regression tests, and record the approval evidence.
