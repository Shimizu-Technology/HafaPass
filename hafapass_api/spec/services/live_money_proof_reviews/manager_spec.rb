require "rails_helper"

RSpec.describe LiveMoneyProofReviews::Manager do
  it "rejects a non-administrator evidence submitter" do
    chain = create_live_money_proof_chain

    expect do
      described_class.submit!(organization: chain[:organization], attributes: chain[:attributes],
        actor: create(:user, :organizer))
    end.to raise_error(described_class::ReviewError, /Only an administrator/)
  end

  it "requires an independent decision and produces a current revocable Gate H approval" do
    chain = create_live_money_proof_chain
    submitter = create(:user, :admin)
    submission = described_class.submit!(
      organization: chain[:organization], attributes: chain[:attributes], actor: submitter
    )

    expect do
      described_class.approve!(submission: submission, actor: submitter)
    end.to raise_error(described_class::ReviewError, /cannot approve/)

    approval = described_class.approve!(submission: submission, actor: create(:user, :admin))
    expect(LiveMoneyProof.active_approval(chain[:organization])).to eq(approval)

    described_class.revoke!(approval: approval, actor: create(:user, :admin), reason: "Bank path changed")
    expect(LiveMoneyProof.active_approval(chain[:organization])).to be_nil
  end

  it "fails closed when the provider account changes after submission" do
    chain = create_live_money_proof_chain
    submission = described_class.submit!(organization: chain[:organization], attributes: chain[:attributes],
      actor: create(:user, :admin))
    account = chain[:organization].payout_account
    ConnectedAccounts::Manager.sync!(account: account,
      attributes: { provider_account_id: "replacement-bank-account" }, actor: create(:user, :admin))

    expect do
      described_class.approve!(submission: submission, actor: create(:user, :admin))
    end.to raise_error(described_class::ReviewError, /state changed/)
  end

  it "deactivates an approval when the connected account changes afterward" do
    chain = create_live_money_proof_chain
    submission = described_class.submit!(organization: chain[:organization], attributes: chain[:attributes],
      actor: create(:user, :admin))
    described_class.approve!(submission: submission, actor: create(:user, :admin))

    ConnectedAccounts::Manager.sync!(account: chain[:organization].payout_account,
      attributes: { provider_account_id: "replacement-bank-account" }, actor: create(:user, :admin))

    expect(LiveMoneyProof.active_approval(chain[:organization])).to be_nil
  end

  it "deactivates an approval when live Stripe capability is disabled afterward" do
    chain = create_live_money_proof_chain
    submission = described_class.submit!(organization: chain[:organization], attributes: chain[:attributes],
      actor: create(:user, :admin))
    described_class.approve!(submission: submission, actor: create(:user, :admin))

    allow(PlatformCapabilities).to receive(:enabled?).with("stripe_live").and_return(false)

    expect(LiveMoneyProof.active_approval(chain[:organization])).to be_nil
  end
end
