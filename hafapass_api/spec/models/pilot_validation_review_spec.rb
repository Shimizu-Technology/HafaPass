require "rails_helper"

RSpec.describe PilotValidationReview do
  let(:event) do
    profile = create(:organizer_profile, :payout_ready)
    create(:event, organizer_profile: profile, organization: profile.organization).tap do |record|
      create(:ticket_type, event: record)
    end
  end
  let(:readiness) { create_pilot_readiness_approval(event: event) }
  let(:submitter) { create(:user, :admin) }

  it "requires concrete physical mobile-device evidence" do
    attributes = valid_pilot_validation_attributes(event: event)
    attributes[:device_matrix]["ios_safari"][:physical_device] = false
    review = described_class.new(attributes.merge(
      event: event,
      pilot_readiness_review: readiness,
      event_state_digest: readiness.event_state_digest,
      application_revision: PilotReadiness.application_revision,
      actor_user: submitter,
      decision: :submission
    ))

    expect(review).not_to be_valid
    expect(review.errors[:device_matrix]).to include("must use a physical device for ios_safari")
  end

  it "rejects load evidence that oversells or exceeds its stated guardrails" do
    attributes = valid_pilot_validation_attributes(event: event)
    attributes[:load_results][:oversell_count] = 1
    attributes[:load_results][:p95_latency_ms] = 2000
    review = described_class.new(attributes.merge(
      event: event,
      pilot_readiness_review: readiness,
      event_state_digest: readiness.event_state_digest,
      application_revision: PilotReadiness.application_revision,
      actor_user: submitter,
      decision: :submission
    ))

    expect(review).not_to be_valid
    expect(review.errors[:load_results]).to include(
      "p95 latency exceeds the declared budget",
      "must prove zero oversells and duplicate sales"
    )
  end

  it "does not permit operators to weaken the pilot latency and error budgets" do
    attributes = valid_pilot_validation_attributes(event: event)
    attributes[:load_results][:latency_budget_ms] = 2000
    attributes[:load_results][:error_rate_budget_percent] = "2.0"
    review = described_class.new(attributes.merge(
      event: event,
      pilot_readiness_review: readiness,
      event_state_digest: readiness.event_state_digest,
      application_revision: PilotReadiness.application_revision,
      actor_user: submitter,
      decision: :submission
    ))

    expect(review).not_to be_valid
    expect(review.errors[:load_results]).to include(
      "p95 latency budget cannot exceed 1500 ms for the pilot",
      "error-rate budget cannot exceed 1 percent for the pilot"
    )
  end

  it "is append-only" do
    readiness
    submission = PilotValidationReviews::Manager.submit!(
      event: event, attributes: valid_pilot_validation_attributes(event: event), actor: submitter
    )

    expect { submission.update!(reason: "rewrite") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect(submission.destroy).to be(false)
  end
end
