require "rails_helper"

RSpec.describe EventDayRehearsalReviews::Manager do
  let(:submitter) { create(:user, :admin) }
  let(:approver) { create(:user, :admin) }
  let(:event) do
    profile = create(:organizer_profile, :payout_ready)
    create(:event, organizer_profile: profile, organization: profile.organization).tap do |record|
      create(:ticket_type, event: record)
    end
  end

  it "refuses rehearsal evidence before Gate F approval" do
    expect do
      described_class.submit!(
        event: event, attributes: valid_event_day_rehearsal_attributes(event: event), actor: submitter
      )
    end.to raise_error(described_class::ReviewError, /Gate F/)
  end

  it "independently approves the exact Gate F candidate" do
    validation = create_pilot_validation_approval(event: event)
    submission = described_class.submit!(
      event: event, attributes: valid_event_day_rehearsal_attributes(event: event), actor: submitter
    )

    expect do
      described_class.approve!(submission: submission, actor: submitter)
    end.to raise_error(described_class::ReviewError, /cannot approve their own/)

    approval = described_class.approve!(submission: submission, actor: approver)
    expect(approval.pilot_validation_review).to eq(validation)
    expect(EventDayRehearsal.active_approval(event)).to eq(approval)
    expect(AuditLog.where(auditable: approval, action: "event_day_rehearsal.approved")).to exist
    audit_json = AuditLog.find_by!(auditable: approval, action: "event_day_rehearsal.approved").after_data.to_json
    expect(audit_json).not_to include("private-rehearsal/testers", "private_contact_reference")
  end

  it "invalidates rehearsal approval when Gate F is revoked" do
    validation = create_pilot_validation_approval(event: event)
    submission = described_class.submit!(
      event: event, attributes: valid_event_day_rehearsal_attributes(event: event), actor: submitter
    )
    described_class.approve!(submission: submission, actor: approver)

    PilotValidationReviews::Manager.revoke!(
      approval: validation, actor: submitter, reason: "Device matrix must be rerun"
    )

    expect(EventDayRehearsal.active_approval(event)).to be_nil
  end

  it "allows only one current rehearsal submission" do
    create_pilot_validation_approval(event: event)
    described_class.submit!(
      event: event, attributes: valid_event_day_rehearsal_attributes(event: event), actor: submitter
    )

    expect do
      described_class.submit!(
        event: event, attributes: valid_event_day_rehearsal_attributes(event: event), actor: approver
      )
    end.to raise_error(described_class::ReviewError, /current Gate G rehearsal submission/)
  end

  it "invalidates rehearsal approval after a deployed revision change" do
    original_revision = ENV["GIT_SHA"]
    ENV["GIT_SHA"] = "gate-g-candidate-a"
    create_pilot_validation_approval(event: event)
    submission = described_class.submit!(
      event: event, attributes: valid_event_day_rehearsal_attributes(event: event), actor: submitter
    )
    described_class.approve!(submission: submission, actor: approver)

    ENV["GIT_SHA"] = "gate-g-candidate-b"

    expect(EventDayRehearsal.active_approval(event)).to be_nil
  ensure
    original_revision.nil? ? ENV.delete("GIT_SHA") : ENV["GIT_SHA"] = original_revision
  end
end
