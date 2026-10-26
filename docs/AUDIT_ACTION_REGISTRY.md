# Audit action registry

Verified against base commit `b4679ad0`, refreshed for main `473e3ccb` and the integrated audit foundation in
`codex/hafapass-audit-integrity`. HafaPass serves event organizers and door
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
| `:audience_variants` | Viewer-specific field allowlists and optional sentence templates, selected by `organization_definition(action, audience:)`. |

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

safe = AuditActions.organization_payload(action, audience: :org_finance,
  before_data: log.before_data, after_data: log.after_data, metadata: log.metadata)
# => { before_data: { "status" => "pending" },
#      after_data: { "status" => "paid" }, metadata: { "amount_cents" => 100 } }
```

`organization_payload` returns the three symbol column keys above, with string
keys inside each projected hash. Only explicitly allowed scalar strings,
numbers, booleans and nil survive; hashes, arrays and other objects are dropped.
It preserves zero and false. `audience` selects the viewer-specific allowlist;
callers authorize rows separately. Organization search scans rendered sentences
and displayed labels in bounded batches, including current event labels, never
hidden stored metadata. Private audit columns are not changed. Admin-only
and unknown actions return three empty hashes. Apply audience authorization
before returning a projected row; an empty payload does not itself authorize a
row. Request IDs, IP addresses, buyer contacts, freeform internal notes,
verification notes, review evidence, provider payloads and arbitrary filter or
column objects have no organization-visible allowlist entry. Export request IDs
are domain identifiers, distinct from HTTP request IDs.

## Visibility and scope decisions

Owners see every organization-visible definition. Managers see operational event,
event staff, scanning, door, messaging and export-summary history. Finance staff
see orders, refunds, payouts, fees, annual tax statements and finance exports.
Door-sale summaries are shared, but Managers receive only event/ticket-count
context and generic door outcomes: no transaction amounts, order identifiers,
currency, provider status or lifecycle details. Owner and Finance retain the full
money sentences. Ticket prices and other event configuration remain visible.
Guest-list, waitlist-offer and catalog-fulfillment Manager snapshots also exclude
order and order-item identifiers. Registry audience variants define these
allowlists and sentences; JSON, CSV and search use the same projection.
Organization team, ownership, verification, payout settings and tax settings are
Owner-only. Event staff has its own `event_staff` area under event operations and
is limited to the Manager's accessible events.

Support lookups and notes, platform roles/settings/invitations, internal event
policy holds, capability/readiness/pilot evidence, legal holds and privacy
requests remain admin-only. Organizer verification exposes status and version
fields to owners; it excludes notes, evidence, phone numbers and links. Payout
setup exposes status flags, while internal readiness decisions remain admin-only.
Tax B-notice and IRS evidence actions remain private; withholding-status and
tax-information changes are Owner-only.

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

The completeness spec parses Ruby with Ripper. It checks literals in audit emitter
files and model callback registrations, explicitly inventories interpolated
expressions, expands callback CRUD keys and enum transitions, and fails when a
new emitted key has no definition. Unknown runtime keys still fail closed to
administrator-only visibility.

Generic callback CRUD is replaced for ticket operations and waitlist joins;
EventStateChange supplies the six lifecycle transitions. Refunds, provider work,
waitlists, transfers and fulfillment use finite action families. Private notes,
contact details, credentials and raw search terms are never organization fields.
The projection also drops nested objects and arrays under allowed keys.

## Coverage table

Audience abbreviations: **O** = `org_owner`, **M** = `org_manager`, **F** =
`org_finance`, **A** = `admin_only`. Snapshot fields apply independently to both
`before_data` and `after_data`; metadata fields apply only to `metadata`.
`—` means an empty allowlist. The table includes finite supported callback and
enum branches; it does not assert that each branch has occurred. Legacy action
keys remain defined so old records can still be interpreted. Fields and sentences
below show the default Owner/Finance projection where those audiences are granted.
Manager overrides for door, guest-list, waitlist-offer and catalog-fulfillment
entries are described above and defined in the registry's audience variants.

| Action | Logged | Area | Audience | Tenant | Event | Snapshot fields | Metadata fields | Sentence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `accessible_seat.released` | yes | events | O/M | yes | yes | `operational_status` | `event_seat_id`, `ticket_id`, `venue_layout_id`, `event_seat_count`, `previous_event_seat_id`, `target_event_seat_id`, `event_title` | Released an accessible seat. |
| `annual_tax_report.exported` | yes | tax | A | no | no | — | — | Exported platform annual tax reports. |
| `annual_tax_report.setting_updated` | yes | tax | A | no | no | — | — | Updated annual tax report settings. |
| `annual_tax_report.statement_downloaded` | yes | tax | O/F | yes | no | — | `year`, `event_title` | Downloaded an annual tax statement. |
| `annual_tax_thresholds.updated` | yes | tax | A | no | no | — | — | Updated annual tax thresholds. |
| `balance_adjustment.posted` | yes | fees | O/F | yes | no | `id`, `kind`, `amount_cents`, `currency`, `status`, `effective_at`, `event_id` | `original_adjustment_id`, `event_title` | Posted an organization balance adjustment. |
| `balance_adjustment.reversed` | yes | fees | O/F | yes | no | `id`, `kind`, `amount_cents`, `currency`, `status`, `effective_at`, `event_id` | `original_adjustment_id`, `event_title` | Reversed an organization balance adjustment. |
| `box_office.cash_sale_created` | yes | door | O/M/F | yes | yes | `order_id`, `amount_cents`, `currency`, `ticket_count` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title`, `order_reference`, `amount_cents`, `currency` | Recorded a box office cash sale. |
| `campaign.created` | yes | messaging | O/M | yes | yes | `status`, `scheduled_at` | `campaign_id`, `recipient_count`, `event_title`, `subject_label` | Created a campaign. |
| `campaign.deleted` | yes | messaging | O/M | yes | yes | `status`, `scheduled_at` | `campaign_id`, `recipient_count`, `event_title`, `subject_label` | Deleted a campaign. |
| `campaign.reauthorization_failed` | yes | messaging | O/M | yes | yes | `status`, `scheduled_at` | `campaign_id`, `recipient_count`, `event_title`, `subject_label` | Blocked a campaign because the sender lost permission. |
| `campaign.recovered` | yes | messaging | O/M | yes | yes | `status`, `scheduled_at` | `campaign_id`, `recipient_count`, `event_title`, `subject_label` | Retried a campaign after authorized review. |
| `campaign.scheduled` | yes | messaging | O/M | yes | yes | `status`, `scheduled_at` | `campaign_id`, `recipient_count`, `event_title`, `subject_label` | Scheduled a campaign. |
| `campaign.send_completed` | yes | messaging | O/M | yes | yes | `status`, `scheduled_at` | `campaign_id`, `recipient_count`, `event_title`, `subject_label` | Queued a campaign for delivery. |
| `campaign.send_failed` | yes | messaging | O/M | yes | yes | `status`, `scheduled_at` | `campaign_id`, `recipient_count`, `event_title`, `subject_label` | Failed to queue a campaign for delivery. |
| `campaign.send_requested` | yes | messaging | O/M | yes | yes | `status`, `scheduled_at` | `campaign_id`, `recipient_count`, `event_title`, `subject_label` | Requested a campaign send. |
| `campaign.updated` | yes | messaging | O/M | yes | yes | `status`, `scheduled_at` | `campaign_id`, `recipient_count`, `event_title`, `subject_label` | Updated a campaign. |
| `card_present.account_updated` | yes | payout_settings | A | yes | no | — | — | Updated a card-present merchant account. |
| `card_present.payment_failed` | yes | door | O/M/F | yes | yes | `status`, `amount_cents` | `lifecycle_result`, `event_title`, `order_reference`, `amount_cents`, `currency` | Failed a card-present payment. |
| `card_present.payment_result_unknown` | yes | door | O/M/F | yes | yes | `status`, `amount_cents` | `lifecycle_result`, `event_title`, `order_reference`, `amount_cents`, `currency` | Flagged an unknown card-present payment result. |
| `card_present.payment_succeeded` | yes | door | O/M/F | yes | yes | `status`, `amount_cents` | `lifecycle_result`, `event_title`, `order_reference`, `amount_cents`, `currency` | Completed a card-present payment. |
| `catalog_fulfillment.cancelled` | yes | attendees | O/M | yes | yes | `order_item_id`, `status`, `fulfilled_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Cancelled catalog fulfillment. |
| `catalog_fulfillment.created` | yes | attendees | O/M | yes | yes | `order_item_id`, `status`, `fulfilled_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Created a catalog fulfillment. |
| `catalog_fulfillment.deleted` | yes | attendees | O/M | yes | yes | `order_item_id`, `status`, `fulfilled_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Deleted a catalog fulfillment. |
| `catalog_fulfillment.fulfilled` | yes | attendees | O/M | yes | yes | `order_item_id`, `status`, `fulfilled_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Fulfilled catalog fulfillment. |
| `catalog_fulfillment.pending` | yes | attendees | O/M | yes | yes | `order_item_id`, `status`, `fulfilled_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Pending catalog fulfillment. |
| `catalog_fulfillment.updated` | yes | attendees | O/M | yes | yes | `order_item_id`, `status`, `fulfilled_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Updated a catalog fulfillment. |
| `catalog_item.created` | yes | tickets | O/M | yes | yes | `event_id`, `kind`, `price_cents`, `minimum_price_cents`, `maximum_price_cents`, `inventory_quantity`, `active`, `position` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title`, `subject_label` | Created a catalog item. |
| `catalog_item.deleted` | yes | tickets | O/M | yes | yes | `event_id`, `kind`, `price_cents`, `minimum_price_cents`, `maximum_price_cents`, `inventory_quantity`, `active`, `position` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title`, `subject_label` | Deleted a catalog item. |
| `catalog_item.updated` | yes | tickets | O/M | yes | yes | `event_id`, `kind`, `price_cents`, `minimum_price_cents`, `maximum_price_cents`, `inventory_quantity`, `active`, `position` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title`, `subject_label` | Updated a catalog item. |
| `connected_account.destination_selected` | yes | payout_settings | O/F | yes | no | `payout_connected_account_id` | `event_title` | Selected the payout destination. |
| `connected_account.onboarding_started` | yes | payout_settings | O | yes | no | `provider`, `status`, `charges_enabled`, `payouts_enabled`, `details_submitted`, `last_synced_at` | `event_title` | Started payout account setup. |
| `connected_account.payout_details_updated` | yes | payout_settings | O | yes | no | `provider`, `status`, `charges_enabled`, `payouts_enabled`, `details_submitted`, `last_synced_at` | `event_title` | Updated payout account details. |
| `connected_account.readiness_approved` | yes | payout_settings | A | yes | no | — | — | Approved payout account readiness. |
| `connected_account.readiness_recomputed` | yes | payout_settings | A | yes | no | — | — | Recomputed payout account readiness. |
| `connected_account.readiness_revoked` | yes | payout_settings | A | yes | no | — | — | Revoked payout account readiness approval. |
| `connected_account.synced` | yes | payout_settings | A | yes | no | — | — | Synchronized payout account provider data. |
| `dispute.lost` | yes | disputes | O/F | yes | yes | `status`, `amount_cents`, `currency` | `order_id`, `payment_id`, `event_title`, `order_reference`, `amount_cents`, `currency` | Lost a payment dispute. |
| `dispute.opened` | yes | disputes | O/F | yes | yes | `status`, `amount_cents`, `currency` | `order_id`, `payment_id`, `event_title`, `order_reference`, `amount_cents`, `currency` | Opened a payment dispute. |
| `dispute.updated` | yes | disputes | O/F | yes | yes | `status`, `amount_cents`, `currency` | `order_id`, `payment_id`, `event_title`, `order_reference`, `amount_cents`, `currency` | Updated a payment dispute. |
| `dispute.won` | yes | disputes | O/F | yes | yes | `status`, `amount_cents`, `currency` | `order_id`, `payment_id`, `event_title`, `order_reference`, `amount_cents`, `currency` | Won a payment dispute. |
| `distribution_link.created` | yes | marketing_partners | O/M | yes | yes | `event_id`, `distribution_partner_id`, `active`, `expires_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Created a distribution link. |
| `distribution_link.deleted` | yes | marketing_partners | O/M | yes | yes | `event_id`, `distribution_partner_id`, `active`, `expires_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Deleted a distribution link. |
| `distribution_link.updated` | yes | marketing_partners | O/M | yes | yes | `event_id`, `distribution_partner_id`, `active`, `expires_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Updated a distribution link. |
| `event.archived` | yes | events | O/M | yes | yes | `status`, `organization_id`, `organizer_profile_id`, `venue_id`, `starts_at`, `ends_at`, `doors_open_at`, `timezone`, `category`, `age_restriction`, `max_capacity`, `fee_policy`, `buyer_fee_percent`, `is_featured`, `show_attendees`, `transfers_enabled`, `recurrence_parent_id`, `recurrence_rule`, `recurrence_end_date` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Archived event. |
| `event.cancellation_card_refunded` | yes | refunds | O/F | yes | yes | `status`, `amount_cents`, `refunded_cents` | `order_id`, `refund_id`, `run_id`, `amount_cents`, `event_title`, `order_reference`, `currency` | Requested a card refund for a cancelled event. |
| `event.cancellation_cash_refunded` | yes | refunds | O/F | yes | yes | `status`, `amount_cents`, `refunded_cents` | `order_id`, `refund_id`, `run_id`, `amount_cents`, `event_title`, `order_reference`, `currency` | Recorded a cash refund for a cancelled event. |
| `event.cancellation_refund_amount_changed` | yes | refunds | O/F | yes | yes | `status`, `amount_cents`, `refunded_cents` | `order_id`, `refund_id`, `run_id`, `amount_cents`, `event_title`, `order_reference`, `currency` | Updated the cancellation refund amount. |
| `event.cancellation_refunds_completed` | yes | refunds | O/F | yes | yes | `status`, `amount_cents`, `refunded_cents` | `order_id`, `refund_id`, `run_id`, `amount_cents`, `event_title`, `order_reference`, `currency` | Completed cancellation refunds. |
| `event.cancellation_refunds_started` | yes | refunds | O/F | yes | yes | `status`, `amount_cents`, `refunded_cents` | `order_id`, `refund_id`, `run_id`, `amount_cents`, `event_title`, `order_reference`, `currency` | Started cancellation refunds. |
| `event.cancelled` | yes | events | O/M | yes | yes | `status`, `organization_id`, `organizer_profile_id`, `venue_id`, `starts_at`, `ends_at`, `doors_open_at`, `timezone`, `category`, `age_restriction`, `max_capacity`, `fee_policy`, `buyer_fee_percent`, `is_featured`, `show_attendees`, `transfers_enabled`, `recurrence_parent_id`, `recurrence_rule`, `recurrence_end_date` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Cancelled event. |
| `event.cloned` | yes | events | O/M | yes | yes | `status`, `organization_id`, `organizer_profile_id`, `venue_id`, `starts_at`, `ends_at`, `doors_open_at`, `timezone`, `category`, `age_restriction`, `max_capacity`, `fee_policy`, `buyer_fee_percent`, `is_featured`, `show_attendees`, `transfers_enabled`, `recurrence_parent_id`, `recurrence_rule`, `recurrence_end_date` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Cloned event. |
| `event.completed` | yes | events | O/M | yes | yes | `status`, `organization_id`, `organizer_profile_id`, `venue_id`, `starts_at`, `ends_at`, `doors_open_at`, `timezone`, `category`, `age_restriction`, `max_capacity`, `fee_policy`, `buyer_fee_percent`, `is_featured`, `show_attendees`, `transfers_enabled`, `recurrence_parent_id`, `recurrence_rule`, `recurrence_end_date` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Completed event. |
| `event.created` | yes | events | O/M | yes | yes | `status`, `organization_id`, `organizer_profile_id`, `venue_id`, `starts_at`, `ends_at`, `doors_open_at`, `timezone`, `category`, `age_restriction`, `max_capacity`, `fee_policy`, `buyer_fee_percent`, `is_featured`, `show_attendees`, `transfers_enabled`, `recurrence_parent_id`, `recurrence_rule`, `recurrence_end_date` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Created an event. |
| `event.deleted` | yes | events | O/M | yes | yes | `status`, `organization_id`, `organizer_profile_id`, `venue_id`, `starts_at`, `ends_at`, `doors_open_at`, `timezone`, `category`, `age_restriction`, `max_capacity`, `fee_policy`, `buyer_fee_percent`, `is_featured`, `show_attendees`, `transfers_enabled`, `recurrence_parent_id`, `recurrence_rule`, `recurrence_end_date` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Deleted an event. |
| `event.legacy_cancellation_refunds_started` | yes | refunds | O/F | yes | yes | `status`, `amount_cents`, `refunded_cents` | `order_id`, `refund_id`, `run_id`, `amount_cents`, `event_title`, `order_reference`, `currency` | Started cancellation refunds for legacy orders. |
| `event.page_customized` | yes | events | O/M | yes | yes | `sales_suspended_at` | `event_title` | Updated the event page design. |
| `event.policy_hold_lifted` | yes | events | A | yes | yes | — | — | Released an event policy hold. |
| `event.policy_hold_placed` | yes | events | A | yes | yes | — | — | Placed an event policy hold. |
| `event.postponed` | yes | events | O/M | yes | yes | `status`, `organization_id`, `organizer_profile_id`, `venue_id`, `starts_at`, `ends_at`, `doors_open_at`, `timezone`, `category`, `age_restriction`, `max_capacity`, `fee_policy`, `buyer_fee_percent`, `is_featured`, `show_attendees`, `transfers_enabled`, `recurrence_parent_id`, `recurrence_rule`, `recurrence_end_date` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Postponed event. |
| `event.preview_link_rotated` | yes | events | O/M | yes | yes | `sales_suspended_at` | `event_title` | Replaced the event preview link. |
| `event.published` | yes | events | O/M | yes | yes | `status`, `organization_id`, `organizer_profile_id`, `venue_id`, `starts_at`, `ends_at`, `doors_open_at`, `timezone`, `category`, `age_restriction`, `max_capacity`, `fee_policy`, `buyer_fee_percent`, `is_featured`, `show_attendees`, `transfers_enabled`, `recurrence_parent_id`, `recurrence_rule`, `recurrence_end_date` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Published event. |
| `event.recurrence_created` | yes | events | O/M | yes | yes | `status`, `organization_id`, `organizer_profile_id`, `venue_id`, `starts_at`, `ends_at`, `doors_open_at`, `timezone`, `category`, `age_restriction`, `max_capacity`, `fee_policy`, `buyer_fee_percent`, `is_featured`, `show_attendees`, `transfers_enabled`, `recurrence_parent_id`, `recurrence_rule`, `recurrence_end_date` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Created a recurring event. |
| `event.resumed` | yes | events | O/M | yes | yes | `status`, `organization_id`, `organizer_profile_id`, `venue_id`, `starts_at`, `ends_at`, `doors_open_at`, `timezone`, `category`, `age_restriction`, `max_capacity`, `fee_policy`, `buyer_fee_percent`, `is_featured`, `show_attendees`, `transfers_enabled`, `recurrence_parent_id`, `recurrence_rule`, `recurrence_end_date` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Resumed event. |
| `event.sales_resumed` | yes | events | O/M | yes | yes | `sales_suspended_at` | `event_title` | Resumed event ticket sales. |
| `event.sales_suspended` | yes | events | O/M | yes | yes | `sales_suspended_at` | `event_title` | Paused event ticket sales. |
| `event.updated` | yes | events | O/M | yes | yes | `status`, `organization_id`, `organizer_profile_id`, `venue_id`, `starts_at`, `ends_at`, `doors_open_at`, `timezone`, `category`, `age_restriction`, `max_capacity`, `fee_policy`, `buyer_fee_percent`, `is_featured`, `show_attendees`, `transfers_enabled`, `recurrence_parent_id`, `recurrence_rule`, `recurrence_end_date` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Updated an event. |
| `event_day_rehearsal.approved` | yes | platform | A | yes | yes | — | — | Approved event-day rehearsal evidence. |
| `event_day_rehearsal.rejected` | yes | platform | A | yes | yes | — | — | Rejected event-day rehearsal evidence. |
| `event_day_rehearsal.revoked` | yes | platform | A | yes | yes | — | — | Revoked event-day rehearsal approval. |
| `event_day_rehearsal.submitted` | yes | platform | A | yes | yes | — | — | Submitted event-day rehearsal evidence. |
| `event_staff.assigned` | yes | event_staff | O/M | yes | yes | `event_id`, `role`, `status`, `expires_at`, `target_user_id`, `target_name` | `event_title`, `team_member_label`, `team_role` | Assigned event staff. |
| `event_staff.invitation_revoked` | yes | event_staff | O/M | yes | yes | `event_id`, `role`, `status`, `expires_at`, `target_user_id`, `target_name` | `event_title`, `team_member_label`, `team_role` | Revoked an event staff invitation. |
| `event_staff.revoked` | yes | event_staff | O/M | yes | yes | `event_id`, `role`, `status`, `expires_at`, `target_user_id`, `target_name` | `event_title`, `team_member_label`, `team_role` | Revoked an event staff assignment. |
| `event_staff.updated` | yes | event_staff | O/M | yes | yes | `event_id`, `role`, `status`, `expires_at`, `target_user_id`, `target_name` | `event_title`, `team_member_label`, `team_role` | Updated an event staff assignment. |
| `event_waiver.created` | yes | attendees | O/M | yes | yes | `event_id`, `active`, `required` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Created an event waiver. |
| `event_waiver.deleted` | yes | attendees | O/M | yes | yes | `event_id`, `active`, `required` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Deleted an event waiver. |
| `event_waiver.updated` | yes | attendees | O/M | yes | yes | `event_id`, `active`, `required` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Updated an event waiver. |
| `finance.exported` | yes | exports | O/F | yes | no | — | `row_count`, `format`, `scope`, `event_id`, `export`, `event_title` | Exported a finance summary. |
| `guest_list.created` | yes | attendees | O/M | yes | yes | `event_id`, `ticket_type_id`, `quantity`, `redeemed`, `order_id` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title`, `ticket_type_label`, `quantity` | Created a guest list entry. |
| `guest_list.deleted` | yes | attendees | O/M | yes | yes | `event_id`, `ticket_type_id`, `quantity`, `redeemed`, `order_id` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title`, `ticket_type_label`, `quantity` | Deleted a guest list entry. |
| `guest_list.redeemed` | yes | attendees | O/M | yes | yes | `event_id`, `ticket_type_id`, `quantity`, `redeemed`, `order_id` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title`, `ticket_type_label`, `quantity` | Redeemed guest list. |
| `guest_list.updated` | yes | attendees | O/M | yes | yes | `event_id`, `ticket_type_id`, `quantity`, `redeemed`, `order_id` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title`, `ticket_type_label`, `quantity` | Updated a guest list entry. |
| `guest_purchase.recovered` | yes | orders | O/F | yes | yes | — | `recovered_tickets`, `event_title`, `order_reference`, `amount_cents`, `currency` | Linked a guest purchase to its buyer account. |
| `legal_hold.placed` | yes | privacy | A | no | no | — | — | Placed a legal hold. |
| `legal_hold.released` | yes | privacy | A | no | no | — | — | Released a legal hold. |
| `live_money_proof.approved` | yes | platform | A | yes | yes | — | — | Approved live-money proof evidence. |
| `live_money_proof.authorization_approved` | yes | platform | A | yes | yes | — | — | Approved live-money proof authorization. |
| `live_money_proof.authorization_consumed` | yes | platform | A | yes | yes | — | — | Used live-money proof authorization. |
| `live_money_proof.authorization_requested` | yes | platform | A | yes | yes | — | — | Requested live-money proof authorization. |
| `live_money_proof.authorization_revoked` | yes | platform | A | yes | yes | — | — | Revoked live-money proof authorization. |
| `live_money_proof.rejected` | yes | platform | A | yes | yes | — | — | Rejected live-money proof evidence. |
| `live_money_proof.revoked` | yes | platform | A | yes | yes | — | — | Revoked live-money proof approval. |
| `live_money_proof.submitted` | yes | platform | A | yes | yes | — | — | Submitted live-money proof evidence. |
| `live_pilot.approved` | yes | platform | A | yes | yes | — | — | Approved live pilot evidence. |
| `live_pilot.rejected` | yes | platform | A | yes | yes | — | — | Rejected live pilot evidence. |
| `live_pilot.revoked` | yes | platform | A | yes | yes | — | — | Revoked live pilot approval. |
| `live_pilot.submitted` | yes | platform | A | yes | yes | — | — | Submitted live pilot evidence. |
| `live_pilot_incident.reported` | yes | platform | A | yes | yes | — | — | Reported a live pilot incident. |
| `live_pilot_incident.resolved` | yes | platform | A | yes | yes | — | — | Resolved a live pilot incident. |
| `live_pilot_metrics.recorded` | yes | platform | A | yes | yes | — | — | Recorded live pilot metrics. |
| `live_pilot_run.aborted` | yes | platform | A | yes | yes | — | — | Aborted a live pilot run. |
| `live_pilot_run.completed` | yes | platform | A | yes | yes | — | — | Completed a live pilot run. |
| `live_pilot_run.paused` | yes | platform | A | yes | yes | — | — | Paused a live pilot run. |
| `live_pilot_run.resumed` | yes | platform | A | yes | yes | — | — | Resumed a live pilot run. |
| `live_pilot_run.started` | yes | platform | A | yes | yes | — | — | Started a live pilot run. |
| `message_delivery.replayed` | yes | messaging | A | no | no | — | — | Replayed a message delivery. |
| `operations.synthetic_data_purged` | yes | platform | A | no | no | — | — | Purged synthetic platform data. |
| `order.agreement_accepted` | yes | orders | O/F | yes | yes | `policy_version`, `accepted_at` | `event_title`, `order_reference`, `amount_cents`, `currency` | Accepted the buyer agreement. |
| `order.cancelled` | yes | orders | O/F | yes | yes | `status` | `refund_id`, `amount_cents`, `currency`, `event_title`, `order_reference` | Cancelled an order. |
| `order.completed` | yes | orders | O/F | yes | yes | `status` | `refund_id`, `amount_cents`, `currency`, `event_title`, `order_reference` | Completed an order. |
| `order.expired` | yes | orders | O/F | yes | yes | `status` | `refund_id`, `amount_cents`, `currency`, `event_title`, `order_reference` | Expired an unpaid order. |
| `order.fulfillment_resent` | yes | messaging | O/M | yes | yes | — | `message_delivery_id`, `event_title` | Resent ticket fulfillment. |
| `order.partially_refunded` | yes | orders | O/F | yes | yes | `status` | `refund_id`, `amount_cents`, `currency`, `event_title`, `order_reference` | Partially refunded an order. |
| `order.refunded` | yes | orders | O/F | yes | yes | `status` | `refund_id`, `amount_cents`, `currency`, `event_title`, `order_reference` | Refunded an order. |
| `organization.created_by_admin` | yes | organization | O | yes | no | `name`, `business_name`, `business_description` | `event_title` | Created the organization on behalf of its owner. |
| `organization.created` | yes | organization | O | yes | no | `name`, `business_name`, `business_description` | `event_title` | Created the organization. |
| `organization.fee_terms_activated` | yes | fees | O/F | yes | no | `service_fee_percent`, `service_fee_flat_cents` | `event_title` | Activated fee terms for the organization. |
| `organization.invitation_accepted` | yes | team | O | yes | no | `role`, `status`, `accepted_at`, `revoked_at`, `expires_at`, `target_user_id`, `target_name` | `membership_id`, `event_title`, `team_member_label`, `team_role` | Accepted a team invitation. |
| `organization.invitation_created` | yes | team | O | yes | no | `role`, `status`, `accepted_at`, `revoked_at`, `expires_at`, `target_user_id`, `target_name` | `membership_id`, `event_title`, `team_member_label`, `team_role` | Invited a team member. |
| `organization.invitation_resent` | yes | team | O | yes | no | `role`, `status`, `accepted_at`, `revoked_at`, `expires_at`, `target_user_id`, `target_name` | `membership_id`, `event_title`, `team_member_label`, `team_role` | Resent a team invitation. |
| `organization.marketing_postal_address_updated` | yes | organization | O | yes | no | `name`, `business_name`, `business_description` | `event_title` | Updated the organization marketing postal address. |
| `organization.membership_revoked` | yes | team | O | yes | no | `role`, `status`, `accepted_at`, `revoked_at`, `expires_at`, `target_user_id`, `target_name` | `membership_id`, `event_title`, `team_member_label`, `team_role` | Revoked team access. |
| `organization.membership_updated` | yes | team | O | yes | no | `role`, `status`, `accepted_at`, `revoked_at`, `expires_at`, `target_user_id`, `target_name` | `membership_id`, `event_title`, `team_member_label`, `team_role` | Updated team access. |
| `organization.ownership_transferred` | yes | team | O | yes | no | `role`, `status`, `accepted_at`, `revoked_at`, `expires_at`, `target_user_id`, `target_name` | `membership_id`, `event_title`, `team_member_label`, `team_role` | Transferred organization ownership. |
| `organization.updated` | yes | organization | O | yes | no | `name`, `business_name`, `business_description` | `event_title` | Updated organization details. |
| `organizer.policy_accepted` | yes | organization | O | yes | no | `policy_version`, `policy_accepted_at`, `accepted_at` | `event_title` | Accepted the organizer agreement. |
| `organizer.verification_request_updated` | yes | verification | O | yes | no | `verification_status`, `verification_requested_at`, `verification_request_version`, `verified_at` | `event_title` | Updated an organizer verification request. |
| `organizer.verification_requested` | yes | verification | O | yes | no | `verification_status`, `verification_requested_at`, `verification_request_version`, `verified_at` | `event_title` | Requested organizer verification. |
| `organizer.verification_updated` | yes | verification | O | yes | no | `verification_status`, `verification_requested_at`, `verification_request_version`, `verified_at` | `event_title` | Updated organizer verification status. |
| `organizer_tax_information.updated` | yes | tax | O | yes | no | — | `certification_version`, `event_title` | Updated organizer tax information. |
| `payment_readiness.approved` | yes | platform | A | yes | no | — | — | Approved payment readiness evidence. |
| `payment_readiness.rejected` | yes | platform | A | yes | no | — | — | Rejected payment readiness evidence. |
| `payment_readiness.revoked` | yes | platform | A | yes | no | — | — | Revoked payment readiness approval. |
| `payment_readiness.submitted` | yes | platform | A | yes | no | — | — | Submitted payment readiness evidence. |
| `payout_method.approved` | yes | payout_settings | O, F | yes | no | `provider`, `organization_name`, `review_by` | `event_title` | HåfaPass approved the check/bank transfer payout method for the organization. |
| `payout_method.changes_requested` | yes | payout_settings | O, F | yes | no | `provider`, `organization_name`, `review_by` | `event_title` | HåfaPass asked for changes to the check/bank transfer payout method for the organization. |
| `payout.backup_withholding_overridden` | yes | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents`, `event_title`, `order_reference`, `currency` | Overrode payout backup withholding. |
| `payout.backup_withholding_recalculated` | yes | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents`, `event_title`, `order_reference`, `currency` | Recalculated payout backup withholding. |
| `payout.check_amount_adjusted` | yes | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents`, `event_title`, `order_reference`, `currency` | Adjusted a payout check amount. |
| `payout.created` | yes | payouts | O/F | yes | yes | `status`, `amount_cents`, `currency` | `amount_cents`, `currency`, `settlement_id`, `event_title`, `order_reference` | Reserved a payout. |
| `payout.failed` | yes | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents`, `event_title`, `order_reference`, `currency` | Marked a payout failed. |
| `payout.held_for_cancellation` | yes | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents`, `event_title`, `order_reference`, `currency` | Held a payout for event cancellation. |
| `payout.held` | yes | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents`, `event_title`, `order_reference`, `currency` | Marked a payout held. |
| `payout.late_result_held` | yes | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents`, `event_title`, `order_reference`, `currency` | Kept a late payout result on hold. |
| `payout.late_result_ignored` | yes | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents`, `event_title`, `order_reference`, `currency` | Ignored a late payout result. |
| `payout.paid` | yes | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents`, `event_title`, `order_reference`, `currency` | Marked a payout paid. |
| `payout.pending` | yes | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents`, `event_title`, `order_reference`, `currency` | Marked a payout pending. |
| `payout.processing` | yes | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents`, `event_title`, `order_reference`, `currency` | Marked a payout processing. |
| `payout.provider_result_conflict` | yes | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents`, `event_title`, `order_reference`, `currency` | Flagged conflicting payout provider results. |
| `payout.reconciled` | yes | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents`, `event_title`, `order_reference`, `currency` | Reconciled a payout. |
| `payout.released_from_cancellation_hold` | yes | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents`, `event_title`, `order_reference`, `currency` | Released a payout cancellation hold. |
| `payout.reversed` | yes | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents`, `event_title`, `order_reference`, `currency` | Marked a payout reversed. |
| `payout.submission_requested` | yes | payouts | O/F | yes | yes | `status`, `amount_cents`, `currency` | `amount_cents`, `currency`, `settlement_id`, `event_title`, `order_reference` | Requested a provider payout. |
| `payout.under_withholding_carried` | yes | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents`, `event_title`, `order_reference`, `currency` | Carried a payout withholding shortfall. |
| `payout.under_withholding_collected` | yes | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents`, `event_title`, `order_reference`, `currency` | Collected a payout withholding shortfall. |
| `payout.withholding_review_required` | yes | payouts | O/F | yes | yes | `status`, `paid_at`, `check_amount_cents`, `under_withheld_cents`, `withheld_cents`, `withholding_rate_bps`, `carried_withholding_cents` | `amount_cents`, `settlement_id`, `adjustment_id`, `delta_cents`, `event_title`, `order_reference`, `currency` | Flagged a payout for withholding review. |
| `pilot_closeout.approved` | yes | platform | A | yes | yes | — | — | Approved pilot closeout evidence. |
| `pilot_closeout.rejected` | yes | platform | A | yes | yes | — | — | Rejected pilot closeout evidence. |
| `pilot_closeout.revoked` | yes | platform | A | yes | yes | — | — | Revoked pilot closeout approval. |
| `pilot_closeout.submitted` | yes | platform | A | yes | yes | — | — | Submitted pilot closeout evidence. |
| `pilot_readiness.approved` | yes | platform | A | yes | yes | — | — | Approved pilot readiness evidence. |
| `pilot_readiness.rejected` | yes | platform | A | yes | yes | — | — | Rejected pilot readiness evidence. |
| `pilot_readiness.revoked` | yes | platform | A | yes | yes | — | — | Revoked pilot readiness approval. |
| `pilot_readiness.submitted` | yes | platform | A | yes | yes | — | — | Submitted pilot readiness evidence. |
| `pilot_validation.approved` | yes | platform | A | yes | yes | — | — | Approved pilot validation evidence. |
| `pilot_validation.rejected` | yes | platform | A | yes | yes | — | — | Rejected pilot validation evidence. |
| `pilot_validation.revoked` | yes | platform | A | yes | yes | — | — | Revoked pilot validation approval. |
| `pilot_validation.submitted` | yes | platform | A | yes | yes | — | — | Submitted pilot validation evidence. |
| `platform.activity_logging_started` | yes | platform | A | no | no | — | — | Started platform activity logging. |
| `platform.demo_seed_completed` | yes | platform | A | no | no | — | — | Created the local demo fixture set. |
| `platform.invitation_accepted` | yes | platform | A | no | no | — | — | Accepted a platform invitation. |
| `platform.invitation_created` | yes | platform | A | no | no | — | — | Created a platform invitation. |
| `platform.invitation_resent` | yes | platform | A | no | no | — | — | Resent a platform invitation. |
| `platform.invitation_revoked` | yes | platform | A | no | no | — | — | Revoked a platform invitation. |
| `platform_capability.approved` | yes | platform | A | no | no | — | — | Approved platform capability evidence. |
| `platform_capability.rejected` | yes | platform | A | no | no | — | — | Rejected platform capability evidence. |
| `platform_capability.revoked` | yes | platform | A | no | no | — | — | Revoked platform capability approval. |
| `platform_capability.submitted` | yes | platform | A | no | no | — | — | Submitted platform capability evidence. |
| `pricing_tier.created` | yes | tickets | O/M | yes | yes | `ticket_type_id`, `price_cents`, `tier_type`, `quantity_limit`, `starts_at`, `ends_at`, `position` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title`, `subject_label` | Created a pricing tier. |
| `pricing_tier.deleted` | yes | tickets | O/M | yes | yes | `ticket_type_id`, `price_cents`, `tier_type`, `quantity_limit`, `starts_at`, `ends_at`, `position` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title`, `subject_label` | Deleted a pricing tier. |
| `pricing_tier.updated` | yes | tickets | O/M | yes | yes | `ticket_type_id`, `price_cents`, `tier_type`, `quantity_limit`, `starts_at`, `ends_at`, `position` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title`, `subject_label` | Updated a pricing tier. |
| `privacy_request.executed` | yes | privacy | A | no | no | — | — | Executed a privacy request. |
| `privacy_request.submitted` | yes | privacy | A | no | no | — | — | Submitted a privacy request. |
| `privacy_request.verified` | yes | privacy | A | no | no | — | — | Verified a privacy request. |
| `promo_code.created` | yes | promotions | O/M | yes | yes | `event_id`, `discount_type`, `discount_value`, `max_uses`, `active`, `starts_at`, `expires_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title`, `subject_label` | Created a promo code. |
| `promo_code.deleted` | yes | promotions | O/M | yes | yes | `event_id`, `discount_type`, `discount_value`, `max_uses`, `active`, `starts_at`, `expires_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title`, `subject_label` | Deleted a promo code. |
| `promo_code.updated` | yes | promotions | O/M | yes | yes | `event_id`, `discount_type`, `discount_value`, `max_uses`, `active`, `starts_at`, `expires_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title`, `subject_label` | Updated a promo code. |
| `promoter.created` | yes | promotions | O/M | yes | yes | `event_id`, `commission_bps`, `active` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Created a promoter. |
| `promoter.deleted` | yes | promotions | O/M | yes | yes | `event_id`, `commission_bps`, `active` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Deleted a promoter. |
| `promoter.updated` | yes | promotions | O/M | yes | yes | `event_id`, `commission_bps`, `active` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Updated a promoter. |
| `refund.buyer_requested` | yes | refunds | O/F | yes | yes | `status`, `failure_code` | `order_id`, `payment_id`, `amount_cents`, `currency`, `manual_record`, `event_title`, `order_reference` | Requested a refund through buyer self-service. |
| `refund.created` | historical | refunds | O/F | yes | yes | `status`, `amount_cents` | `order_id`, `amount_cents`, `event_title`, `order_reference`, `currency` | Requested a refund. |
| `refund.external_observed` | yes | refunds | O/F | yes | yes | `status`, `failure_code` | `order_id`, `payment_id`, `amount_cents`, `currency`, `manual_record`, `event_title`, `order_reference` | Recorded a terminal external refund observation. |
| `refund.failed` | yes | refunds | O/F | yes | yes | `status`, `failure_code` | `order_id`, `payment_id`, `amount_cents`, `currency`, `manual_record`, `event_title`, `order_reference` | Recorded a failed refund. |
| `refund.pending` | yes | refunds | O/F | yes | yes | `status`, `failure_code` | `order_id`, `payment_id`, `amount_cents`, `currency`, `manual_record`, `event_title`, `order_reference` | Recorded a pending provider refund. |
| `refund.provider_result_conflict` | yes | refunds | O/F | yes | yes | `status`, `failure_code` | `order_id`, `payment_id`, `amount_cents`, `currency`, `manual_record`, `event_title`, `order_reference` | Flagged conflicting refund provider results. |
| `refund.requested` | yes | refunds | O/F | yes | yes | `status`, `failure_code` | `order_id`, `payment_id`, `amount_cents`, `currency`, `manual_record`, `event_title`, `order_reference` | Reserved a refund request. |
| `refund.submission_requested` | yes | refunds | O/F | yes | yes | `status`, `failure_code` | `order_id`, `payment_id`, `amount_cents`, `currency`, `manual_record`, `event_title`, `order_reference` | Requested a provider refund. |
| `refund.succeeded` | yes | refunds | O/F | yes | yes | `status`, `failure_code` | `order_id`, `payment_id`, `amount_cents`, `currency`, `manual_record`, `event_title`, `order_reference` | Completed a refund. |
| `refund.unknown` | yes | refunds | O/F | yes | yes | `status`, `failure_code` | `order_id`, `payment_id`, `amount_cents`, `currency`, `manual_record`, `event_title`, `order_reference` | Flagged an unknown refund result. |
| `refund_reconciliation.action_attempted` | yes | refunds | O/F | yes | yes | `status`, `amount_cents` | `operation`, `retry_refund_id`, `amount_cents`, `order_id`, `refund_id`, `provider_status`, `event_title`, `order_reference`, `currency` | Attempted a refund reconciliation action. |
| `refund_reconciliation.cancellation_retry` | yes | refunds | O/F | yes | yes | `status`, `amount_cents` | `operation`, `retry_refund_id`, `amount_cents`, `order_id`, `refund_id`, `provider_status`, `event_title`, `order_reference`, `currency` | Retried a cancellation refund. |
| `refund_reconciliation.manual_return` | yes | refunds | O/F | yes | yes | `status`, `amount_cents` | `operation`, `retry_refund_id`, `amount_cents`, `order_id`, `refund_id`, `provider_status`, `event_title`, `order_reference`, `currency` | Recorded a manual refund return. |
| `refund_reconciliation.overdue` | yes | refunds | O/F | yes | yes | `status`, `amount_cents` | `operation`, `retry_refund_id`, `amount_cents`, `order_id`, `refund_id`, `provider_status`, `event_title`, `order_reference`, `currency` | Flagged an overdue refund. |
| `refund_reconciliation.request_executed` | yes | refunds | O/F | yes | yes | `status`, `amount_cents` | `operation`, `retry_refund_id`, `amount_cents`, `order_id`, `refund_id`, `provider_status`, `event_title`, `order_reference`, `currency` | Executed an approved refund request. |
| `refund_reconciliation.resynced` | yes | refunds | O/F | yes | yes | `status`, `amount_cents` | `operation`, `retry_refund_id`, `amount_cents`, `order_id`, `refund_id`, `provider_status`, `event_title`, `order_reference`, `currency` | Refreshed the refund provider status. |
| `refund_reconciliation.retry` | yes | refunds | O/F | yes | yes | `status`, `amount_cents` | `operation`, `retry_refund_id`, `amount_cents`, `order_id`, `refund_id`, `provider_status`, `event_title`, `order_reference`, `currency` | Retried a refund. |
| `refund_reconciliation.unable` | yes | refunds | O/F | yes | yes | `status`, `amount_cents` | `operation`, `retry_refund_id`, `amount_cents`, `order_id`, `refund_id`, `provider_status`, `event_title`, `order_reference`, `currency` | Could not complete refund reconciliation. |
| `registration_question.created` | yes | attendees | O/M | yes | yes | `event_id`, `kind`, `required`, `active`, `position` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Created a registration question. |
| `registration_question.deleted` | yes | attendees | O/M | yes | yes | `event_id`, `kind`, `required`, `active`, `position` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Deleted a registration question. |
| `registration_question.updated` | yes | attendees | O/M | yes | yes | `event_id`, `kind`, `required`, `active`, `position` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Updated a registration question. |
| `sales.door_list_exported` | yes | exports | O/M | yes | yes | — | `row_count`, `export_request_id`, `outcome`, `view`, `event_title` | Exported an event door list. |
| `sales.emergency_door_list_exported` | yes | exports | O/M | yes | yes | — | `row_count`, `export_request_id`, `outcome`, `view`, `event_title` | Exported an emergency event door list. |
| `sales.export_download_failed` | yes | exports | O/M | yes | yes | — | `row_count`, `export_request_id`, `outcome`, `view`, `event_title` | Failed to download an event sales export. |
| `sales.export_downloaded` | yes | exports | O/M | yes | yes | — | `row_count`, `export_request_id`, `outcome`, `view`, `event_title` | Downloaded an event sales export. |
| `sales.export_failed` | yes | exports | O/M | yes | yes | — | `row_count`, `export_request_id`, `outcome`, `view`, `event_title` | Failed to generate an event sales export. |
| `sales.export_generated` | yes | exports | O/M | yes | yes | — | `row_count`, `export_request_id`, `outcome`, `view`, `event_title` | Generated an event sales export. |
| `sales.export_requested` | yes | exports | O/M | yes | yes | — | `row_count`, `export_request_id`, `outcome`, `view`, `event_title` | Requested an event sales export. |
| `sales.exported` | yes | exports | O/M | yes | yes | — | `row_count`, `export_request_id`, `outcome`, `view`, `event_title` | Exported an event sales summary. |
| `scanner_device.authorized` | yes | scanning | O/M | yes | yes | `status` | `event_id`, `event_title` | Authorized an event scanner device. |
| `scanner_device.journal_recovered` | yes | scanning | O/M | yes | yes | — | `entry_count`, `window_start`, `window_end`, `event_title` | Recovered a reviewed offline admission journal. |
| `scanner_device.lease_updated` | yes | scanning | O/M | yes | yes | `status`, `lease_expires_at` | `event_id`, `manifest_version`, `entry_count`, `event_title` | Updated an event scanner authorization lease. |
| `scanner_device.manifest_downloaded` | yes | scanning | O/M | yes | yes | `status` | `event_id`, `manifest_version`, `entry_count`, `event_title` | Downloaded an event scanner manifest. |
| `scanner_device.renamed` | yes | scanning | O/M | yes | yes | `status` | `event_id`, `manifest_version`, `entry_count`, `event_title` | Renamed an event scanner device. |
| `scanner_device.revoked` | yes | scanning | O/M | yes | yes | `status` | `event_id`, `event_title` | Revoked an event scanner device. |
| `seat.exchanged` | yes | events | O/M | yes | yes | `operational_status` | `event_seat_id`, `ticket_id`, `venue_layout_id`, `event_seat_count`, `previous_event_seat_id`, `target_event_seat_id`, `event_title` | Exchanged a ticket's seat. |
| `seat.released_from_ticket` | yes | events | O/M | yes | yes | `operational_status` | `event_seat_id`, `ticket_id`, `venue_layout_id`, `event_seat_count`, `previous_event_seat_id`, `target_event_seat_id`, `event_title` | Released a cancelled ticket's seat. |
| `seat.status_changed` | yes | events | O/M | yes | yes | `operational_status` | `event_seat_id`, `ticket_id`, `venue_layout_id`, `event_seat_count`, `previous_event_seat_id`, `target_event_seat_id`, `event_title` | Changed a seat's availability. |
| `seating.configuration_activated` | yes | events | O/M | yes | yes | `operational_status` | `event_seat_id`, `ticket_id`, `venue_layout_id`, `event_seat_count`, `previous_event_seat_id`, `target_event_seat_id`, `event_title` | Activated event seating. |
| `seating.organizer_sales_resumed` | yes | events | O/M | yes | yes | `organizer_sales_suspended_at` | `event_title` | Resumed assigned-seat sales for the organizer. |
| `seating.organizer_sales_suspended` | yes | events | O/M | yes | yes | `organizer_sales_suspended_at` | `event_title` | Paused assigned-seat sales for the organizer. |
| `settlement.finalized` | yes | payouts | O/F | yes | yes | `gross_cents`, `discount_cents`, `refund_cents`, `net_cents`, `platform_fee_cents`, `processing_fee_cents`, `platform_processing_fee_cents`, `organizer_proceeds_cents`, `reserve_cents`, `adjustment_cents`, `payable_cents`, `paid_cents`, `negative_balance_cents`, `version` | `settlement_id`, `event_title`, `order_reference`, `amount_cents`, `currency` | Finalized an event settlement. |
| `site_settings.fee_change_acknowledged` | yes | fees | O/F | yes | no | — | `fee_change_id`, `event_title` | Acknowledged an upcoming fee change. |
| `site_settings.fee_change_notice_skipped` | yes | fees | A | yes | no | — | — | Skipped a fee change notice delivery. |
| `site_settings.fee_terms_activated` | yes | platform | A | no | no | — | — | Activated platform fee terms. |
| `site_settings.fee_terms_activation_blocked` | yes | platform | A | no | no | — | — | Blocked platform fee term activation. |
| `site_settings.fee_terms_scheduled` | yes | platform | A | no | no | — | — | Scheduled platform fee terms. |
| `site_settings.fee_terms_updated` | yes | platform | A | no | no | — | — | Updated platform fee terms. |
| `site_settings.payment_mode_changed` | yes | platform | A | no | no | — | — | Changed the platform payment mode. |
| `site_settings.retention_purge_changed` | yes | platform | A | no | no | — | — | Changed platform retention purge settings. |
| `site_settings.updated` | yes | platform | A | no | no | — | — | Updated platform settings. |
| `support.lookup` | yes | platform | A | no | no | — | — | Looked up a support subject. |
| `support.note_created` | yes | platform | A | yes | no | — | — | Added an internal support note. |
| `tax_information.b_notice_generated` | yes | tax | A | yes | no | — | — | Generated a tax B notice. |
| `tax_information.b_notice_sent` | yes | tax | A | yes | no | — | — | Sent a tax B notice. |
| `tax_information.irs_notice_received` | yes | tax | A | yes | no | — | — | Recorded receipt of a tax notice. |
| `tax_information.second_b_notice_validated` | yes | tax | A | yes | no | — | — | Validated a second tax B notice. |
| `tax_information.withholding_flag_changed` | yes | tax | O | yes | no | `backup_withholding_required`, `tin_matching_status` | `event_title` | Updated tax withholding status. |
| `tax_report.exported` | yes | tax | A | no | no | — | — | Exported platform tax reports. |
| `ticket.admission_reconciled` | yes | scanning | O/M | yes | yes | `result`, `reason_code`, `ticket_id` | `event_id`, `event_title` | Reconciled a ticket admission. |
| `ticket.cancelled` | yes | tickets | O/M | yes | yes | `status`, `cancelled_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Cancelled ticket. |
| `ticket.check_in_reversed` | yes | scanning | O/M | yes | yes | `result`, `reason_code`, `ticket_id` | `event_id`, `event_title` | Reversed a ticket check-in. |
| `ticket.checked_in` | yes | scanning | O/M | yes | yes | `result`, `reason_code`, `ticket_id` | `event_id`, `event_title` | Checked in a ticket. |
| `ticket.display_credential_revoked` | yes | tickets | O/M | yes | yes | `status`, `cancelled_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Revoked a ticket display credential. |
| `ticket.scan_credential_rotated` | yes | tickets | O/M | yes | yes | `status`, `cancelled_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Rotated a ticket scan code. |
| `ticket_transfer.accepted` | yes | tickets | O/M | yes | yes | `ticket_id`, `status`, `expires_at`, `accepted_at`, `cancelled_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Accepted ticket transfer. |
| `ticket_transfer.cancelled` | yes | tickets | O/M | yes | yes | `ticket_id`, `status`, `expires_at`, `accepted_at`, `cancelled_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Cancelled ticket transfer. |
| `ticket_transfer.created` | yes | tickets | O/M | yes | yes | `ticket_id`, `status`, `expires_at`, `accepted_at`, `cancelled_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Created a ticket transfer. |
| `ticket_transfer.declined` | yes | tickets | O/M | yes | yes | `ticket_id`, `status`, `expires_at`, `accepted_at`, `cancelled_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Declined ticket transfer. |
| `ticket_transfer.deleted` | yes | tickets | O/M | yes | yes | `ticket_id`, `status`, `expires_at`, `accepted_at`, `cancelled_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Deleted a ticket transfer. |
| `ticket_transfer.expired` | yes | tickets | O/M | yes | yes | `ticket_id`, `status`, `expires_at`, `accepted_at`, `cancelled_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Expired ticket transfer. |
| `ticket_transfer.pending` | yes | tickets | O/M | yes | yes | `ticket_id`, `status`, `expires_at`, `accepted_at`, `cancelled_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Pending ticket transfer. |
| `ticket_transfer.updated` | yes | tickets | O/M | yes | yes | `ticket_id`, `status`, `expires_at`, `accepted_at`, `cancelled_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Updated a ticket transfer. |
| `ticket_type.created` | yes | tickets | O/M | yes | yes | `event_id`, `price_cents`, `quantity_available`, `max_per_order`, `max_per_buyer`, `door_allocation`, `sort_order`, `sales_start_at`, `sales_end_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title`, `subject_label` | Created a ticket type. |
| `ticket_type.deleted` | yes | tickets | O/M | yes | yes | `event_id`, `price_cents`, `quantity_available`, `max_per_order`, `max_per_buyer`, `door_allocation`, `sort_order`, `sales_start_at`, `sales_end_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title`, `subject_label` | Deleted a ticket type. |
| `ticket_type.updated` | yes | tickets | O/M | yes | yes | `event_id`, `price_cents`, `quantity_available`, `max_per_order`, `max_per_buyer`, `door_allocation`, `sort_order`, `sales_start_at`, `sales_end_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title`, `subject_label` | Updated a ticket type. |
| `tin_matching.exported` | yes | tax | A | no | no | — | — | Exported a taxpayer identification matching batch. |
| `tin_matching.import_failed` | yes | tax | A | no | no | — | — | Failed to import taxpayer identification matching results. |
| `tin_matching.imported` | yes | tax | A | no | no | — | — | Imported taxpayer identification matching results. |
| `user.role_updated` | yes | platform | A | no | no | — | — | Updated a platform user role. |
| `venue_layout.created` | yes | events | O/M | yes | no | `organization_id`, `venue_id`, `version`, `status`, `renderer` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Created a venue layout. |
| `venue_layout.deleted` | yes | events | O/M | yes | no | `organization_id`, `venue_id`, `version`, `status`, `renderer` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Deleted a venue layout. |
| `venue_layout.updated` | yes | events | O/M | yes | no | `organization_id`, `venue_id`, `version`, `status`, `renderer` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Updated a venue layout. |
| `waitlist.cancelled` | yes | attendees | O/M | yes | yes | `event_id`, `ticket_type_id`, `quantity`, `position`, `status`, `notified_at`, `expires_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Cancelled waitlist. |
| `waitlist.converted` | yes | attendees | O/M | yes | yes | `event_id`, `ticket_type_id`, `quantity`, `position`, `status`, `notified_at`, `expires_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Converted waitlist. |
| `waitlist.deleted` | yes | attendees | O/M | yes | yes | `event_id`, `ticket_type_id`, `quantity`, `position`, `status`, `notified_at`, `expires_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Deleted a waitlist entry. |
| `waitlist.expired` | yes | attendees | O/M | yes | yes | `event_id`, `ticket_type_id`, `quantity`, `position`, `status`, `notified_at`, `expires_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Expired waitlist. |
| `waitlist.joined` | yes | attendees | O/M | yes | yes | `event_id`, `ticket_type_id`, `quantity`, `position`, `status`, `notified_at`, `expires_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Joined the waitlist. |
| `waitlist.notification_requested` | yes | attendees | O/M | yes | yes | `event_id`, `ticket_type_id`, `quantity`, `position`, `status`, `notified_at`, `expires_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Requested a waitlist notification. |
| `waitlist.offered` | yes | attendees | O/M | yes | yes | `event_id`, `ticket_type_id`, `quantity`, `position`, `status`, `notified_at`, `expires_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Offered waitlist. |
| `waitlist.rejoined` | yes | attendees | O/M | yes | yes | `event_id`, `ticket_type_id`, `quantity`, `position`, `status`, `notified_at`, `expires_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Rejoined the waitlist. |
| `waitlist.requeued` | yes | attendees | O/M | yes | yes | `event_id`, `ticket_type_id`, `quantity`, `position`, `status`, `notified_at`, `expires_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Returned a waitlist entry to the queue. |
| `waitlist.updated` | yes | attendees | O/M | yes | yes | `event_id`, `ticket_type_id`, `quantity`, `position`, `status`, `notified_at`, `expires_at` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Updated a waitlist entry. |
| `waitlist_offer.cancelled` | yes | attendees | O/M | yes | yes | `waitlist_entry_id`, `event_id`, `ticket_type_id`, `pricing_tier_id`, `quantity`, `unit_price_cents`, `status`, `expires_at`, `claimed_at`, `converted_at`, `order_id` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Cancelled waitlist offer. |
| `waitlist_offer.claimed` | yes | attendees | O/M | yes | yes | `waitlist_entry_id`, `event_id`, `ticket_type_id`, `pricing_tier_id`, `quantity`, `unit_price_cents`, `status`, `expires_at`, `claimed_at`, `converted_at`, `order_id` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Claimed waitlist offer. |
| `waitlist_offer.converted` | yes | attendees | O/M | yes | yes | `waitlist_entry_id`, `event_id`, `ticket_type_id`, `pricing_tier_id`, `quantity`, `unit_price_cents`, `status`, `expires_at`, `claimed_at`, `converted_at`, `order_id` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Converted waitlist offer. |
| `waitlist_offer.created` | yes | attendees | O/M | yes | yes | `waitlist_entry_id`, `event_id`, `ticket_type_id`, `pricing_tier_id`, `quantity`, `unit_price_cents`, `status`, `expires_at`, `claimed_at`, `converted_at`, `order_id` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Created a waitlist offer. |
| `waitlist_offer.deleted` | yes | attendees | O/M | yes | yes | `waitlist_entry_id`, `event_id`, `ticket_type_id`, `pricing_tier_id`, `quantity`, `unit_price_cents`, `status`, `expires_at`, `claimed_at`, `converted_at`, `order_id` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Deleted a waitlist offer. |
| `waitlist_offer.expired` | yes | attendees | O/M | yes | yes | `waitlist_entry_id`, `event_id`, `ticket_type_id`, `pricing_tier_id`, `quantity`, `unit_price_cents`, `status`, `expires_at`, `claimed_at`, `converted_at`, `order_id` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Expired waitlist offer. |
| `waitlist_offer.offered` | yes | attendees | O/M | yes | yes | `waitlist_entry_id`, `event_id`, `ticket_type_id`, `pricing_tier_id`, `quantity`, `unit_price_cents`, `status`, `expires_at`, `claimed_at`, `converted_at`, `order_id` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Offered waitlist offer. |
| `waitlist_offer.updated` | yes | attendees | O/M | yes | yes | `waitlist_entry_id`, `event_id`, `ticket_type_id`, `pricing_tier_id`, `quantity`, `unit_price_cents`, `status`, `expires_at`, `claimed_at`, `converted_at`, `order_id` | `source_event_id`, `event_state_change_id`, `ticket_count`, `event_title` | Updated a waitlist offer. |
| `waiver.accepted` | yes | attendees | O/M | yes | yes | `event_waiver_id`, `version`, `accepted_at` | `event_title` | Accepted an event waiver. |

