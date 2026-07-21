# frozen_string_literal: true

require "rails_helper"

RSpec.describe PaymentReadinessReviews::Manager do
  include ActiveSupport::Testing::TimeHelpers

  let(:submitter) { create(:user, :admin) }
  let(:approver) { create(:user, :admin) }
  let(:account) do
    create(:connected_account, with_readiness_approval: false, status: :requirements_due,
      requirements_due: ["independent_readiness_approval"])
  end
  let(:evidence) do
    {
      evidence_reference: "restricted/gate-b/paypal-account-1",
      evidence_digest: Digest::SHA256.hexdigest("redacted-provider-evidence"),
      provider_approval_reference: "paypal-partner-approval-1",
      merchant_of_record: "organizer",
      fee_tax_schedule_reference: "approved/fee-tax/2026-07",
      liability_schedule_reference: "approved/liability/2026-07",
      controls: PaymentReadinessReview::CONTROL_KEYS.index_with(true),
      effective_at: 1.hour.ago,
      expires_at: 6.months.from_now
    }
  end

  it "requires two people, preserves evidence, and revokes readiness append-only" do
    submission = described_class.submit!(account: account, attributes: evidence, actor: submitter)

    expect do
      described_class.approve!(submission: submission, actor: submitter)
    end.to raise_error(described_class::ReviewError, /cannot approve their own/)

    approval = described_class.approve!(submission: submission, actor: approver)
    expect(account.reload).to be_status_ready
    expect(account.requirements_due).to be_empty
    expect(account).to be_payout_ready
    expect(approval).to be_active
    expect { approval.update!(evidence_reference: "changed") }.to raise_error(ActiveRecord::ReadonlyAttributeError)

    revocation = described_class.revoke!(approval: approval, actor: submitter,
      reason: "Provider authorization withdrawn")
    expect(revocation).to be_decision_revocation
    expect(account.reload).to be_status_requirements_due
    expect(account.requirements_due).to include("independent_readiness_approval")
    expect(account).not_to be_payout_ready
    expect(AuditLog.where(auditable_type: "PaymentReadinessReview").pluck(:action)).to contain_exactly(
      "payment_readiness.submitted", "payment_readiness.approved", "payment_readiness.revoked"
    )
  end

  it "rejects incomplete or expired evidence" do
    expect do
      described_class.submit!(account: account, attributes: evidence.merge(
        controls: evidence.fetch(:controls).merge("bank_account_confirmed" => false)
      ), actor: submitter)
    end.to raise_error(described_class::ReviewError, /bank_account_confirmed/)

    submission = described_class.submit!(account: account, attributes: evidence.merge(
      effective_at: 2.days.ago, expires_at: 1.day.ago
    ), actor: submitter)
    expect do
      described_class.approve!(submission: submission, actor: approver)
    end.to raise_error(described_class::ReviewError, /expired/)
  end

  it "does not accept capability booleans as provider evidence" do
    account.update!(charges_enabled: false)

    expect do
      described_class.submit!(account: account, attributes: evidence, actor: submitter)
    end.to raise_error(described_class::ReviewError, /capabilities and onboarding/)
  end

  it "records a reasoned rejection and allows a corrected submission" do
    submission = described_class.submit!(account: account, attributes: evidence, actor: submitter)
    rejection = described_class.reject!(submission: submission, actor: approver,
      reason: "The approval excludes organizer payouts")

    expect(rejection).to be_decision_rejection
    expect(rejection.reason).to eq("The approval excludes organizer payouts")
    expect(account.pending_payment_readiness_submission).to be_nil
    expect do
      described_class.approve!(submission: submission, actor: approver)
    end.to raise_error(described_class::ReviewError, /already has a decision/)

    corrected = described_class.submit!(account: account, attributes: evidence.merge(
      evidence_digest: Digest::SHA256.hexdigest("corrected-provider-evidence")
    ), actor: submitter)
    expect(account.pending_payment_readiness_submission).to eq(corrected)
  end

  it "fails readiness closed after approval evidence expires" do
    submission = described_class.submit!(account: account, attributes: evidence.merge(
      expires_at: 1.hour.from_now
    ), actor: submitter)
    approval = described_class.approve!(submission: submission, actor: approver)
    expect(account.reload).to be_payout_ready

    travel 2.hours
    expect(account.reload).not_to be_payout_ready
    expect(account.active_payment_readiness_approval).to be_nil
    expect(account.latest_payment_readiness_approval).to eq(approval)
  end

  it "never revives old evidence after provider state changes and later reverts" do
    original_capabilities = account.capabilities.deep_dup
    submission = described_class.submit!(account: account, attributes: evidence, actor: submitter)
    described_class.approve!(submission: submission, actor: approver)
    original_revision = account.reload.readiness_revision
    expect(account).to be_payout_ready

    ConnectedAccounts::Manager.sync!(account: account, actor: submitter,
      attributes: { capabilities: original_capabilities.merge("provider_risk_review" => "required") })
    expect(account.reload.readiness_revision).to eq(original_revision + 1)
    expect(account).not_to be_payout_ready

    ConnectedAccounts::Manager.sync!(account: account, actor: submitter,
      attributes: { capabilities: original_capabilities })
    expect(account.reload.readiness_revision).to eq(original_revision + 2)
    expect(account).not_to be_payout_ready
    expect(account.requirements_due).to include("independent_readiness_approval")
  end

  it "rejects a pending snapshot after provider state changes" do
    submission = described_class.submit!(account: account, attributes: evidence, actor: submitter)
    ConnectedAccounts::Manager.sync!(account: account, actor: submitter,
      attributes: { capabilities: account.capabilities.merge("provider_risk_review" => "required") })

    expect do
      described_class.approve!(submission: submission, actor: approver)
    end.to raise_error(described_class::ReviewError, /Provider state changed/)
    expect(submission.reload.child_reviews).to be_empty
    expect(account.reload).not_to be_payout_ready
  end
end
