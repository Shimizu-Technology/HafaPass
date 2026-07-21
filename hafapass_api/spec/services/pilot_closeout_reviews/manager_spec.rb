require "rails_helper"

RSpec.describe PilotCloseoutReviews::Manager do
  it "requires administrators and a completed, locally reconciled Gate I run" do
    run = create_completed_live_pilot_run
    order = create(:order, :pending, event: run.event)
    create(:payment, order: order, status: :pending)

    expect do
      described_class.submit!(
        run: run, attributes: valid_pilot_closeout_attributes, actor: create(:user, :organizer)
      )
    end.to raise_error(described_class::ReviewError, /Only an administrator/)
    expect do
      described_class.submit!(
        run: run, attributes: valid_pilot_closeout_attributes, actor: create(:user, :admin)
      )
    end.to raise_error(described_class::ReviewError, /pending_payment_count/)
  end

  it "records a signed metric report and requires an independent second administrator" do
    run = create_completed_live_pilot_run
    submitter = create(:user, :admin)
    submission = described_class.submit!(
      run: run, attributes: valid_pilot_closeout_attributes, actor: submitter
    )

    expect(submission).to be_decision_submission
    expect(submission.local_metrics).to include(
      "checkout_conversion_bps", "checkout_abandonment_bps", "no_show_rate_bps",
      "refund_average_seconds", "payout_variance_cents", "partner_attributed_order_count"
    )
    expect do
      described_class.approve!(submission: submission, actor: submitter)
    end.to raise_error(described_class::ReviewError, /cannot approve their own/)

    approval = described_class.approve!(submission: submission, actor: create(:user, :admin))
    expect(approval).to be_decision_approval
    expect(PilotCloseout.active_approval(run)).to eq(approval)
    expect(PilotCloseout.metric_report(approval)).to include("support_contacts_per_100_orders" => 0)
  end

  it "rejects approval when local operations change after submission" do
    submission = create_pilot_closeout_submission
    SupportNote.create!(event: submission.event, author_user: create(:user, :admin), body: "Follow-up recorded")

    expect do
      described_class.approve!(submission: submission, actor: create(:user, :admin))
    end.to raise_error(described_class::ReviewError, /Local operations or the application changed/)
  end

  it "does not approve expansion while a retrospective blocker remains planned" do
    submission = create_pilot_closeout_submission(
      expansion_decision: "limited_guam_expansion", blocking_action: true
    )

    expect do
      described_class.approve!(submission: submission, actor: create(:user, :admin))
    end.to raise_error(described_class::ReviewError, /expansion-blocking/)
  end

  it "records a bounded Guam-only expansion scope when evidence and blockers are complete" do
    submission = create_pilot_closeout_submission(expansion_decision: "limited_guam_expansion")

    approval = described_class.approve!(submission: submission, actor: create(:user, :admin))

    expect(approval).to be_expansion_decision_limited_guam_expansion
    expect(approval.expansion_scope).to include(
      "event_limit" => 3, "max_inventory_per_event" => 500, "new_regions" => false
    )
  end

  it "requires server-visible temporary devices to be revoked before submission" do
    run = create_completed_live_pilot_run
    create(:scanner_device, event: run.event, organization: run.event.organization, status: :active)

    expect do
      described_class.submit!(
        run: run, attributes: valid_pilot_closeout_attributes, actor: create(:user, :admin)
      )
    end.to raise_error(described_class::ReviewError, /active_scanner_device_count/)
  end

  it "keeps closeout reviews append-only" do
    submission = create_pilot_closeout_submission

    expect(submission.update(evidence_reference: "changed")).to be(false)
    expect(submission.destroy).to be(false)
  end

  it "requires a rationale and a future due date for planned actions" do
    run = create_completed_live_pilot_run
    attributes = valid_pilot_closeout_attributes
    attributes[:expansion_scope][:rationale] = ""

    expect do
      described_class.submit!(run: run, attributes: attributes, actor: create(:user, :admin))
    end.to raise_error(described_class::ReviewError, /decision rationale/)

    attributes[:expansion_scope][:rationale] = "Hold until the follow-up is complete."
    attributes[:retrospective_actions][0].merge!(status: "planned", due_at: 1.hour.ago.iso8601)
    expect do
      described_class.submit!(run: run, attributes: attributes, actor: create(:user, :admin))
    end.to raise_error(described_class::ReviewError, /must be after signing/)
  end

  it "rejects expansion beyond the bounded Guam decision contract" do
    run = create_completed_live_pilot_run
    too_many_events = valid_pilot_closeout_attributes(expansion_decision: "limited_guam_expansion")
    too_many_events[:expansion_scope][:event_limit] = 11
    expect do
      described_class.submit!(run: run, attributes: too_many_events, actor: create(:user, :admin))
    end.to raise_error(described_class::ReviewError, /1–10 events/)

    new_region = valid_pilot_closeout_attributes(expansion_decision: "limited_guam_expansion")
    new_region[:expansion_scope][:new_regions] = true
    expect do
      described_class.submit!(run: run, attributes: new_region, actor: create(:user, :admin))
    end.to raise_error(described_class::ReviewError, /cannot authorize new regions/)

    unsupported_window = valid_pilot_closeout_attributes(expansion_decision: "repeat_bounded_pilot")
    unsupported_window[:expansion_scope][:expires_at] = 91.days.from_now.iso8601
    expect do
      described_class.submit!(run: run, attributes: unsupported_window, actor: create(:user, :admin))
    end.to raise_error(described_class::ReviewError, /within 90 days/)
  end

  it "invalidates an approval when local evidence changes and accepts a replacement snapshot" do
    submission = create_pilot_closeout_submission
    approval = described_class.approve!(submission: submission, actor: create(:user, :admin))
    expect(PilotCloseout.active_approval(submission.live_pilot_run)).to eq(approval)

    SupportNote.create!(event: submission.event, author_user: create(:user, :admin), body: "Late closeout note")

    expect(PilotCloseout.active_approval(submission.live_pilot_run)).to be_nil
    replacement = described_class.submit!(
      run: submission.live_pilot_run, attributes: valid_pilot_closeout_attributes,
      actor: create(:user, :admin)
    )
    expect(replacement.local_state_digest).not_to eq(submission.local_state_digest)
  end

  it "does not coerce arbitrary strings into signed attestations" do
    run = create_completed_live_pilot_run
    attributes = valid_pilot_closeout_attributes
    attributes[:reconciliation_results]["sales"] = "yes"

    expect do
      described_class.submit!(run: run, attributes: attributes, actor: create(:user, :admin))
    end.to raise_error(described_class::ReviewError, /must affirm: sales/)
  end
end
