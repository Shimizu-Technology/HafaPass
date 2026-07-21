# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConnectedAccounts::Manager do
  let(:organization) { create(:organization) }
  let(:actor) { create(:user, :admin) }

  it "requires verified capabilities and independent evidence approval before becoming ready" do
    account = described_class.start!(organization: organization, provider: "paypal", actor: actor)
    expect(account).to be_status_onboarding
    expect(account).not_to be_payout_ready

    account = described_class.sync!(account: account, actor: actor, attributes: {
      provider_account_id: "paypal-seller-1", charges_enabled: false, payouts_enabled: true,
      details_submitted: true, requirements_due: []
    })
    expect(account).to be_status_onboarding

    account = described_class.sync!(account: account, actor: actor, attributes: {
      charges_enabled: true, payouts_enabled: true, details_submitted: true, requirements_due: []
    })
    expect(account).to be_status_requirements_due
    expect(account.requirements_due).to eq(["independent_readiness_approval"])
    expect(account).not_to be_payout_ready
    expect(organization.reload).not_to be_payout_ready
    expect(AuditLog.where(auditable: account).pluck(:action)).to include(
      "connected_account.onboarding_started", "connected_account.synced"
    )
  end

  it "moves accounts to requirements due and disabled states deterministically" do
    account = described_class.start!(organization: organization, provider: "manual", actor: actor)
    account = described_class.sync!(account: account, actor: actor,
      attributes: { details_submitted: true, requirements_due: ["bank_account_review"] })
    expect(account).to be_status_requirements_due

    account = described_class.sync!(account: account, actor: actor, attributes: { disabled: true })
    expect(account).to be_status_disabled
    expect(account).not_to be_payout_ready

    account = described_class.sync!(account: account, actor: actor, attributes: { details_submitted: true })
    expect(account).to be_status_disabled

    account = described_class.sync!(account: account, actor: actor, attributes: { disabled: false })
    expect(account).to be_status_requirements_due
  end
end