## Verification

This table is generated from the 288 registered definitions. The
completeness spec requires a row for each definition. See
[AUDIT_INTEGRITY.md](AUDIT_INTEGRITY.md) for combined test results, deployment and
privacy/retention behavior. See [Organization activity projection](AUDIT_INTEGRITY.md#organization-activity-projection) for the Activity endpoints and UI.

## Activity export lifecycle

These summaries contain an opaque export request ID and row count only. Raw
filters and search text stay inside an encrypted ticket, never audit metadata.
Admin exports may be platform-wide; organizer exports always pass the selected
organization. Download requires the same requester and current permissions.

| Action | Area | Audience | Tenant | Event | Organization fields |
| --- | --- | --- | --- | --- | --- |
| `activity_log.export_requested` | exports | org_owner, org_manager, org_finance | optional (admin exports) | optional | export_request_id, row_count |
| `activity_log.export_generated` | exports | org_owner, org_manager, org_finance | optional (admin exports) | optional | export_request_id, row_count |
| `activity_log.export_downloaded` | exports | org_owner, org_manager, org_finance | optional (admin exports) | optional | export_request_id, row_count |
| `activity_log.export_failed` | exports | org_owner, org_manager, org_finance | optional (admin exports) | optional | export_request_id, row_count |

## Readable activity sentences

`AuditDisplayContext` captures display facts at the shared `AuditLogger` write
call: event/ticket/campaign names, team invitee and role, and financial amount,
currency and order reference. `ActivityLogSentence` reads only each action's
registry-allowlisted scalar fields. Buyer contacts, guest names, campaign bodies,
provider payloads, account numbers and tax identifiers are not display context.
Team invitation contact is visible only to the organization Owner audience.

Sentences begin with the audience-safe actor label and identify the affected
record and relevant price, inventory, amount or status. Historical rows without
captured context fall back to stable record IDs; no live buyer record is loaded
to reconstruct a sentence. Organization JSON and CSV use the same presenter.
Search reads only the allowlisted display context, and masking also applies to
exact actor filters. Admin drilldowns retain sanitized technical data.
