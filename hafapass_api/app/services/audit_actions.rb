# frozen_string_literal: true

# The organization history is a projection of the private audit record. Keep
# visibility, required scope, and safe fields explicit; never infer them from
# an action prefix or from a caller's permissions.
class AuditActions
  AREAS = %w[organization team verification events tickets promotions attendees door scanning orders refunds disputes payouts payout_settings tax fees exports messaging marketing_partners privacy platform].freeze
  AUDIENCES = %w[org_owner org_manager org_finance admin_only].freeze

  class << self
    def fetch(action)
      DEFINITIONS.fetch(action.to_s, UNKNOWN)
    end

    def registered?(action)
      DEFINITIONS.key?(action.to_s)
    end

    def keys
      DEFINITIONS.keys
    end

    def tenant?(action)
      fetch(action).fetch(:tenant)
    end

    def event_required?(action)
      fetch(action).fetch(:event_required)
    end

    def visible_to?(action, audience)
      fetch(action).fetch(:audience).include?(audience.to_s)
    end

    # Input/output keys are the AuditLog JSON columns. Unknown/admin-only
    # actions produce empty projections. Nested objects and arrays are dropped,
    # even under allowed keys, so a new caller cannot smuggle private payloads.
    # This does not alter the private before_data/after_data/metadata record.
    def organization_payload(action, before_data: {}, after_data: {}, metadata: {})
      definition = fetch(action)
      inputs = { before_data: before_data, after_data: after_data, metadata: metadata }
      inputs.to_h do |column, data|
        allowed = definition.fetch(:organization_fields).fetch(column)
        filtered = data.is_a?(Hash) ? data.each_with_object({}) do |(key, value), result|
          next unless allowed.include?(key.to_s) && scalar?(value)

          result[key.to_s] = value
        end : {}
        [column, filtered]
      end
    end

    private

    def scalar?(value)
      value.nil? || value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, item| deep_freeze(key); deep_freeze(item) }
      when Array then value.each { |item| deep_freeze(item) }
      end
      value.freeze
    end

    def define(registry, area:, audience:, tenant:, event_required:, snapshots: [], metadata: [], actions:)
      audiences = Array(audience).map(&:to_s)
      raise ArgumentError, "Invalid audit area" unless AREAS.include?(area)
      raise ArgumentError, "Invalid audit audience" unless (audiences - AUDIENCES).empty? && audiences.any?
      raise ArgumentError, "Admin history cannot be organization-visible" if audiences.include?("admin_only") && audiences.size > 1
      raise ArgumentError, "Organization owners must see organization-visible history" unless audiences == ["admin_only"] || audiences.include?("org_owner")
      raise ArgumentError, "Event scope requires a tenant" if event_required && !tenant
      fields = audiences == ["admin_only"] ? { before_data: [], after_data: [], metadata: [] } :
        { before_data: snapshots, after_data: snapshots, metadata: metadata }
      actions.each do |action, template|
        raise ArgumentError, "Duplicate audit action: #{action}" if registry.key?(action)

        registry[action] = deep_freeze({ area: area, audience: audiences.dup, tenant: tenant,
          event_required: event_required, organization_fields: fields, template: template })
      end
    end
  end

  UNKNOWN = deep_freeze({ area: "platform", audience: ["admin_only"], tenant: false,
    event_required: false, organization_fields: { before_data: [], after_data: [], metadata: [] },
    template: "Recorded an unrecognized administrative action." })

  DEFINITIONS = begin
    registry = {}
    define registry, area: "organization", audience: %w[org_owner],
      tenant: true, event_required: false,
      snapshots: %w[name business_name business_description], metadata: %w[], actions: {
        "organization.created" => "Created the organization.",
        "organization.updated" => "Updated organization details.",
        "organization.created_by_admin" => "Created the organization on behalf of its owner.",
        "organization.marketing_postal_address_updated" => "Updated the organization marketing postal address."
      }

    define registry, area: "organization", audience: %w[org_owner],
      tenant: true, event_required: false,
      snapshots: %w[policy_version policy_accepted_at accepted_at], metadata: %w[], actions: {
        "organizer.policy_accepted" => "Accepted the organizer agreement."
      }

    define registry, area: "team", audience: %w[org_owner],
      tenant: true, event_required: false,
      snapshots: %w[role status accepted_at revoked_at expires_at target_user_id target_name], metadata: %w[membership_id], actions: {
        "organization.invitation_created" => "Invited a team member.",
        "organization.invitation_resent" => "Resent a team invitation.",
        "organization.invitation_accepted" => "Accepted a team invitation.",
        "organization.membership_revoked" => "Revoked team access.",
        "organization.membership_updated" => "Updated team access.",
        "organization.ownership_transferred" => "Transferred organization ownership."
      }

    define registry, area: "team", audience: %w[org_owner org_manager],
      tenant: true, event_required: true,
      snapshots: %w[event_id role status expires_at target_user_id target_name], metadata: %w[], actions: {
        "event_staff.assigned" => "Assigned event staff.",
        "event_staff.updated" => "Updated an event staff assignment.",
        "event_staff.revoked" => "Revoked an event staff assignment.",
        "event_staff.invitation_revoked" => "Revoked an event staff invitation."
      }

    define registry, area: "verification", audience: %w[org_owner],
      tenant: true, event_required: false,
      snapshots: %w[verification_status verification_requested_at verification_request_version verified_at], metadata: %w[], actions: {
        "organizer.verification_requested" => "Requested organizer verification.",
        "organizer.verification_request_updated" => "Updated an organizer verification request.",
        "organizer.verification_updated" => "Updated organizer verification status."
      }

    define registry, area: "events", audience: %w[org_owner org_manager],
      tenant: true, event_required: true,
      snapshots: %w[sales_suspended_at], metadata: %w[], actions: {
        "event.sales_resumed" => "Resumed event ticket sales.",
        "event.preview_link_rotated" => "Replaced the event preview link.",
        "event.page_customized" => "Updated the event page design."
      }

    define registry, area: "events", audience: %w[admin_only],
      tenant: true, event_required: true,
      snapshots: %w[], metadata: %w[], actions: {
        "event.policy_hold_placed" => "Placed an event policy hold.",
        "event.policy_hold_lifted" => "Released an event policy hold."
      }

    define registry, area: "refunds", audience: %w[org_owner org_finance],
      tenant: true, event_required: true,
      snapshots: %w[status amount_cents refunded_cents], metadata: %w[order_id refund_id run_id amount_cents], actions: {
        "event.cancellation_cash_refunded" => "Recorded a cash refund for a cancelled event.",
        "event.cancellation_card_refunded" => "Requested a card refund for a cancelled event.",
        "event.cancellation_refund_amount_changed" => "Updated the cancellation refund amount.",
        "event.cancellation_refunds_started" => "Started cancellation refunds.",
        "event.cancellation_refunds_completed" => "Completed cancellation refunds.",
        "event.legacy_cancellation_refunds_started" => "Started cancellation refunds for legacy orders."
      }

    define registry, area: "refunds", audience: %w[org_owner org_finance],
      tenant: true, event_required: true,
      snapshots: %w[status amount_cents], metadata: %w[order_id amount_cents], actions: {
        "refund.created" => "Requested a refund."
      }

    define registry, area: "refunds", audience: %w[org_owner org_finance],
      tenant: true, event_required: true,
      snapshots: %w[status amount_cents], metadata: %w[operation retry_refund_id amount_cents order_id refund_id provider_status], actions: {
        "refund_reconciliation.action_attempted" => "Attempted a refund reconciliation action.",
        "refund_reconciliation.unable" => "Could not complete refund reconciliation.",
        "refund_reconciliation.retry" => "Retried a refund.",
        "refund_reconciliation.cancellation_retry" => "Retried a cancellation refund.",
        "refund_reconciliation.request_executed" => "Executed an approved refund request.",
        "refund_reconciliation.resynced" => "Refreshed the refund provider status.",
        "refund_reconciliation.manual_return" => "Recorded a manual refund return.",
        "refund_reconciliation.overdue" => "Flagged an overdue refund."
      }

    define registry, area: "scanning", audience: %w[org_owner org_manager],
      tenant: true, event_required: true,
      snapshots: %w[result reason_code ticket_id], metadata: %w[event_id], actions: {
        "ticket.checked_in" => "Checked in a ticket.",
        "ticket.admission_reconciled" => "Reconciled a ticket admission.",
        "ticket.check_in_reversed" => "Reversed a ticket check-in."
      }

    define registry, area: "scanning", audience: %w[org_owner org_manager],
      tenant: true, event_required: true,
      snapshots: %w[status], metadata: %w[event_id], actions: {
        "scanner_device.authorized" => "Authorized an event scanner device.",
        "scanner_device.revoked" => "Revoked an event scanner device."
      }

    define registry, area: "orders", audience: %w[org_owner org_finance],
      tenant: true, event_required: true,
      snapshots: %w[], metadata: %w[recovered_tickets], actions: {
        "guest_purchase.recovered" => "Linked a guest purchase to its buyer account."
      }

    define registry, area: "messaging", audience: %w[org_owner org_manager],
      tenant: true, event_required: true,
      snapshots: %w[], metadata: %w[message_delivery_id], actions: {
        "order.fulfillment_resent" => "Resent ticket fulfillment."
      }

    define registry, area: "messaging", audience: %w[admin_only],
      tenant: false, event_required: false,
      snapshots: %w[], metadata: %w[], actions: {
        "message_delivery.replayed" => "Replayed a message delivery."
      }

    define registry, area: "exports", audience: %w[org_owner org_manager],
      tenant: true, event_required: true,
      snapshots: %w[], metadata: %w[row_count export_request_id outcome view], actions: {
        "sales.exported" => "Exported an event sales summary.",
        "sales.export_requested" => "Requested an event sales export.",
        "sales.export_generated" => "Generated an event sales export.",
        "sales.export_downloaded" => "Downloaded an event sales export.",
        "sales.export_failed" => "Failed to generate an event sales export.",
        "sales.export_download_failed" => "Failed to download an event sales export.",
        "sales.door_list_exported" => "Exported an event door list.",
        "sales.emergency_door_list_exported" => "Exported an emergency event door list."
      }

    define registry, area: "exports", audience: %w[org_owner org_finance],
      tenant: true, event_required: false,
      snapshots: %w[], metadata: %w[row_count format scope event_id export], actions: {
        "finance.exported" => "Exported a finance summary."
      }

    define registry, area: "tax", audience: %w[org_owner org_finance],
      tenant: true, event_required: false,
      snapshots: %w[], metadata: %w[year], actions: {
        "annual_tax_report.statement_downloaded" => "Downloaded an annual tax statement."
      }

    define registry, area: "tax", audience: %w[org_owner org_finance],
      tenant: true, event_required: false,
      snapshots: %w[], metadata: %w[certification_version], actions: {
        "organizer_tax_information.updated" => "Updated organizer tax information."
      }

    define registry, area: "tax", audience: %w[org_owner org_finance],
      tenant: true, event_required: false,
      snapshots: %w[backup_withholding_required tin_matching_status], metadata: %w[], actions: {
        "tax_information.withholding_flag_changed" => "Updated tax withholding status."
      }

    define registry, area: "tax", audience: %w[admin_only],
      tenant: true, event_required: false,
      snapshots: %w[], metadata: %w[], actions: {
        "tax_information.b_notice_generated" => "Generated a tax B notice.",
        "tax_information.b_notice_sent" => "Sent a tax B notice.",
        "tax_information.irs_notice_received" => "Recorded receipt of a tax notice.",
        "tax_information.second_b_notice_validated" => "Validated a second tax B notice."
      }

    define registry, area: "tax", audience: %w[admin_only],
      tenant: false, event_required: false,
      snapshots: %w[], metadata: %w[], actions: {
        "annual_tax_report.setting_updated" => "Updated annual tax report settings.",
        "annual_tax_report.exported" => "Exported platform annual tax reports.",
        "annual_tax_thresholds.updated" => "Updated annual tax thresholds.",
        "tax_report.exported" => "Exported platform tax reports.",
        "tin_matching.exported" => "Exported a taxpayer identification matching batch.",
        "tin_matching.imported" => "Imported taxpayer identification matching results.",
        "tin_matching.import_failed" => "Failed to import taxpayer identification matching results."
      }

    define registry, area: "payout_settings", audience: %w[org_owner org_finance],
      tenant: true, event_required: false,
      snapshots: %w[provider status charges_enabled payouts_enabled details_submitted last_synced_at], metadata: %w[], actions: {
        "connected_account.onboarding_started" => "Started payout account setup.",
        "connected_account.payout_details_updated" => "Updated payout account details."
      }

    define registry, area: "payout_settings", audience: %w[admin_only],
      tenant: true, event_required: false,
      snapshots: %w[], metadata: %w[], actions: {
        "connected_account.synced" => "Synchronized payout account provider data.",
        "connected_account.readiness_recomputed" => "Recomputed payout account readiness.",
        "connected_account.readiness_approved" => "Approved payout account readiness.",
        "connected_account.readiness_revoked" => "Revoked payout account readiness approval."
      }

    define registry, area: "payouts", audience: %w[org_owner org_finance],
      tenant: true, event_required: true,
      snapshots: %w[status paid_at check_amount_cents under_withheld_cents withheld_cents withholding_rate_bps carried_withholding_cents], metadata: %w[amount_cents settlement_id adjustment_id delta_cents], actions: {
        "payout.pending" => "Marked a payout pending.",
        "payout.processing" => "Marked a payout processing.",
        "payout.paid" => "Marked a payout paid.",
        "payout.failed" => "Marked a payout failed.",
        "payout.reversed" => "Marked a payout reversed.",
        "payout.held" => "Marked a payout held.",
        "payout.withholding_review_required" => "Flagged a payout for withholding review.",
        "payout.provider_result_conflict" => "Flagged conflicting payout provider results.",
        "payout.late_result_held" => "Kept a late payout result on hold.",
        "payout.late_result_ignored" => "Ignored a late payout result.",
        "payout.under_withholding_carried" => "Carried a payout withholding shortfall.",
        "payout.under_withholding_collected" => "Collected a payout withholding shortfall.",
        "payout.held_for_cancellation" => "Held a payout for event cancellation.",
        "payout.released_from_cancellation_hold" => "Released a payout cancellation hold.",
        "payout.check_amount_adjusted" => "Adjusted a payout check amount.",
        "payout.reconciled" => "Reconciled a payout.",
        "payout.backup_withholding_overridden" => "Overrode payout backup withholding.",
        "payout.backup_withholding_recalculated" => "Recalculated payout backup withholding."
      }

    define registry, area: "payouts", audience: %w[org_owner org_finance],
      tenant: true, event_required: true,
      snapshots: %w[gross_cents discount_cents refund_cents net_cents platform_fee_cents processing_fee_cents platform_processing_fee_cents organizer_proceeds_cents reserve_cents adjustment_cents payable_cents paid_cents negative_balance_cents version], metadata: %w[settlement_id], actions: {
        "settlement.finalized" => "Finalized an event settlement."
      }

    define registry, area: "fees", audience: %w[org_owner org_finance],
      tenant: true, event_required: false,
      snapshots: %w[id kind amount_cents currency status effective_at event_id], metadata: %w[original_adjustment_id], actions: {
        "balance_adjustment.posted" => "Posted an organization balance adjustment.",
        "balance_adjustment.reversed" => "Reversed an organization balance adjustment."
      }

    define registry, area: "fees", audience: %w[org_owner org_finance],
      tenant: true, event_required: false,
      snapshots: %w[], metadata: %w[fee_change_id], actions: {
        "site_settings.fee_change_acknowledged" => "Acknowledged an upcoming fee change."
      }

    define registry, area: "fees", audience: %w[admin_only],
      tenant: true, event_required: false,
      snapshots: %w[], metadata: %w[], actions: {
        "site_settings.fee_change_notice_skipped" => "Skipped a fee change notice delivery."
      }

    define registry, area: "platform", audience: %w[admin_only],
      tenant: false, event_required: false,
      snapshots: %w[], metadata: %w[], actions: {
        "site_settings.updated" => "Updated platform settings.",
        "site_settings.payment_mode_changed" => "Changed the platform payment mode.",
        "site_settings.retention_purge_changed" => "Changed platform retention purge settings.",
        "site_settings.fee_terms_updated" => "Updated platform fee terms.",
        "site_settings.fee_terms_scheduled" => "Scheduled platform fee terms.",
        "site_settings.fee_terms_activated" => "Activated platform fee terms.",
        "site_settings.fee_terms_activation_blocked" => "Blocked platform fee term activation."
      }

    define registry, area: "door", audience: %w[org_owner org_manager org_finance],
      tenant: true, event_required: true,
      snapshots: %w[status amount_cents], metadata: %w[lifecycle_result], actions: {
        "card_present.payment_succeeded" => "Completed a card-present payment.",
        "card_present.payment_failed" => "Failed a card-present payment.",
        "card_present.payment_result_unknown" => "Flagged an unknown card-present payment result."
      }

    define registry, area: "payout_settings", audience: %w[admin_only],
      tenant: true, event_required: false,
      snapshots: %w[], metadata: %w[], actions: {
        "card_present.account_updated" => "Updated a card-present merchant account."
      }

    define registry, area: "privacy", audience: %w[admin_only],
      tenant: false, event_required: false,
      snapshots: %w[], metadata: %w[], actions: {
        "privacy_request.submitted" => "Submitted a privacy request.",
        "privacy_request.verified" => "Verified a privacy request.",
        "privacy_request.executed" => "Executed a privacy request."
      }

    define registry, area: "privacy", audience: %w[admin_only],
      tenant: false, event_required: false,
      snapshots: %w[], metadata: %w[], actions: {
        "legal_hold.placed" => "Placed a legal hold.",
        "legal_hold.released" => "Released a legal hold."
      }

    define registry, area: "platform", audience: %w[admin_only],
      tenant: false, event_required: false,
      snapshots: %w[], metadata: %w[], actions: {
        "support.lookup" => "Looked up a support subject.",
        "user.role_updated" => "Updated a platform user role.",
        "operations.synthetic_data_purged" => "Purged synthetic platform data."
      }

    define registry, area: "platform", audience: %w[admin_only],
      tenant: true, event_required: false,
      snapshots: %w[], metadata: %w[], actions: {
        "support.note_created" => "Added an internal support note."
      }

    define registry, area: "platform", audience: %w[admin_only],
      tenant: false, event_required: false,
      snapshots: %w[], metadata: %w[], actions: {
        "platform.invitation_created" => "Created a platform invitation.",
        "platform.invitation_resent" => "Resent a platform invitation.",
        "platform.invitation_revoked" => "Revoked a platform invitation.",
        "platform.invitation_accepted" => "Accepted a platform invitation."
      }

    define registry, area: "platform", audience: %w[admin_only],
      tenant: false, event_required: false,
      snapshots: %w[], metadata: %w[], actions: {
        "platform_capability.submitted" => "Submitted platform capability evidence.",
        "platform_capability.approved" => "Approved platform capability evidence.",
        "platform_capability.rejected" => "Rejected platform capability evidence.",
        "platform_capability.revoked" => "Revoked platform capability approval."
      }

    define registry, area: "platform", audience: %w[admin_only],
      tenant: true, event_required: false,
      snapshots: %w[], metadata: %w[], actions: {
        "payment_readiness.submitted" => "Submitted payment readiness evidence.",
        "payment_readiness.approved" => "Approved payment readiness evidence.",
        "payment_readiness.rejected" => "Rejected payment readiness evidence.",
        "payment_readiness.revoked" => "Revoked payment readiness approval."
      }

    define registry, area: "platform", audience: %w[admin_only],
      tenant: true, event_required: true,
      snapshots: %w[], metadata: %w[], actions: {
        "pilot_readiness.submitted" => "Submitted pilot readiness evidence.",
        "pilot_readiness.approved" => "Approved pilot readiness evidence.",
        "pilot_readiness.rejected" => "Rejected pilot readiness evidence.",
        "pilot_readiness.revoked" => "Revoked pilot readiness approval."
      }

    define registry, area: "platform", audience: %w[admin_only],
      tenant: true, event_required: true,
      snapshots: %w[], metadata: %w[], actions: {
        "pilot_validation.submitted" => "Submitted pilot validation evidence.",
        "pilot_validation.approved" => "Approved pilot validation evidence.",
        "pilot_validation.rejected" => "Rejected pilot validation evidence.",
        "pilot_validation.revoked" => "Revoked pilot validation approval."
      }

    define registry, area: "platform", audience: %w[admin_only],
      tenant: true, event_required: true,
      snapshots: %w[], metadata: %w[], actions: {
        "event_day_rehearsal.submitted" => "Submitted event-day rehearsal evidence.",
        "event_day_rehearsal.approved" => "Approved event-day rehearsal evidence.",
        "event_day_rehearsal.rejected" => "Rejected event-day rehearsal evidence.",
        "event_day_rehearsal.revoked" => "Revoked event-day rehearsal approval."
      }

    define registry, area: "platform", audience: %w[admin_only],
      tenant: true, event_required: true,
      snapshots: %w[], metadata: %w[], actions: {
        "live_money_proof.submitted" => "Submitted live-money proof evidence.",
        "live_money_proof.approved" => "Approved live-money proof evidence.",
        "live_money_proof.rejected" => "Rejected live-money proof evidence.",
        "live_money_proof.revoked" => "Revoked live-money proof approval."
      }

    define registry, area: "platform", audience: %w[admin_only],
      tenant: true, event_required: true,
      snapshots: %w[], metadata: %w[], actions: {
        "live_pilot.submitted" => "Submitted live pilot evidence.",
        "live_pilot.approved" => "Approved live pilot evidence.",
        "live_pilot.rejected" => "Rejected live pilot evidence.",
        "live_pilot.revoked" => "Revoked live pilot approval."
      }

    define registry, area: "platform", audience: %w[admin_only],
      tenant: true, event_required: true,
      snapshots: %w[], metadata: %w[], actions: {
        "pilot_closeout.submitted" => "Submitted pilot closeout evidence.",
        "pilot_closeout.approved" => "Approved pilot closeout evidence.",
        "pilot_closeout.rejected" => "Rejected pilot closeout evidence.",
        "pilot_closeout.revoked" => "Revoked pilot closeout approval."
      }

    define registry, area: "platform", audience: %w[admin_only],
      tenant: true, event_required: true,
      snapshots: %w[], metadata: %w[], actions: {
        "live_money_proof.authorization_requested" => "Requested live-money proof authorization.",
        "live_money_proof.authorization_approved" => "Approved live-money proof authorization.",
        "live_money_proof.authorization_revoked" => "Revoked live-money proof authorization.",
        "live_money_proof.authorization_consumed" => "Used live-money proof authorization."
      }

    define registry, area: "platform", audience: %w[admin_only],
      tenant: true, event_required: true,
      snapshots: %w[], metadata: %w[], actions: {
        "live_pilot_run.started" => "Started a live pilot run.",
        "live_pilot_run.paused" => "Paused a live pilot run.",
        "live_pilot_run.resumed" => "Resumed a live pilot run.",
        "live_pilot_run.completed" => "Completed a live pilot run.",
        "live_pilot_run.aborted" => "Aborted a live pilot run."
      }

    define registry, area: "platform", audience: %w[admin_only],
      tenant: true, event_required: true,
      snapshots: %w[], metadata: %w[], actions: {
        "live_pilot_incident.reported" => "Reported a live pilot incident.",
        "live_pilot_incident.resolved" => "Resolved a live pilot incident.",
        "live_pilot_metrics.recorded" => "Recorded live pilot metrics."
      }

    define registry, area: "platform", audience: %w[admin_only],
      tenant: false, event_required: false, actions: {
        "platform.activity_logging_started" => "Started platform activity logging."
      }

    define registry, area: "messaging", audience: %w[org_owner org_manager],
      tenant: true, event_required: true,
      snapshots: %w[status scheduled_at], metadata: %w[campaign_id recipient_count], actions: {
        "campaign.created" => "Created a campaign.",
        "campaign.updated" => "Updated a campaign.",
        "campaign.deleted" => "Deleted a campaign.",
        "campaign.scheduled" => "Scheduled a campaign.",
        "campaign.send_requested" => "Requested a campaign send.",
        "campaign.send_completed" => "Queued a campaign for delivery.",
        "campaign.send_failed" => "Failed to queue a campaign for delivery."
      }

    define registry, area: "scanning", audience: %w[org_owner org_manager],
      tenant: true, event_required: true,
      snapshots: %w[status], metadata: %w[event_id manifest_version entry_count], actions: {
        "scanner_device.renamed" => "Renamed an event scanner device.",
        "scanner_device.manifest_downloaded" => "Downloaded an event scanner manifest."
      }

    deep_freeze(registry)
  end
end
