module EventDayRehearsalHelpers
  def create_pilot_validation_approval(event:, submitter: create(:user, :admin), approver: create(:user, :admin))
    create_pilot_readiness_approval(event: event)
    submission = PilotValidationReviews::Manager.submit!(
      event: event, attributes: valid_pilot_validation_attributes(event: event), actor: submitter
    )
    PilotValidationReviews::Manager.approve!(submission: submission, actor: approver)
  end

  def valid_event_day_rehearsal_attributes(event:)
    devices = 3.times.map do |index|
      {
        identifier: "rehearsal-device-#{index + 1}", name: "Door #{index + 1}", model: "Physical test device #{index + 1}",
        os_version: "current", browser: index.zero? ? "Safari" : "Chrome", browser_version: "current",
        tester_reference: "private-rehearsal/testers/#{index + 1}",
        evidence_reference: "private-rehearsal/devices/#{index + 1}", physical_device: true,
        manifest_signature_verified: true, offline_mode_completed: true, reconnect_order: index + 1,
        queued_actions_before_sync: index + 2, queued_actions_after_sync: 0, conflicts_observed: index.zero? ? 1 : 0,
        immediate_feedback_p95_ms: 45 + index, battery_plan_reference: "private-rehearsal/battery-plan",
        spare_device_reference: "private-rehearsal/spares"
      }
    end
    incidents = EventDayRehearsalReview::INCIDENT_KEYS.index_with do |key|
      {
        status: "passed", evidence_reference: "private-rehearsal/incidents/#{key}",
        alert_acknowledgement_reference: "private-rehearsal/alerts/#{key}",
        resolution_reference: "private-rehearsal/resolutions/#{key}"
      }
    end
    assignments = EventDayRehearsalReview::ASSIGNMENT_KEYS.index_with do |role|
      {
        name: role.humanize, private_contact_reference: "private-directory/#{role}",
        acknowledgement_reference: "private-rehearsal/acknowledgements/#{role}"
      }
    end
    disabled_channel = {
      status: "disabled", disabled_reason: "Not offered during the controlled pilot",
      evidence_reference: "private-rehearsal/door-sales/disabled-decision"
    }
    {
      evidence_reference: "private-rehearsal/gate-g/#{event.id}", evidence_digest: "c" * 64,
      manifest_results: {
        rehearsal_event_reference: "isolated-rehearsal/#{event.id}", version: 3, digest: "d" * 64,
        key_id: "pilot-signing-key", algorithm: "RSA-PSS-SHA256", ticket_count: 500,
        generated_at: 1.hour.ago.iso8601, expires_at: 12.hours.from_now.iso8601,
        signed_manifest_evidence_reference: "private-rehearsal/manifest",
        emergency_door_list_reference: "private-rehearsal/door-list", emergency_door_list_digest: "e" * 64,
        signature_verified_on_every_device: true
      },
      device_results: devices,
      scan_results: EventDayRehearsalReview::SCAN_KEYS.index_with(true),
      incident_drills: incidents,
      door_sales_results: { cash: disabled_channel, card_present: disabled_channel },
      reconciliation_results: {
        generated_ticket_count: 500, unique_admissions_expected: 2, unique_admissions_observed: 2,
        duplicate_conflicts_expected: 1, duplicate_conflicts_observed: 1, pending_queue_count: 0,
        unresolved_conflict_count: 0, unexplained_admission_variance: 0, unexplained_inventory_variance: 0,
        unexplained_cash_variance_cents: 0, unexplained_card_variance_cents: 0, online_scan_p95_ms: 180,
        offline_feedback_p95_ms: 48, all_card_attempts_resolved: true, all_devices_synced: true
      },
      assignments: assignments, controls: EventDayRehearsalReview::CONTROL_KEYS.index_with(true),
      effective_at: 1.minute.ago, expires_at: 7.days.from_now
    }
  end
end

RSpec.configure do |config|
  config.include EventDayRehearsalHelpers
end
