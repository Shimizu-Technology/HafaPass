module PilotCloseoutHelpers
  def create_completed_live_pilot_run
    chain = create_live_pilot_run
    chain[:event].update_columns(status: Event.statuses[:completed], updated_at: Time.current)
    record_safe_live_pilot_checkpoint(chain[:run])
    LivePilotRuns::Manager.complete!(
      run: chain[:run], actor: create(:user, :admin), attributes: valid_live_pilot_completion_attributes
    )
    chain[:run].reload
  end

  def valid_pilot_closeout_attributes(expansion_decision: "hold", blocking_action: false)
    scope = {
      event_limit: 0, max_inventory_per_event: 0, expires_at: nil, new_regions: false,
      recommended_product_investments: [], product_evidence_reference: "",
      demand_evidence_reference: "", capacity_evidence_reference: "",
      rationale: "Hold expansion until the measured closeout is independently approved."
    }
    if expansion_decision == "repeat_bounded_pilot"
      scope.merge!(event_limit: 1, max_inventory_per_event: 250, expires_at: 30.days.from_now.iso8601)
    elsif expansion_decision == "limited_guam_expansion"
      scope.merge!(
        event_limit: 3, max_inventory_per_event: 500, expires_at: 60.days.from_now.iso8601,
        demand_evidence_reference: "restricted-closeout/demand",
        capacity_evidence_reference: "restricted-closeout/capacity"
      )
    end
    {
      evidence_reference: "restricted-closeout/gate-j", evidence_digest: "a" * 64,
      expansion_decision: expansion_decision,
      outcome_metrics: {
        support_contacts_count: 0, entry_latency_p50_ms: 120, entry_latency_p95_ms: 250,
        organizer_feedback_rating: 5, buyer_feedback_response_count: 0, buyer_feedback_rating: 0
      },
      reconciliation_results: PilotCloseoutReview::RECONCILIATION_FIELDS.index_with(true),
      cleanup_results: PilotCloseoutReview::CLEANUP_FIELDS.index_with(true),
      evidence_references: PilotCloseoutReview::EVIDENCE_REFERENCE_FIELDS.index_with do |field|
        "restricted-closeout/#{field}"
      end,
      retrospective_actions: [{
        title: "Publish the measured pilot retrospective", owner_reference: "restricted-owners/engineering",
        due_at: 7.days.from_now.iso8601, status: blocking_action ? "planned" : "completed", priority: "p2",
        evidence_reference: "restricted-closeout/retrospective/action-1", blocks_expansion: blocking_action
      }],
      expansion_scope: scope
    }
  end

  def create_pilot_closeout_submission(run: nil, **options)
    run ||= create_completed_live_pilot_run
    PilotCloseoutReviews::Manager.submit!(
      run: run, attributes: valid_pilot_closeout_attributes(**options), actor: create(:user, :admin)
    )
  end
end

RSpec.configure do |config|
  config.include PilotCloseoutHelpers
end
