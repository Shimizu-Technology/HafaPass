# Audit action registry

Verified 2026-10-23 against base commit `b4679ad0` in the isolated
`t3/audit-action-registry` worktree. HafaPass serves event organizers and door
staff, with ticket sales, admission, refunds and settlement workflows. This
registry defines which parts of its private audit history each organization role
may see. It does not grant permissions to perform those actions.

Context: [project overview](../README.md), [repository instructions](../CLAUDE.md),
[current logger](../hafapass_api/app/services/audit_logger.rb) and
[append-only record](../hafapass_api/app/models/audit_log.rb). The local source is
the implementation baseline; deployment and database behavior are outside this
worker's verification. The project brief also reflects the
[2026-10-04 portfolio review](/Users/leonshimizu/Desktop/ShimizuTechnology/Brain-Dump/work/shimizu-tech/company-positioning-and-project-review-2026-10-04.md),
which describes HafaPass as ticketing and operations software with paid-launch
and operated-pilot gates still open at that time.

## Contract

`AuditActions.fetch(action)` returns an immutable hash with these symbol keys:

| Key | Value |
| --- | --- |
| `:area` | One string from `AuditActions::AREAS`. |
| `:audience` | Array of role strings: `org_owner`, `org_manager`, `org_finance`, or exclusively `admin_only`. |
| `:tenant` | Boolean: the logger must resolve an organization when true. |
| `:event_required` | Boolean: the logger must resolve an event when true. |
| `:organization_fields` | Hash with `:before_data`, `:after_data`, and `:metadata` string field allowlists. |
| `:template` | Plain English sentence describing the action without private interpolation. |

`AuditActions.tenant?(action)` and `AuditActions.event_required?(action)` return
those explicit booleans. `registered?(action)` distinguishes a registered key
from the fallback. `keys` returns all registered keys. `visible_to?(action,
audience)` checks the audience array. Action keys accept strings or symbols.

Unknown keys return `admin_only`, area `platform`, false scope requirements and
empty organization field allowlists. Unknown keys are never made visible by
matching a known prefix. Their false scope requirements allow private recording
without pretending the registry knows their tenant model. The coverage spec must
fail before an unknown recorded action is integrated.

```ruby
definition = AuditActions.fetch(action)
# definition[:audience].include?("admin_only")
AuditActions.tenant?(action)
AuditActions.event_required?(action)

safe = AuditActions.organization_payload(action,
  before_data: log.before_data, after_data: log.after_data, metadata: log.metadata)
# => { before_data: { "status" => "pending" },
#      after_data: { "status" => "paid" }, metadata: { "amount_cents" => 100 } }
```

`organization_payload` returns the three symbol column keys above, with string
keys inside each projected hash. Only explicitly allowed scalar strings,
numbers, booleans and nil survive; hashes, arrays and other objects are dropped.
It preserves zero and false. Private audit columns are not changed. Admin-only
and unknown actions return three empty hashes. Apply audience authorization
before returning a projected row; an empty payload does not itself authorize a
row. Request IDs, IP addresses, buyer contacts, freeform internal notes,
verification notes, review evidence, provider payloads and arbitrary filter or
column objects have no organization-visible allowlist entry. Export request IDs
are domain identifiers, distinct from HTTP request IDs.

## Visibility and scope decisions

Owners see every organization-visible definition. Managers see operational event,
event staff, scanning, door, messaging and export-summary history. Finance staff
see orders, refunds, payouts, fees, tax-status and finance-export history. The
card-present outcome summaries are shared with managers and finance staff.
Organization-wide team role and ownership changes are owner-only; event staff
assignment changes are available to managers.

Support lookups and notes, platform roles/settings/invitations, internal event
policy holds, capability/readiness/pilot evidence, legal holds and privacy
requests remain admin-only. Organizer verification exposes status and version
fields to owners; it excludes notes, evidence, phone numbers and links. Payout
setup exposes status flags, while internal readiness decisions remain admin-only.
Tax B-notice and IRS evidence actions remain private; the withholding-status
change has a finance-visible summary.

