require "rails_helper"

RSpec.describe LiveMoneyProofReview do
  it "accepts a real cent-exact charge, refund, payout, bank, and negative-balance chain" do
    chain = create_live_money_proof_chain
    review = described_class.new(chain[:attributes].merge(
      organization: chain[:organization], connected_account: chain[:organization].payout_account,
      proof_event: chain[:event], actor_user: create(:user, :admin), decision: :submission,
      application_revision: PilotReadiness.application_revision,
      provider_state_digest: chain[:organization].payout_account.readiness_state_digest,
      platform_configuration_digest: LiveMoneyProof.platform_configuration_digest
    ))

    expect(review).to be_valid
  end

  it "rejects simulated provider records and a nonzero unexplained variance" do
    chain = create_live_money_proof_chain
    chain[:payment].update!(provider_payment_id: "sim_pi_not_live")
    chain[:attributes][:reconciliation_results][:charge_variance_cents] = 1
    review = described_class.new(chain[:attributes].merge(
      organization: chain[:organization], connected_account: chain[:organization].payout_account,
      proof_event: chain[:event], actor_user: create(:user, :admin), decision: :submission,
      application_revision: PilotReadiness.application_revision,
      provider_state_digest: chain[:organization].payout_account.readiness_state_digest,
      platform_configuration_digest: LiveMoneyProof.platform_configuration_digest
    ))

    expect(review).not_to be_valid
    expect(review.errors[:payment]).to include(/real provider payment reference/)
    expect(review.errors[:reconciliation_results]).to include(/charge_variance_cents must be zero/)
  end

  it "is append-only" do
    chain = create_live_money_proof_chain
    submission = LiveMoneyProofReviews::Manager.submit!(
      organization: chain[:organization], attributes: chain[:attributes], actor: create(:user, :admin)
    )

    expect { submission.update!(evidence_reference: "changed") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect(submission.destroy).to be(false)
  end
end
