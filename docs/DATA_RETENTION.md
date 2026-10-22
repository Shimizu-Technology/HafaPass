# HåfaPass data retention schedule

**Engineering draft, 22 October 2026. Counsel and CPA confirmation required before live purge is enabled.** The executable table inventory is [`hafapass_api/config/data_retention.yml`](../hafapass_api/config/data_retention.yml). It classifies each application table that can hold personal or financial information, names its trigger column, period, action, and fields that require privacy review. Changes to a table or sensitive column must update that file and its coverage spec.

| Record class | Clock starts | Proposed period | Expiry action | Reason to confirm |
|---|---|---|---|---|
| Completed orders, payments, refunds, disputes, payouts, settlements, fees, tax and audit records | End of the calendar year of completion, payment, certification, or creation as configured | 7 years after year end | Remove personal fields; keep amounts, status, identifiers and accounting links | Accounting, tax, chargeback and audit evidence. CPA and counsel must confirm the exact records and start dates. |
| Buyer details on a completed order, tickets and answers | End of the completed order's year | Up to the financial retention point | Anonymize | Order totals and admission evidence remain useful without buyer contact information. A verified deletion request can anonymize earlier if there is no hold or unresolved money operation. |
| Organizer tax/TIN and payout identity | End of the year of certification or payout | 7 years after year end | Anonymize tax identity and payee snapshots; keep transaction totals | W-9 and payout evidence may have different legal periods. Confirm with CPA. |
| Marketing withdrawal proof | Withdrawal time | 3 years | Delete | Retain evidence of the opt-out and suppress sends during that period. Confirm whether a longer suppression record is needed. |
| Unlinked marketplace analytics | Event time | 13 months | Delete | Existing analytics limit; linked order attribution follows the financial record. |
| Private organizer sales exports | File creation | 2 days | Delete S3 object and request row | Existing two-day export window. Active legal holds stop both the cleanup job and orphan sweep. |
| Abandoned or expired pending orders with no captured money or tickets | Expiry or abandonment | 90 days | Delete dependent checkout and inventory records, then order | Remove unused buyer contact details; any payment, refund, ticket, request or legal hold blocks disposal. |
| Active user accounts and organizer operating data | While account or event remains active | No automatic account deletion | Keep; handle verified request | Automatic inactivity deletion could interrupt tickets, membership, event operations or payouts. |
| User uploads in S3 | Account or event lifecycle | No automatic account deletion | Delete on an eligible verified deletion request | An upload may be a live event asset. Counsel should set a post-event period. |
| Scanner and device evidence, operational review records | Creation or event activity as configured | 7 years where audit evidence; otherwise event lifecycle | Keep or anonymize as configured | Scanner admission evidence can matter in refunds or disputes. Device local storage also needs an operator policy. |

The `keep` action means the financial or audit row remains after its seven-year review point. It does **not** mean all personal details remain: the order, payout, tax, audit, delivery and admission anonymizers remove the fields named in the configuration. Some event or account records remain active until a separate closure decision; the proposed period needs counsel review. The schedule is deliberately conservative where a row participates in payment, audit, admission, or event integrity.

## Operation

`DataRetentionPurgeJob` runs daily through Solid Queue in batches of 100. It logs table counts and dry-run state only. Production starts with `site_settings.retention_purge_enabled = false`; an admin can enable it in Settings after review. `DATA_RETENTION_DRY_RUN=true` forces dry run regardless of that setting. Enabling or disabling is audited. A hold on an organization, event, order, user, or buyer email prevents purge and deletion for matching records. Open disputes, pending refunds and pending or held payouts block order anonymization and a deletion request.

The admin privacy queue shows what a request will anonymize, delete, retain, and why. An admin verifies the requester before execution. Guest requests require the existing signed order link sent through verified email recovery. Access exports use a seven-day signed JSON download link. If S3 or Clerk removal fails or is not configured, the request records a manual completion step in the queue. The operations owner must resolve those steps and confirm the provider result; a partial status is not complete erasure.

## Review questions

- Confirm seven-year clocks for W-9 certifications, Stripe evidence, payout checks, audit logs and buyer orders; some may need longer periods or a different year-end date.
- Decide when organizer accounts, event assets, scanner devices and local offline manifests may be closed and disposed.
- Confirm how marketing suppression is preserved after the three-year proof record is deleted.
- Confirm whether other jurisdictions require additional access, deletion, or breach procedures for remote buyers.

See [`docs/COUNSEL_REVIEW_PACKET.md`](COUNSEL_REVIEW_PACKET.md) for the broader legal and accounting questions. This schedule does not amend the live policy register or approve the proposed periods.