Audience and scope are independent. `support.note_created` is private but must
resolve the organization from its order, ticket or event subject. Platform tax
exports, platform settings, capability reviews, support lookups and platform
invitations have no mandatory tenant. Privacy requests and legal holds can target
a user or buyer across organizations, so a tenant is not mandatory. Delivery
replays can target platform notices, so a tenant is not mandatory there either.
Tenant-scoped readiness reviews need an organization without an event. Finance
exports support both an event and an organization-wide source and therefore do
not require an event. Event staff changes always require the affected event,
including implicit grant/revocation callbacks. A scope flag is a requirement,
not a prohibition on attaching additional verified scope.

`campaign.send_completed` means **queued for delivery**. It does not claim
provider acceptance or recipient delivery. The integration's new `source` and
`outcome` columns are not reconstructed for older rows: existing NULL values mean
unknown. Registry templates describe the action and do not supply missing
historical provenance or outcomes.

## Source inventory and acceptance

The base contains **122 `AuditLogger.record!` call sites in 74 files**, with
**155 distinct literal keys**. Eleven more definitions enumerate two constructed
families, giving 166 definitions for existing code. Ten keys supplied by the
integration worker bring this registry to **176 definitions**. These integration
keys are registered here before their emitting code is brought into this
worktree. Other workers' final keys must be registered and added to the table
when the root integrates their commits.

The database-free RSpec coverage check parses Ruby with Ripper. It inventories
action-shaped literals across every emitter file, including helper arguments,
default values, constants, assignments, ternaries and export callbacks. SQL
column arguments and calls to the separate seating audit store are excluded.
It discovers emitters from the parsed `AuditLogger.record!` call rather than a
line-format match. It also fingerprints both interpolated expressions and reads
the corresponding model enums from source, so a changed expression or added
enum value requires registry coverage. The test intentionally inventories a
conservative superset of helper literals in emitter files. It is a source
contract for these explicit families, not a general Ruby runtime evaluator;
new computed families or externally supplied action parameters must add an
explicit source inventory instead of accepting arbitrary strings.

| Constructed family | Source and exhaustive possible keys |
| --- | --- |
| `live_pilot_run.#{kind}` | `LivePilotRunAction` kind enum: `started`, `paused`, `resumed`, `completed`, `aborted`. |
| `payout.#{attributes.fetch(:status)}` | `Payout` status enum: `pending`, `processing`, `paid`, `failed`, `reversed`, `held`. All six are registered, including statuses not currently returned by an adapter. |

Helper-forwarded literal families include `payment_readiness`,
`connected_account.readiness_*`, `platform_capability`, `pilot_readiness`,
`pilot_validation`, `event_day_rehearsal`, `live_money_proof` (including its four
authorization actions), `live_pilot`, `pilot_closeout`, `live_pilot_incident`,
`live_pilot_metrics`, `refund_reconciliation`, `card_present.payment_*`,
`event_staff`, `sales.export_*`, and payout conflict/withholding/late-result
branches. `Operations::SyntheticDataPurge::ACTION` supplies
`operations.synthetic_data_purged`. Both values in organizer creation/update,
verification-request and admission-reversal conditionals are covered. Team
invitation acceptance keeps `organization.invitation_accepted` when moved into
the model; callback-driven event staff changes keep the same three assignment
keys.

Acceptance: every recorded key and enum member is registered; unknown keys are
private; tenant/event requirements are explicit; every organization-visible
definition includes the owner; projections contain only approved fields; every
key has a plain English sentence; all registry keys appear in the coverage
table. The focused spec runs without Rails or a database. The root owns logger
integration, full Rails tests and end-to-end authorization acceptance.

## Coverage table

Audience abbreviations: **O** = `org_owner`, **M** = `org_manager`, **F** =
`org_finance`, **A** = `admin_only`. Snapshot fields apply independently to both
`before_data` and `after_data`; metadata fields apply only to `metadata`.
`—` means an empty allowlist. Origin **L** means an existing literal, **D** a
constructed enum member, and **I** an integration-worker addition.

