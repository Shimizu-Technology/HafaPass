require "rails_helper"

RSpec.describe EventDayRehearsalReview do
  let(:event) do
    profile = create(:organizer_profile, :payout_ready)
    create(:event, organizer_profile: profile, organization: profile.organization).tap do |record|
      create(:ticket_type, event: record)
    end
  end
  let(:validation) { create_pilot_validation_approval(event: event) }
  let(:actor) { create(:user, :admin) }

  def build_review(attributes = {})
    values = valid_event_day_rehearsal_attributes(event: event)
    described_class.new(values.merge(
      event: event, pilot_validation_review: validation, actor_user: actor, decision: :submission,
      event_state_digest: validation.event_state_digest, application_revision: PilotReadiness.application_revision
    ).merge(attributes))
  end

  it "requires three distinct physical devices" do
    review = build_review
    review.device_results = review.device_results.first(2)

    expect(review).not_to be_valid
    expect(review.errors[:device_results]).to include(/at least three physical devices/)
  end

  it "rejects unreconciled queues and slow offline feedback" do
    review = build_review
    review.device_results[0]["queued_actions_after_sync"] = 1
    review.reconciliation_results["offline_feedback_p95_ms"] = 101

    expect(review).not_to be_valid
    expect(review.errors[:device_results]).to include(/queue must drain/)
    expect(review.errors[:reconciliation_results]).to include(/at most 100 ms/)
  end

  it "requires every incident scenario and scan scenario" do
    review = build_review
    review.scan_results["refunded"] = false
    review.incident_drills["venue_network_loss"]["status"] = "failed"

    expect(review).not_to be_valid
    expect(review.errors[:scan_results]).to include(/refunded/)
    expect(review.errors[:incident_drills]).to include(/venue_network_loss/)
  end

  it "rejects an overlong manifest lifetime and mismatched generated-ticket reconciliation" do
    review = build_review
    review.manifest_results["expires_at"] = 25.hours.from_now.iso8601
    review.reconciliation_results["generated_ticket_count"] = 501

    expect(review).not_to be_valid
    expect(review.errors[:manifest_results]).to include(/no more than 24 hours/)
    expect(review.errors[:reconciliation_results]).to include(/must match the signed manifest/)
  end

  it "reports malformed manifest integers once on the manifest field" do
    review = build_review
    review.manifest_results["version"] = "not-an-integer"
    review.manifest_results["ticket_count"] = "not-an-integer"

    expect(review).not_to be_valid
    expect(review.errors[:manifest_results]).to include("version must be an integer", "ticket_count must be an integer")
    expect(review.errors[:manifest_results]).not_to include("version must be positive")
    expect(review.errors[:manifest_results]).not_to include("must contain at least 500 generated tickets")
    expect(review.errors[:reconciliation_results]).not_to include(/manifest ticket_count/)
    expect(review.errors[:reconciliation_results]).not_to include(/must match the signed manifest/)
  end

  it "does not add downstream device errors for malformed integer fields" do
    review = build_review
    review.device_results[0]["reconnect_order"] = "invalid"
    review.device_results[0]["queued_actions_before_sync"] = "invalid"
    review.device_results[0]["queued_actions_after_sync"] = "invalid"
    review.device_results[0]["conflicts_observed"] = "invalid"
    review.device_results[0]["immediate_feedback_p95_ms"] = "invalid"

    expect(review).not_to be_valid
    expect(review.errors[:device_results]).to include(
      "reconnect_order must be an integer",
      "queued_actions_before_sync must be an integer",
      "queued_actions_after_sync must be an integer",
      "conflicts_observed must be an integer",
      "immediate_feedback_p95_ms must be an integer"
    )
    expect(review.errors[:device_results]).not_to include(
      "reconnect order must uniquely cover every device",
      "every device must queue offline actions",
      "every device queue must drain to zero",
      "offline feedback p95 must be positive and at most 100 ms"
    )
  end

  it "is append-only" do
    review = build_review
    review.save!

    expect { review.update!(evidence_reference: "changed") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect(review.destroy).to be false
  end
end
