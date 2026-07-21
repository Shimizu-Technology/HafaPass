require "rails_helper"

RSpec.describe PilotReadinessReviews::Manager do
  let(:submitter) { create(:user, :admin) }
  let(:approver) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :payout_ready) }
  let(:event) do
    create(:event, organizer_profile: profile, organization: profile.organization).tap do |record|
      create(:ticket_type, event: record)
    end
  end
  let(:attributes) do
    {
      evidence_reference: "private/pilot/event-#{event.id}",
      evidence_digest: "b" * 64,
      controls: PilotReadinessReview::CONTROL_KEYS.index_with(true),
      assignments: PilotReadinessReview::ASSIGNMENT_KEYS.index_with do |role|
        { name: role.humanize, contact_reference: "private-directory/#{role}" }
      end,
      effective_at: 1.minute.ago,
      expires_at: 30.days.from_now
    }
  end

  it "requires a second administrator and activates the exact event snapshot" do
    submission = described_class.submit!(event: event, attributes: attributes, actor: submitter)

    expect do
      described_class.approve!(submission: submission, actor: submitter)
    end.to raise_error(described_class::ReviewError, /cannot approve their own/)

    approval = described_class.approve!(submission: submission, actor: approver)

    expect(approval).to be_active
    expect(approval.application_revision).to eq(PilotReadiness.application_revision)
    expect(PilotReadiness.active_approval(event)).to eq(approval)
    expect(AuditLog.where(auditable: approval, action: "pilot_readiness.approved")).to exist
  end

  it "does not require the later validation, rehearsal, or live-money gates before readiness submission" do
    allow(event).to receive(:publish_checklist).and_return([
      { code: "title", label: "Event title added", complete: true },
      { code: "pilot_readiness_approved", label: "Readiness approved", complete: false },
      { code: "pilot_validation_approved", label: "Validation approved", complete: false },
      { code: "event_day_rehearsal_approved", label: "Rehearsal approved", complete: false },
      { code: "live_money_approved", label: "Live-money approved", complete: false }
    ])

    expect do
      described_class.submit!(event: event, attributes: attributes, actor: submitter)
    end.to change(event.pilot_readiness_reviews, :count).by(1)
  end


  it "invalidates approval when the deployed application revision changes" do
    original_revision = ENV["GIT_SHA"]
    ENV["GIT_SHA"] = "pilot-candidate-a"
    submission = described_class.submit!(event: event, attributes: attributes, actor: submitter)
    approval = described_class.approve!(submission: submission, actor: approver)

    ENV["GIT_SHA"] = "pilot-candidate-b"

    expect(approval.reload).not_to be_active
    expect(PilotReadiness.active_approval(event)).to be_nil
  ensure
    original_revision.nil? ? ENV.delete("GIT_SHA") : ENV["GIT_SHA"] = original_revision
  end

  it "invalidates approval after a material event change without mutating evidence" do
    submission = described_class.submit!(event: event, attributes: attributes, actor: submitter)
    approval = described_class.approve!(submission: submission, actor: approver)

    event.update!(max_capacity: event.max_capacity - 1)

    expect(approval.reload).not_to be_active
    expect(PilotReadiness.active_approval(event)).to be_nil
  end

  it "does not invalidate approval when sold inventory changes" do
    submission = described_class.submit!(event: event, attributes: attributes, actor: submitter)
    approval = described_class.approve!(submission: submission, actor: approver)

    event.ticket_types.first.update!(quantity_sold: 1)

    expect(approval.reload).to be_active
  end

  it "invalidates approval when physical seat or accessibility metadata changes" do
    venue = create(:venue)
    event.update!(venue: venue)
    layout = create(:venue_layout, venue: venue, organization: event.organization)
    section = create(:seating_section, venue_layout: layout)
    row = create(:seating_row, seating_section: section)
    zone = create(:seating_price_zone, venue_layout: layout)
    venue_seat = create(:venue_seat, seating_row: row, seating_price_zone: zone, companion_group: "A")
    configuration = create(:event_seating_configuration, event: event, venue_layout: layout)
    EventPriceZone.create!(event_seating_configuration: configuration, seating_price_zone: zone,
      ticket_type: event.ticket_types.first)
    create(:event_seat, event_seating_configuration: configuration, venue_seat: venue_seat,
      ticket_type: event.ticket_types.first)
    submission = described_class.submit!(event: event, attributes: attributes, actor: submitter)
    approval = described_class.approve!(submission: submission, actor: approver)

    venue_seat.update!(obstructed_view: true, view_note: "Partial stage obstruction")

    expect(approval.reload).not_to be_active
  end

  it "revokes approval with an append-only decision" do
    submission = described_class.submit!(event: event, attributes: attributes, actor: submitter)
    approval = described_class.approve!(submission: submission, actor: approver)

    revocation = described_class.revoke!(approval: approval, actor: submitter, reason: "Venue withdrew availability")

    expect(revocation).to be_decision_revocation
    expect(approval.reload).to be_revoked
    expect(PilotReadiness.active_approval(event)).to be_nil
  end
end
