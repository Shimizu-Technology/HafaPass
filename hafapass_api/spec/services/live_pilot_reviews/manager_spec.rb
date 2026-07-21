require "rails_helper"

RSpec.describe LivePilotReviews::Manager do
  it "rejects non-administrators at the service boundary" do
    profile = create(:organizer_profile, :payout_ready)
    event = create(:event, :published, organizer_profile: profile, organization: profile.organization)
    create(:ticket_type, :free, event: event, quantity_available: 50)
    create_event_day_rehearsal_approval(event: event)

    expect do
      described_class.submit!(event: event, attributes: valid_live_pilot_attributes(event: event),
        actor: create(:user, :organizer))
    end.to raise_error(described_class::ReviewError, /Only an administrator/)
  end

  it "requires an independent decision and binds the exact Gate G candidate" do
    profile = create(:organizer_profile, :payout_ready)
    event = create(:event, :published, organizer_profile: profile, organization: profile.organization,
      starts_at: 1.day.from_now, ends_at: 1.day.from_now + 3.hours, max_capacity: 50)
    create(:ticket_type, :free, event: event, quantity_available: 50)
    create_event_day_rehearsal_approval(event: event)
    submitter = create(:user, :admin)
    submission = described_class.submit!(
      event: event, attributes: valid_live_pilot_attributes(event: event), actor: submitter
    )

    expect do
      described_class.approve!(submission: submission, actor: submitter)
    end.to raise_error(described_class::ReviewError, /cannot approve/)

    approval = described_class.approve!(submission: submission, actor: create(:user, :admin))
    expect(LivePilot.active_approval(event)).to eq(approval)
    expect(approval).to have_attributes(inventory_cap: 10, event_state_digest: PilotReadiness.event_state_digest(event))
  end

  it "rejects a cap larger than the bounded pilot maximum" do
    approval = create_live_pilot_approval
    event = approval.event
    LivePilotReviews::Manager.revoke!(approval: approval, actor: create(:user, :admin), reason: "Test replacement")

    expect do
      described_class.submit!(event: event,
        attributes: valid_live_pilot_attributes(event: event, inventory_cap: 251), actor: create(:user, :admin))
    end.to raise_error(described_class::ReviewError, /less than or equal to 250/)
  end

  it "accepts zero-tolerance count thresholds and invalidates approval after event drift" do
    profile = create(:organizer_profile, :payout_ready)
    event = create(:event, :published, organizer_profile: profile, organization: profile.organization,
      max_capacity: 50)
    create(:ticket_type, :free, event: event, quantity_available: 50)
    create_event_day_rehearsal_approval(event: event)
    attributes = valid_live_pilot_attributes(event: event)
    attributes[:thresholds][:maximum_scanner_conflicts] = 0
    attributes[:thresholds][:maximum_support_contacts_per_100_orders] = 0
    submission = described_class.submit!(event: event, attributes: attributes, actor: create(:user, :admin))
    approval = described_class.approve!(submission: submission, actor: create(:user, :admin))

    expect(LivePilot.active_approval(event)).to eq(approval)
    event.update!(title: "Materially changed pilot")
    expect(LivePilot.active_approval(event)).to be_nil
  end

  it "binds paid pilots to the exact current Gate H approval" do
    proof = create_live_money_proof_chain
    gate_h_submission = LiveMoneyProofReviews::Manager.submit!(
      organization: proof[:organization], attributes: proof[:attributes], actor: create(:user, :admin)
    )
    gate_h_approval = LiveMoneyProofReviews::Manager.approve!(
      submission: gate_h_submission, actor: create(:user, :admin)
    )
    event = create(:event, :published, organizer_profile: proof[:profile], organization: proof[:organization],
      starts_at: 1.day.from_now, ends_at: 1.day.from_now + 3.hours, max_capacity: 25)
    create(:ticket_type, event: event, quantity_available: 25, price_cents: 1000)
    create_event_day_rehearsal_approval(event: event)

    submission = described_class.submit!(
      event: event, attributes: valid_live_pilot_attributes(event: event), actor: create(:user, :admin)
    )
    approval = described_class.approve!(submission: submission, actor: create(:user, :admin))
    expect(approval.live_money_proof_review_id).to eq(gate_h_approval.id)

    LiveMoneyProofReviews::Manager.revoke!(
      approval: gate_h_approval, actor: create(:user, :admin), reason: "Provider evidence withdrawn"
    )
    expect(LivePilot.active_approval(event)).to be_nil
  end
end
