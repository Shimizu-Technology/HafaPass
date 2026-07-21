require "rails_helper"

RSpec.describe PilotReadinessReview do
  let(:profile) { create(:organizer_profile, :payout_ready) }
  let(:event) do
    create(:event, organizer_profile: profile, organization: profile.organization).tap do |record|
      create(:ticket_type, event: record)
    end
  end

  it "requires every operational control and named assignment field" do
    review = build(:pilot_readiness_review, event: event, controls: {}, assignments: {})

    expect(review).not_to be_valid
    expect(review.errors[:controls].join).to include("low_risk_scope")
    expect(review.errors[:assignments].join).to include("primary_on_call.name", "venue_safety_contact.contact_reference")
  end

  it "is append-only" do
    review = create(:pilot_readiness_review, event: event)

    expect { review.update!(evidence_reference: "changed") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect(review.reload.evidence_reference).not_to eq("changed")
  end
end
