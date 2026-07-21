require "rails_helper"

RSpec.describe PilotValidationReviews::Manager do
  let(:submitter) { create(:user, :admin) }
  let(:approver) { create(:user, :admin) }
  let(:event) do
    profile = create(:organizer_profile, :payout_ready)
    create(:event, organizer_profile: profile, organization: profile.organization).tap do |record|
      create(:ticket_type, event: record)
    end
  end

  it "refuses evidence before Gate E is approved" do
    expect do
      described_class.submit!(
        event: event, attributes: valid_pilot_validation_attributes(event: event), actor: submitter
      )
    end.to raise_error(described_class::ReviewError, /Gate E/)
  end

  it "independently approves evidence for the exact Gate E candidate" do
    readiness = create_pilot_readiness_approval(event: event)
    submission = described_class.submit!(
      event: event, attributes: valid_pilot_validation_attributes(event: event), actor: submitter
    )

    expect do
      described_class.approve!(submission: submission, actor: submitter)
    end.to raise_error(described_class::ReviewError, /cannot approve their own/)

    approval = described_class.approve!(submission: submission, actor: approver)
    expect(approval.pilot_readiness_review).to eq(readiness)
    expect(PilotValidation.active_approval(event)).to eq(approval)
    expect(AuditLog.where(auditable: approval, action: "pilot_validation.approved")).to exist
    audit_json = AuditLog.find_by!(auditable: approval, action: "pilot_validation.approved").after_data.to_json
    expect(audit_json).not_to include("private-qa/testers", "Qualified accessibility reviewer")
  end

  it "allows only one open candidate submission at a time" do
    create_pilot_readiness_approval(event: event)
    described_class.submit!(
      event: event, attributes: valid_pilot_validation_attributes(event: event), actor: submitter
    )

    expect do
      described_class.submit!(
        event: event, attributes: valid_pilot_validation_attributes(event: event), actor: approver
      )
    end.to raise_error(described_class::ReviewError, /current Gate F validation submission/)
  end

  it "invalidates approval after Gate E is revoked" do
    readiness = create_pilot_readiness_approval(event: event)
    submission = described_class.submit!(
      event: event, attributes: valid_pilot_validation_attributes(event: event), actor: submitter
    )
    described_class.approve!(submission: submission, actor: approver)

    PilotReadinessReviews::Manager.revoke!(
      approval: readiness, actor: submitter, reason: "Venue configuration must be rechecked"
    )

    expect(PilotValidation.active_approval(event)).to be_nil
  end

  it "invalidates approval after a deployed revision change" do
    original_revision = ENV["GIT_SHA"]
    ENV["GIT_SHA"] = "gate-f-candidate-a"
    create_pilot_readiness_approval(event: event)
    submission = described_class.submit!(
      event: event, attributes: valid_pilot_validation_attributes(event: event), actor: submitter
    )
    described_class.approve!(submission: submission, actor: approver)

    ENV["GIT_SHA"] = "gate-f-candidate-b"

    expect(PilotValidation.active_approval(event)).to be_nil
  ensure
    original_revision.nil? ? ENV.delete("GIT_SHA") : ENV["GIT_SHA"] = original_revision
  end
end
