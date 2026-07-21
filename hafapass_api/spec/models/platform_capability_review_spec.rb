require "rails_helper"

RSpec.describe PlatformCapabilityReview do
  let(:submitter) { create(:user, :admin) }
  let(:controls) { PlatformCapabilities.required_controls("policy_register").index_with { true } }
  let(:attributes) do
    {
      actor_user: submitter,
      capability: "policy_register",
      decision: :submission,
      evidence_reference: "legal-register-2026-07",
      evidence_digest: "a" * 64,
      configuration_digest: PlatformCapabilities.configuration_digest("policy_register"),
      controls: controls,
      effective_at: 1.minute.ago,
      expires_at: 90.days.from_now
    }
  end

  it "requires every capability-specific evidence control" do
    review = described_class.new(attributes.merge(controls: controls.except("counsel_approved")))

    expect(review).not_to be_valid
    expect(review.errors[:controls].join).to include("counsel_approved")
  end

  it "reports a missing evidence digest as blank at the application boundary" do
    review = described_class.new(attributes.merge(evidence_digest: nil))

    expect(review).not_to be_valid
    expect(review.errors[:evidence_digest]).to include("can't be blank")
  end

  it "is append-only" do
    review = described_class.create!(attributes)

    expect { review.update(evidence_reference: "changed") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect(review.destroy).to be(false)
  end

  it "requires an independent approver and an exact parent snapshot" do
    submission = described_class.create!(attributes)
    approval = described_class.new(attributes.merge(
      decision: :approval, parent_review: submission, evidence_reference: "different"
    ))

    expect(approval).not_to be_valid
    expect(approval.errors[:actor_user]).to include("must be independent from the evidence submitter")
    expect(approval.errors[:base]).to include("Evidence snapshot must match the parent review")
  end
end
