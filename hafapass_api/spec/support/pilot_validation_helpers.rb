module PilotValidationHelpers
  def create_pilot_readiness_approval(event:, submitter: create(:user, :admin), approver: create(:user, :admin))
    attributes = {
      evidence_reference: "private/pilot-readiness/#{event.id}",
      evidence_digest: "a" * 64,
      controls: PilotReadinessReview::CONTROL_KEYS.index_with(true),
      assignments: PilotReadinessReview::ASSIGNMENT_KEYS.index_with do |role|
        { name: role.humanize, contact_reference: "private-directory/#{role}" }
      end,
      effective_at: 1.minute.ago,
      expires_at: 30.days.from_now
    }
    submission = PilotReadinessReviews::Manager.submit!(event: event, attributes: attributes, actor: submitter)
    PilotReadinessReviews::Manager.approve!(submission: submission, actor: approver)
  end

  def valid_pilot_validation_attributes(event:)
    device_matrix = PilotValidationReview::DEVICE_TARGETS.to_h do |target, requirements|
      if requirements[:required]
        [target, {
          status: "passed",
          device_name: "QA #{target}",
          os_version: "current",
          browser_version: "current",
          tester_reference: "private-qa/testers/#{target}",
          evidence_reference: "private-qa/devices/#{target}",
          physical_device: requirements[:physical]
        }]
      else
        [target, { status: "unavailable", unavailable_reason: "Not available in the pilot device pool" }]
      end
    end
    assistive = PilotValidationReview::ASSISTIVE_TECHNOLOGY_TARGETS.index_with do |target|
      {
        status: "passed",
        platform: target,
        technology_version: "current",
        tester_reference: "private-qa/accessibility-testers/#{target}",
        evidence_reference: "private-qa/accessibility/#{target}"
      }
    end
    {
      evidence_reference: "private-qa/gate-f/#{event.id}",
      evidence_digest: "b" * 64,
      device_matrix: device_matrix,
      buyer_flows: PilotValidationReview::BUYER_FLOW_KEYS.index_with(true),
      organizer_flows: PilotValidationReview::ORGANIZER_FLOW_KEYS.index_with(true),
      accessibility_results: {
        checks: PilotValidationReview::ACCESSIBILITY_CHECK_KEYS.index_with(true),
        assistive_technology: assistive,
        reviewer: {
          name: "Qualified accessibility reviewer",
          qualification_reference: "private-qa/qualifications/accessibility-reviewer",
          evidence_reference: "private-qa/accessibility/signoff"
        }
      },
      load_results: {
        scenario_name: "Expected pilot onsale",
        tool_name: "k6",
        target_environment: "isolated production-like candidate",
        expected_concurrent_buyers: 50,
        executed_concurrent_buyers: 60,
        request_count: 1000,
        duration_seconds: 300,
        p95_latency_ms: 650,
        latency_budget_ms: 1500,
        observed_error_rate_percent: "0.2",
        error_rate_budget_percent: "1.0",
        peak_database_connections: 12,
        database_connection_limit: 20,
        inventory_contention_attempts: 100,
        seat_contention_attempts: event.assigned_seating? ? 25 : 0,
        expired_holds_expected: 10,
        expired_holds_observed: 10,
        oversell_count: 0,
        duplicate_sale_count: 0,
        all_holds_reconciled: true
      },
      controls: PilotValidationReview::CONTROL_KEYS.index_with(true),
      effective_at: 1.minute.ago,
      expires_at: 14.days.from_now
    }
  end
end

RSpec.configure do |config|
  config.include PilotValidationHelpers
end
