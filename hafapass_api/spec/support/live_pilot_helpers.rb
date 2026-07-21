module LivePilotHelpers
  def valid_live_pilot_attributes(event:, inventory_cap: 10)
    event_start = event.starts_at
    event_end = event.ends_at
    {
      evidence_reference: "restricted-pilot/gate-i/#{event.id}", evidence_digest: "a" * 64,
      inventory_cap: inventory_cap,
      support_coverage: {
        before_event: support_window(event_start - 4.hours, event_start + 30.minutes, "before"),
        during_event: support_window(event_start - 30.minutes, event_end + 30.minutes, "during"),
        after_event: support_window(event_end - 30.minutes, event_end + 3.hours, "after")
      },
      assignments: LivePilotReview::ASSIGNMENT_KEYS.index_with do |key|
        {
          name: key.humanize, private_contact_reference: "restricted-contacts/#{key}",
          acknowledgement_reference: "restricted-acknowledgements/#{key}"
        }
      end,
      thresholds: {
        minimum_checkout_conversion_bps: 1000, maximum_payment_failure_rate_bps: 2000,
        maximum_hold_expiry_rate_bps: 5000, maximum_delivery_failure_rate_bps: 2000,
        maximum_scanner_conflicts: 5, maximum_scanner_sync_lag_seconds: 120,
        maximum_checkout_p95_ms: 2000, maximum_support_contacts_per_100_orders: 100
      },
      controls: LivePilotReview::CONTROL_KEYS.index_with(true),
      effective_at: 1.minute.ago, expires_at: event_end + 1.day
    }
  end

  def create_live_pilot_approval(event: nil, inventory_cap: 10)
    event ||= begin
      profile = create(:organizer_profile, :payout_ready)
      created = create(:event, :published, organizer_profile: profile, organization: profile.organization,
        starts_at: 1.day.from_now, ends_at: 1.day.from_now + 3.hours, max_capacity: 50)
      create(:ticket_type, :free, event: created, quantity_available: 50, max_per_order: 10)
      created
    end
    create_event_day_rehearsal_approval(event: event) unless EventDayRehearsal.active_approval(event)
    submission = LivePilotReviews::Manager.submit!(
      event: event, attributes: valid_live_pilot_attributes(event: event, inventory_cap: inventory_cap),
      actor: create(:user, :admin)
    )
    LivePilotReviews::Manager.approve!(submission: submission, actor: create(:user, :admin))
  end

  def create_live_pilot_run(event: nil, inventory_cap: 10)
    approval = create_live_pilot_approval(event: event, inventory_cap: inventory_cap)
    run = LivePilotRuns::Manager.start!(approval: approval, actor: create(:user, :admin))
    { event: approval.event, approval: approval, run: run }
  end

  def safe_live_pilot_external_metrics
    {
      provider_healthy: true, provider_status_reference: "restricted-provider/status",
      checkout_p95_ms: 500, scanner_sync_lag_seconds: 10, support_contacts_count: 0,
      refund_request_count: 0, support_coverage_confirmed: true, guam_communications_current: true
    }
  end

  def record_safe_live_pilot_checkpoint(run)
    LivePilotMetrics::Manager.record!(
      run: run, actor: create(:user, :admin), attributes: {
        evidence_reference: "restricted-pilot/metrics/#{run.id}", evidence_digest: "b" * 64,
        external_metrics: safe_live_pilot_external_metrics
      }
    )
  end

  def valid_live_pilot_completion_attributes
    {
      completion_evidence_reference: "restricted-pilot/closeout",
      completion_evidence_digest: "f" * 64,
      completion_results: LivePilotRuns::Manager::COMPLETION_BOOLEAN_FIELDS.index_with(true).merge(
        LivePilotRuns::Manager::COMPLETION_ZERO_FIELDS.index_with(0)
      )
    }
  end

  def support_window(starts_at, ends_at, label)
    {
      starts_at: starts_at.iso8601, ends_at: ends_at.iso8601,
      primary_reference: "restricted-support/#{label}/primary",
      backup_reference: "restricted-support/#{label}/backup",
      channel_reference: "restricted-support/#{label}/channel",
      acknowledgement_reference: "restricted-support/#{label}/ack"
    }
  end
end

RSpec.configure do |config|
  config.include LivePilotHelpers
end
