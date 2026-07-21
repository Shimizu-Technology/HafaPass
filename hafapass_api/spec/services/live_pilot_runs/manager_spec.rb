require "rails_helper"

RSpec.describe LivePilotRuns::Manager do
  it "rejects non-administrators at every operational service boundary" do
    approval = create_live_pilot_approval

    expect do
      described_class.start!(approval: approval, actor: create(:user, :organizer))
    end.to raise_error(described_class::RunError, /Only an administrator/)
  end

  it "starts, safety-pauses, and resumes only after incident resolution and a safe checkpoint" do
    chain = create_live_pilot_run
    actor = create(:user, :admin)
    incident = LivePilotIncidents::Manager.report!(
      run: chain[:run], actor: actor, attributes: {
        severity: "p1", category: "uncertain_payment", summary: "Provider result unknown",
        evidence_reference: "restricted-incidents/unknown", evidence_digest: "c" * 64
      }
    )
    expect(chain[:run].reload).to be_status_paused
    expect(chain[:event].reload.sales_suspension_reason).to include("[GATE I]")

    expect do
      described_class.resume!(run: chain[:run], actor: actor, reason: "Retry")
    end.to raise_error(described_class::RunError, /Resolve every/)

    LivePilotIncidents::Manager.resolve!(incident: incident, actor: actor, attributes: {
      summary: "Provider confirmed no charge", evidence_reference: "restricted-incidents/resolved",
      evidence_digest: "d" * 64
    })
    record_safe_live_pilot_checkpoint(chain[:run])
    described_class.resume!(run: chain[:run], actor: actor, reason: "Evidence is clear")

    expect(chain[:run].reload).to be_status_active
    expect(chain[:event].reload.sales_suspended_at).to be_nil
  end

  it "pauses automatically when a monitoring threshold is breached" do
    chain = create_live_pilot_run
    metrics = safe_live_pilot_external_metrics.merge(provider_healthy: false)

    snapshot = LivePilotMetrics::Manager.record!(run: chain[:run], actor: create(:user, :admin), attributes: {
      evidence_reference: "restricted-pilot/metrics/provider", evidence_digest: "e" * 64,
      external_metrics: metrics
    })

    expect(snapshot.breached_thresholds).to include("provider_health")
    expect(chain[:run].reload).to be_status_paused
  end

  it "keeps door orders out of online checkout conversion" do
    chain = create_live_pilot_run
    create(:order, event: chain[:event], status: :completed, source: "box_office", payment_method: "door_cash",
      subtotal_cents: 0, service_fee_cents: 0, total_cents: 0)
    MarketplaceFunnelEvent.create!(
      event: chain[:event], stage: :checkout_started, visitor_hash: "visitor-online", occurred_at: Time.current
    )

    metrics = LivePilotMetrics::Manager.local_metrics(chain[:run])

    expect(metrics).to include(
      "purchase_count" => 1, "online_purchase_count" => 0, "checkout_conversion_bps" => 0
    )
  end

  it "rejects invalid, pre-run, and future monitoring timestamps" do
    chain = create_live_pilot_run
    actor = create(:user, :admin)
    base = {
      evidence_reference: "restricted-pilot/metrics/time", evidence_digest: "e" * 64,
      external_metrics: safe_live_pilot_external_metrics
    }

    expect do
      LivePilotMetrics::Manager.record!(run: chain[:run], actor: actor,
        attributes: base.merge(observed_at: "not-a-time"))
    end.to raise_error(LivePilotMetrics::Manager::MetricError, /ISO-8601/)
    expect do
      LivePilotMetrics::Manager.record!(run: chain[:run], actor: actor,
        attributes: base.merge(observed_at: 1.hour.ago.iso8601))
    end.to raise_error(LivePilotMetrics::Manager::MetricError, /predate/)
    expect do
      LivePilotMetrics::Manager.record!(run: chain[:run], actor: actor,
        attributes: base.merge(observed_at: 1.hour.from_now.iso8601))
    end.to raise_error(LivePilotMetrics::Manager::MetricError, /future/)
  end

  it "requires a post-completion safe checkpoint and reconciled evidence before closeout" do
    chain = create_live_pilot_run
    actor = create(:user, :admin)
    record_safe_live_pilot_checkpoint(chain[:run])
    chain[:event].update_columns(status: Event.statuses[:completed], updated_at: Time.current)

    expect do
      described_class.complete!(run: chain[:run], actor: actor,
        attributes: valid_live_pilot_completion_attributes)
    end.to raise_error(described_class::RunError, /final post-event safe monitoring checkpoint/)

    record_safe_live_pilot_checkpoint(chain[:run])
    result = described_class.complete!(run: chain[:run], actor: actor,
      attributes: valid_live_pilot_completion_attributes)
    expect(result.reload).to be_status_completed
    expect(result.live_pilot_run_actions.kind_completed.count).to eq(1)
  end

  it "rechecks current local operations instead of trusting a formerly safe snapshot" do
    chain = create_live_pilot_run
    actor = create(:user, :admin)
    chain[:event].update_columns(status: Event.statuses[:completed], updated_at: Time.current)
    record_safe_live_pilot_checkpoint(chain[:run])
    order = create(:order, :pending, event: chain[:event])
    create(:payment, order: order, status: :pending)

    expect do
      described_class.complete!(run: chain[:run], actor: actor,
        attributes: valid_live_pilot_completion_attributes)
    end.to raise_error(described_class::RunError, /pending_payment_count/)
  end

  it "records abort semantics separately and clears its Gate I suspension for an approved recovery run" do
    chain = create_live_pilot_run
    actor = create(:user, :admin)

    described_class.abort!(run: chain[:run], actor: actor, reason: "Provider outcome requires recovery")
    aborted = chain[:run].reload
    expect(aborted).to be_status_aborted
    expect(aborted).to have_attributes(
      abort_reason: "Provider outcome requires recovery", paused_at: nil, pause_reason: nil
    )
    expect(aborted.aborted_at).to be_present
    expect(chain[:event].reload.sales_suspension_reason).to start_with("[GATE I]")

    LivePilotReviews::Manager.revoke!(
      approval: chain[:approval], actor: actor, reason: "Authorize a separately reviewed recovery plan"
    )
    recovery_approval = create_live_pilot_approval(event: chain[:event])
    recovery = described_class.start!(approval: recovery_approval, actor: actor)

    expect(recovery).to be_status_active
    expect(chain[:event].reload).to have_attributes(sales_suspended_at: nil, sales_suspension_reason: nil)
  end

  it "clears a Gate I suspension when a paused run completes" do
    chain = create_live_pilot_run
    actor = create(:user, :admin)
    described_class.pause!(run: chain[:run], actor: actor, reason: "Hold through closeout")
    chain[:event].update_columns(status: Event.statuses[:completed], updated_at: Time.current)
    record_safe_live_pilot_checkpoint(chain[:run])

    described_class.complete!(run: chain[:run], actor: actor,
      attributes: valid_live_pilot_completion_attributes)

    expect(chain[:event].reload).to have_attributes(sales_suspended_at: nil, sales_suspension_reason: nil)
  end

  it "enforces the active pilot inventory cap against committed ticket quantities" do
    chain = create_live_pilot_run(inventory_cap: 2)
    ticket_type = chain[:event].ticket_types.first
    order = create(:order, event: chain[:event], subtotal_cents: 0, service_fee_cents: 0, total_cents: 0)
    create(:order_item, order: order, ticket_type: ticket_type, quantity: 2, unit_price_cents: 0,
      subtotal_cents: 0, fee_cents: 0, organizer_fee_cents: 0, organizer_proceeds_cents: 0)
    allow(Rails.env).to receive(:production?).and_return(true)

    expect do
      LivePilot.enforce_inventory_cap!(event: chain[:event], requested_quantity: 1)
    end.to raise_error(LivePilot::InventoryLimitError, /inventory cap has been reached/)
  end
end