| Action | Area | Audience | Tenant | Event | Snapshot fields | Metadata fields | Sentence | Origin |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `annual_tax_report.exported` | tax | A | no | no | — | — | Exported platform annual tax reports. | L |
| `annual_tax_report.setting_updated` | tax | A | no | no | — | — | Updated annual tax report settings. | L |
| `annual_tax_report.statement_downloaded` | tax | O/F | yes | no | — | `year` | Downloaded an annual tax statement. | L |
| `annual_tax_thresholds.updated` | tax | A | no | no | — | — | Updated annual tax thresholds. | L |
| `balance_adjustment.posted` | fees | O/F | yes | no | `id`, `kind`, `amount_cents`, `currency`, `status`, `effective_at`, `event_id` | `original_adjustment_id` | Posted an organization balance adjustment. | L |
| `balance_adjustment.reversed` | fees | O/F | yes | no | `id`, `kind`, `amount_cents`, `currency`, `status`, `effective_at`, `event_id` | `original_adjustment_id` | Reversed an organization balance adjustment. | L |
| `campaign.created` | messaging | O/M | yes | yes | `status`, `scheduled_at` | `campaign_id`, `recipient_count` | Created a campaign. | I |
| `campaign.deleted` | messaging | O/M | yes | yes | `status`, `scheduled_at` | `campaign_id`, `recipient_count` | Deleted a campaign. | I |
| `campaign.scheduled` | messaging | O/M | yes | yes | `status`, `scheduled_at` | `campaign_id`, `recipient_count` | Scheduled a campaign. | I |
| `campaign.send_completed` | messaging | O/M | yes | yes | `status`, `scheduled_at` | `campaign_id`, `recipient_count` | Queued a campaign for delivery. | I |
| `campaign.send_failed` | messaging | O/M | yes | yes | `status`, `scheduled_at` | `campaign_id`, `recipient_count` | Failed to queue a campaign for delivery. | I |
| `campaign.send_requested` | messaging | O/M | yes | yes | `status`, `scheduled_at` | `campaign_id`, `recipient_count` | Requested a campaign send. | I |
| `campaign.updated` | messaging | O/M | yes | yes | `status`, `scheduled_at` | `campaign_id`, `recipient_count` | Updated a campaign. | I |
| `card_present.account_updated` | payout_settings | A | yes | no | — | — | Updated a card-present merchant account. | L |
| `card_present.payment_failed` | door | O/M/F | yes | yes | `status`, `amount_cents` | `lifecycle_result` | Failed a card-present payment. | L |
| `card_present.payment_result_unknown` | door | O/M/F | yes | yes | `status`, `amount_cents` | `lifecycle_result` | Flagged an unknown card-present payment result. | L |
| `card_present.payment_succeeded` | door | O/M/F | yes | yes | `status`, `amount_cents` | `lifecycle_result` | Completed a card-present payment. | L |
| `connected_account.onboarding_started` | payout_settings | O/F | yes | no | `provider`, `status`, `charges_enabled`, `payouts_enabled`, `details_submitted`, `last_synced_at` | — | Started payout account setup. | L |
| `connected_account.payout_details_updated` | payout_settings | O/F | yes | no | `provider`, `status`, `charges_enabled`, `payouts_enabled`, `details_submitted`, `last_synced_at` | — | Updated payout account details. | L |
| `connected_account.readiness_approved` | payout_settings | A | yes | no | — | — | Approved payout account readiness. | L |
| `connected_account.readiness_recomputed` | payout_settings | A | yes | no | — | — | Recomputed payout account readiness. | L |
| `connected_account.readiness_revoked` | payout_settings | A | yes | no | — | — | Revoked payout account readiness approval. | L |
| `connected_account.synced` | payout_settings | A | yes | no | — | — | Synchronized payout account provider data. | L |
| `event.cancellation_card_refunded` | refunds | O/F | yes | yes | `status`, `amount_cents`, `refunded_cents` | `order_id`, `refund_id`, `run_id`, `amount_cents` | Requested a card refund for a cancelled event. | L |
| `event.cancellation_cash_refunded` | refunds | O/F | yes | yes | `status`, `amount_cents`, `refunded_cents` | `order_id`, `refund_id`, `run_id`, `amount_cents` | Recorded a cash refund for a cancelled event. | L |
| `event.cancellation_refund_amount_changed` | refunds | O/F | yes | yes | `status`, `amount_cents`, `refunded_cents` | `order_id`, `refund_id`, `run_id`, `amount_cents` | Updated the cancellation refund amount. | L |
| `event.cancellation_refunds_completed` | refunds | O/F | yes | yes | `status`, `amount_cents`, `refunded_cents` | `order_id`, `refund_id`, `run_id`, `amount_cents` | Completed cancellation refunds. | L |
| `event.cancellation_refunds_started` | refunds | O/F | yes | yes | `status`, `amount_cents`, `refunded_cents` | `order_id`, `refund_id`, `run_id`, `amount_cents` | Started cancellation refunds. | L |
| `event.legacy_cancellation_refunds_started` | refunds | O/F | yes | yes | `status`, `amount_cents`, `refunded_cents` | `order_id`, `refund_id`, `run_id`, `amount_cents` | Started cancellation refunds for legacy orders. | L |
| `event.page_customized` | events | O/M | yes | yes | `sales_suspended_at` | — | Updated the event page design. | L |
| `event.policy_hold_lifted` | events | A | yes | yes | — | — | Released an event policy hold. | L |
| `event.policy_hold_placed` | events | A | yes | yes | — | — | Placed an event policy hold. | L |
| `event.preview_link_rotated` | events | O/M | yes | yes | `sales_suspended_at` | — | Replaced the event preview link. | L |
| `event.sales_resumed` | events | O/M | yes | yes | `sales_suspended_at` | — | Resumed event ticket sales. | L |
| `event_day_rehearsal.approved` | platform | A | yes | yes | — | — | Approved event-day rehearsal evidence. | L |
| `event_day_rehearsal.rejected` | platform | A | yes | yes | — | — | Rejected event-day rehearsal evidence. | L |
| `event_day_rehearsal.revoked` | platform | A | yes | yes | — | — | Revoked event-day rehearsal approval. | L |
| `event_day_rehearsal.submitted` | platform | A | yes | yes | — | — | Submitted event-day rehearsal evidence. | L |
| `event_staff.assigned` | team | O/M | yes | yes | `event_id`, `role`, `status`, `expires_at` | — | Assigned event staff. | L |
| `event_staff.invitation_revoked` | team | O/M | yes | yes | `event_id`, `role`, `status`, `expires_at` | — | Revoked an event staff invitation. | L |
| `event_staff.revoked` | team | O/M | yes | yes | `event_id`, `role`, `status`, `expires_at` | — | Revoked an event staff assignment. | L |
| `event_staff.updated` | team | O/M | yes | yes | `event_id`, `role`, `status`, `expires_at` | — | Updated an event staff assignment. | L |
| `finance.exported` | exports | O/F | yes | no | — | `row_count`, `format`, `scope`, `event_id`, `export` | Exported a finance summary. | L |
| `guest_purchase.recovered` | orders | O/F | yes | yes | — | `recovered_tickets` | Linked a guest purchase to its buyer account. | L |
| `legal_hold.placed` | privacy | A | no | no | — | — | Placed a legal hold. | L |
| `legal_hold.released` | privacy | A | no | no | — | — | Released a legal hold. | L |
| `live_money_proof.approved` | platform | A | yes | yes | — | — | Approved live-money proof evidence. | L |
| `live_money_proof.authorization_approved` | platform | A | yes | yes | — | — | Approved live-money proof authorization. | L |
| `live_money_proof.authorization_consumed` | platform | A | yes | yes | — | — | Used live-money proof authorization. | L |
| `live_money_proof.authorization_requested` | platform | A | yes | yes | — | — | Requested live-money proof authorization. | L |
| `live_money_proof.authorization_revoked` | platform | A | yes | yes | — | — | Revoked live-money proof authorization. | L |
| `live_money_proof.rejected` | platform | A | yes | yes | — | — | Rejected live-money proof evidence. | L |
| `live_money_proof.revoked` | platform | A | yes | yes | — | — | Revoked live-money proof approval. | L |
| `live_money_proof.submitted` | platform | A | yes | yes | — | — | Submitted live-money proof evidence. | L |
| `live_pilot.approved` | platform | A | yes | yes | — | — | Approved live pilot evidence. | L |
| `live_pilot.rejected` | platform | A | yes | yes | — | — | Rejected live pilot evidence. | L |
| `live_pilot.revoked` | platform | A | yes | yes | — | — | Revoked live pilot approval. | L |
| `live_pilot.submitted` | platform | A | yes | yes | — | — | Submitted live pilot evidence. | L |
| `live_pilot_incident.reported` | platform | A | yes | yes | — | — | Reported a live pilot incident. | L |
| `live_pilot_incident.resolved` | platform | A | yes | yes | — | — | Resolved a live pilot incident. | L |
| `live_pilot_metrics.recorded` | platform | A | yes | yes | — | — | Recorded live pilot metrics. | L |
| `live_pilot_run.aborted` | platform | A | yes | yes | — | — | Aborted a live pilot run. | D |
| `live_pilot_run.completed` | platform | A | yes | yes | — | — | Completed a live pilot run. | D |
| `live_pilot_run.paused` | platform | A | yes | yes | — | — | Paused a live pilot run. | D |
| `live_pilot_run.resumed` | platform | A | yes | yes | — | — | Resumed a live pilot run. | D |
| `live_pilot_run.started` | platform | A | yes | yes | — | — | Started a live pilot run. | D |
| `message_delivery.replayed` | messaging | A | no | no | — | — | Replayed a message delivery. | L |
| `operations.synthetic_data_purged` | platform | A | no | no | — | — | Purged synthetic platform data. | L |
| `order.fulfillment_resent` | messaging | O/M | yes | yes | — | `message_delivery_id` | Resent ticket fulfillment. | L |
| `organization.created` | organization | O | yes | no | `name`, `business_name`, `business_description` | — | Created the organization. | L |
| `organization.created_by_admin` | organization | O | yes | no | `name`, `business_name`, `business_description` | — | Created the organization on behalf of its owner. | L |
| `organization.invitation_accepted` | team | O | yes | no | `role`, `status`, `accepted_at`, `revoked_at`, `expires_at` | `membership_id` | Accepted a team invitation. | L |
| `organization.invitation_created` | team | O | yes | no | `role`, `status`, `accepted_at`, `revoked_at`, `expires_at` | `membership_id` | Invited a team member. | L |
| `organization.invitation_resent` | team | O | yes | no | `role`, `status`, `accepted_at`, `revoked_at`, `expires_at` | `membership_id` | Resent a team invitation. | L |
| `organization.marketing_postal_address_updated` | organization | O | yes | no | `name`, `business_name`, `business_description` | — | Updated the organization marketing postal address. | L |
| `organization.membership_revoked` | team | O | yes | no | `role`, `status`, `accepted_at`, `revoked_at`, `expires_at` | `membership_id` | Revoked team access. | L |
| `organization.membership_updated` | team | O | yes | no | `role`, `status`, `accepted_at`, `revoked_at`, `expires_at` | `membership_id` | Updated team access. | L |
| `organization.ownership_transferred` | team | O | yes | no | `role`, `status`, `accepted_at`, `revoked_at`, `expires_at` | `membership_id` | Transferred organization ownership. | L |
| `organization.updated` | organization | O | yes | no | `name`, `business_name`, `business_description` | — | Updated organization details. | L |
| `organizer.policy_accepted` | organization | O | yes | no | `policy_version`, `policy_accepted_at` | — | Accepted the organizer agreement. | L |
| `organizer.verification_request_updated` | verification | O | yes | no | `verification_status`, `verification_requested_at`, `verification_request_version`, `verified_at` | — | Updated an organizer verification request. | L |
| `organizer.verification_requested` | verification | O | yes | no | `verification_status`, `verification_requested_at`, `verification_request_version`, `verified_at` | — | Requested organizer verification. | L |
| `organizer.verification_updated` | verification | O | yes | no | `verification_status`, `verification_requested_at`, `verification_request_version`, `verified_at` | — | Updated organizer verification status. | L |
| `organizer_tax_information.updated` | tax | O/F | yes | no | — | `certification_version` | Updated organizer tax information. | L |
| `payment_readiness.approved` | platform | A | yes | no | — | — | Approved payment readiness evidence. | L |
| `payment_readiness.rejected` | platform | A | yes | no | — | — | Rejected payment readiness evidence. | L |
| `payment_readiness.revoked` | platform | A | yes | no | — | — | Revoked payment readiness approval. | L |
| `payment_readiness.submitted` | platform | A | yes | no | — | — | Submitted payment readiness evidence. | L |
| `payout.backup_withholding_overridden` | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents` | Overrode payout backup withholding. | L |
| `payout.backup_withholding_recalculated` | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents` | Recalculated payout backup withholding. | L |
| `payout.check_amount_adjusted` | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents` | Adjusted a payout check amount. | L |
| `payout.failed` | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents` | Marked a payout failed. | D |
| `payout.held` | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents` | Marked a payout held. | D |
| `payout.held_for_cancellation` | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents` | Held a payout for event cancellation. | L |
| `payout.late_result_held` | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents` | Kept a late payout result on hold. | L |
| `payout.late_result_ignored` | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents` | Ignored a late payout result. | L |
| `payout.paid` | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents` | Marked a payout paid. | D |
| `payout.pending` | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents` | Marked a payout pending. | D |
| `payout.processing` | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents` | Marked a payout processing. | D |
| `payout.provider_result_conflict` | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents` | Flagged conflicting payout provider results. | L |
| `payout.reconciled` | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents` | Reconciled a payout. | L |
| `payout.released_from_cancellation_hold` | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents` | Released a payout cancellation hold. | L |
| `payout.reversed` | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents` | Marked a payout reversed. | D |
| `payout.under_withholding_carried` | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents` | Carried a payout withholding shortfall. | L |
| `payout.under_withholding_collected` | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents` | Collected a payout withholding shortfall. | L |
| `payout.withholding_review_required` | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents` | Flagged a payout for withholding review. | L |
| `pilot_closeout.approved` | platform | A | yes | yes | — | — | Approved pilot closeout evidence. | L |
| `pilot_closeout.rejected` | platform | A | yes | yes | — | — | Rejected pilot closeout evidence. | L |
| `pilot_closeout.revoked` | platform | A | yes | yes | — | — | Revoked pilot closeout approval. | L |
| `pilot_closeout.submitted` | platform | A | yes | yes | — | — | Submitted pilot closeout evidence. | L |
| `pilot_readiness.approved` | platform | A | yes | yes | — | — | Approved pilot readiness evidence. | L |
| `pilot_readiness.rejected` | platform | A | yes | yes | — | — | Rejected pilot readiness evidence. | L |
| `pilot_readiness.revoked` | platform | A | yes | yes | — | — | Revoked pilot readiness approval. | L |
| `pilot_readiness.submitted` | platform | A | yes | yes | — | — | Submitted pilot readiness evidence. | L |
| `pilot_validation.approved` | platform | A | yes | yes | — | — | Approved pilot validation evidence. | L |
| `pilot_validation.rejected` | platform | A | yes | yes | — | — | Rejected pilot validation evidence. | L |
| `pilot_validation.revoked` | platform | A | yes | yes | — | — | Revoked pilot validation approval. | L |
| `pilot_validation.submitted` | platform | A | yes | yes | — | — | Submitted pilot validation evidence. | L |
| `platform.activity_logging_started` | platform | A | no | no | — | — | Started platform activity logging. | I |
| `platform.invitation_accepted` | platform | A | no | no | — | — | Accepted a platform invitation. | L |
| `platform.invitation_created` | platform | A | no | no | — | — | Created a platform invitation. | L |
| `platform.invitation_resent` | platform | A | no | no | — | — | Resent a platform invitation. | L |
| `platform.invitation_revoked` | platform | A | no | no | — | — | Revoked a platform invitation. | L |
| `platform_capability.approved` | platform | A | no | no | — | — | Approved platform capability evidence. | L |
| `platform_capability.rejected` | platform | A | no | no | — | — | Rejected platform capability evidence. | L |
| `platform_capability.revoked` | platform | A | no | no | — | — | Revoked platform capability approval. | L |
| `platform_capability.submitted` | platform | A | no | no | — | — | Submitted platform capability evidence. | L |
| `privacy_request.executed` | privacy | A | no | no | — | — | Executed a privacy request. | L |
| `privacy_request.submitted` | privacy | A | no | no | — | — | Submitted a privacy request. | L |
| `privacy_request.verified` | privacy | A | no | no | — | — | Verified a privacy request. | L |
| `refund.created` | refunds | O/F | yes | yes | `status`, `amount_cents` | `order_id`, `amount_cents` | Requested a refund. | L |
| `refund_reconciliation.action_attempted` | refunds | O/F | yes | yes | `status`, `amount_cents` | `operation`, `retry_refund_id`, `amount_cents`, `order_id`, `refund_id`, `provider_status` | Attempted a refund reconciliation action. | L |
| `refund_reconciliation.cancellation_retry` | refunds | O/F | yes | yes | `status`, `amount_cents` | `operation`, `retry_refund_id`, `amount_cents`, `order_id`, `refund_id`, `provider_status` | Retried a cancellation refund. | L |
| `refund_reconciliation.manual_return` | refunds | O/F | yes | yes | `status`, `amount_cents` | `operation`, `retry_refund_id`, `amount_cents`, `order_id`, `refund_id`, `provider_status` | Recorded a manual refund return. | L |
| `refund_reconciliation.overdue` | refunds | O/F | yes | yes | `status`, `amount_cents` | `operation`, `retry_refund_id`, `amount_cents`, `order_id`, `refund_id`, `provider_status` | Flagged an overdue refund. | L |
| `refund_reconciliation.request_executed` | refunds | O/F | yes | yes | `status`, `amount_cents` | `operation`, `retry_refund_id`, `amount_cents`, `order_id`, `refund_id`, `provider_status` | Executed an approved refund request. | L |
| `refund_reconciliation.resynced` | refunds | O/F | yes | yes | `status`, `amount_cents` | `operation`, `retry_refund_id`, `amount_cents`, `order_id`, `refund_id`, `provider_status` | Refreshed the refund provider status. | L |
| `refund_reconciliation.retry` | refunds | O/F | yes | yes | `status`, `amount_cents` | `operation`, `retry_refund_id`, `amount_cents`, `order_id`, `refund_id`, `provider_status` | Retried a refund. | L |
| `refund_reconciliation.unable` | refunds | O/F | yes | yes | `status`, `amount_cents` | `operation`, `retry_refund_id`, `amount_cents`, `order_id`, `refund_id`, `provider_status` | Could not complete refund reconciliation. | L |
| `sales.door_list_exported` | exports | O/M | yes | yes | — | `row_count`, `export_request_id`, `outcome`, `view` | Exported an event door list. | L |
| `sales.emergency_door_list_exported` | exports | O/M | yes | yes | — | `row_count`, `export_request_id`, `outcome`, `view` | Exported an emergency event door list. | L |
| `sales.export_download_failed` | exports | O/M | yes | yes | — | `row_count`, `export_request_id`, `outcome`, `view` | Failed to download an event sales export. | L |
| `sales.export_downloaded` | exports | O/M | yes | yes | — | `row_count`, `export_request_id`, `outcome`, `view` | Downloaded an event sales export. | L |
| `sales.export_failed` | exports | O/M | yes | yes | — | `row_count`, `export_request_id`, `outcome`, `view` | Failed to generate an event sales export. | L |
| `sales.export_generated` | exports | O/M | yes | yes | — | `row_count`, `export_request_id`, `outcome`, `view` | Generated an event sales export. | L |
| `sales.export_requested` | exports | O/M | yes | yes | — | `row_count`, `export_request_id`, `outcome`, `view` | Requested an event sales export. | L |
| `sales.exported` | exports | O/M | yes | yes | — | `row_count`, `export_request_id`, `outcome`, `view` | Exported an event sales summary. | L |
| `scanner_device.authorized` | scanning | O/M | yes | yes | `status` | `event_id` | Authorized an event scanner device. | L |
| `scanner_device.manifest_downloaded` | scanning | O/M | yes | yes | `status` | `event_id`, `manifest_version`, `entry_count` | Downloaded an event scanner manifest. | I |
| `scanner_device.renamed` | scanning | O/M | yes | yes | `status` | `event_id`, `manifest_version`, `entry_count` | Renamed an event scanner device. | I |
| `scanner_device.revoked` | scanning | O/M | yes | yes | `status` | `event_id` | Revoked an event scanner device. | L |
| `settlement.finalized` | payouts | O/F | yes | yes | `gross_cents`, `discount_cents`, `refund_cents`, `net_cents`, `platform_fee_cents`, `processing_fee_cents`, `platform_processing_fee_cents`, `organizer_proceeds_cents`, `reserve_cents`, `adjustment_cents`, `payable_cents`, `paid_cents`, `negative_balance_cents`, `version` | `settlement_id` | Finalized an event settlement. | L |
| `site_settings.fee_change_acknowledged` | fees | O/F | yes | no | — | `fee_change_id` | Acknowledged an upcoming fee change. | L |
| `site_settings.fee_change_notice_skipped` | fees | A | yes | no | — | — | Skipped a fee change notice delivery. | L |
| `site_settings.fee_terms_activated` | platform | A | no | no | — | — | Activated platform fee terms. | L |
| `site_settings.fee_terms_activation_blocked` | platform | A | no | no | — | — | Blocked platform fee term activation. | L |
| `site_settings.fee_terms_scheduled` | platform | A | no | no | — | — | Scheduled platform fee terms. | L |
| `site_settings.fee_terms_updated` | platform | A | no | no | — | — | Updated platform fee terms. | L |
| `site_settings.payment_mode_changed` | platform | A | no | no | — | — | Changed the platform payment mode. | L |
| `site_settings.retention_purge_changed` | platform | A | no | no | — | — | Changed platform retention purge settings. | L |
| `site_settings.updated` | platform | A | no | no | — | — | Updated platform settings. | L |
| `support.lookup` | platform | A | no | no | — | — | Looked up a support subject. | L |
| `support.note_created` | platform | A | yes | no | — | — | Added an internal support note. | L |
| `tax_information.b_notice_generated` | tax | A | yes | no | — | — | Generated a tax B notice. | L |
| `tax_information.b_notice_sent` | tax | A | yes | no | — | — | Sent a tax B notice. | L |
| `tax_information.irs_notice_received` | tax | A | yes | no | — | — | Recorded receipt of a tax notice. | L |
| `tax_information.second_b_notice_validated` | tax | A | yes | no | — | — | Validated a second tax B notice. | L |
| `tax_information.withholding_flag_changed` | tax | O/F | yes | no | `backup_withholding_required`, `tin_matching_status` | — | Updated tax withholding status. | L |
| `tax_report.exported` | tax | A | no | no | — | — | Exported platform tax reports. | L |
| `ticket.admission_reconciled` | scanning | O/M | yes | yes | `result`, `reason_code`, `ticket_id` | `event_id` | Reconciled a ticket admission. | L |
| `ticket.check_in_reversed` | scanning | O/M | yes | yes | `result`, `reason_code`, `ticket_id` | `event_id` | Reversed a ticket check-in. | L |
| `ticket.checked_in` | scanning | O/M | yes | yes | `result`, `reason_code`, `ticket_id` | `event_id` | Checked in a ticket. | L |
| `tin_matching.exported` | tax | A | no | no | — | — | Exported a taxpayer identification matching batch. | L |
| `tin_matching.import_failed` | tax | A | no | no | — | — | Failed to import taxpayer identification matching results. | L |
| `tin_matching.imported` | tax | A | no | no | — | — | Imported taxpayer identification matching results. | L |
| `user.role_updated` | platform | A | no | no | — | — | Updated a platform user role. | L |

## Verification and integration handoff

- Passed: `bundle exec rspec spec/services/audit_actions_spec.rb` (13 examples).
- Passed: `bundle exec rubocop app/services/audit_actions.rb spec/services/audit_actions_spec.rb`.
- Not run by this worker: full Rails/database suite, logger integration, browser
  journeys, deployment checks. No DB, server, browser, simulator or container was
  started. No long-running development resources need cleanup or handoff.
- Scope: only the registry service, its spec, and this document. No policy file,
  PR, merge, schema change or logger change belongs to this worker.

The root should refresh the literal inventory and counts after integrating the
other workers. New actions must supply an area, audience, mandatory scope,
explicit field allowlists and sentence before becoming organization-visible.
