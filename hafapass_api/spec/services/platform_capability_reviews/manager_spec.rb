require "rails_helper"

RSpec.describe PlatformCapabilityReviews::Manager do
  let(:submitter) { create(:user, :admin) }
  let(:approver) { create(:user, :admin) }
  let(:attributes) do
    {
      evidence_reference: "policy-approval-register-2026-07",
      evidence_digest: "b" * 64,
      controls: PlatformCapabilities.required_controls("policy_register").index_with { true },
      effective_at: 1.minute.ago,
      expires_at: 90.days.from_now
    }
  end

  # Generic examples model counsel-approved policy text; the draft path is below.
  before { allow(PolicyRegistry).to receive(:draft?).and_return(false) }

  it "approves draft policies for launch only with the explicit acknowledgment, and records it" do
    allow(PolicyRegistry).to receive(:draft?).and_call_original
    expect(PolicyRegistry).to be_draft
    submission = described_class.submit!(capability: "policy_register", attributes: attributes, actor: submitter)

    expect do
      described_class.approve!(submission: submission, actor: approver)
    end.to raise_error(described_class::ReviewError, /approving draft policies for launch before legal review/)

    approval = described_class.approve!(submission: submission, actor: approver, draft_policies_acknowledged: true)
    expect(approval).to be_active
    expect(approval.reason).to eq(PolicyRegistry::DRAFT_ACKNOWLEDGMENT)
    log = AuditLog.find_by!(auditable: approval, action: "platform_capability.approved")
    expect(log.metadata).to include("draft_policies_acknowledged" => true, "policy_version" => PolicyRegistry.version)
    expect(log.after_data).to include("reason" => PolicyRegistry::DRAFT_ACKNOWLEDGMENT)
  end

  it "blocks approval only for technical problems in the policy text" do
    allow(PolicyRegistry).to receive(:approval_blockers).and_return(["Unfilled template placeholders remain in: Buyer Terms"])
    submission = described_class.submit!(capability: "policy_register", attributes: attributes, actor: submitter)

    expect do
      described_class.approve!(submission: submission, actor: approver, draft_policies_acknowledged: true)
    end.to raise_error(described_class::ReviewError, /technical problems: Unfilled template placeholders/)
    expect(PlatformCapabilities.enabled?("policy_register")).to be(false)
  end

  it "lets the submitting administrator approve an exact evidence snapshot" do
    submission = described_class.submit!(capability: "policy_register", attributes: attributes, actor: submitter)

    approval = described_class.approve!(submission: submission, actor: submitter)
    expect(approval.actor_user).to eq(submitter)

    expect(approval).to be_active
    expect(PlatformCapabilities.enabled?("policy_register")).to be(true)
    expect(AuditLog.where(auditable: approval, action: "platform_capability.approved")).to exist
  end

  it "invalidates approval when the approved policy content digest changes" do
    submission = described_class.submit!(capability: "policy_register", attributes: attributes, actor: submitter)
    approval = described_class.approve!(submission: submission, actor: approver)
    allow(PolicyRegistry).to receive(:registry_digest).and_return("c" * 64)

    expect(approval.reload).not_to be_active
    expect(PlatformCapabilities.enabled?("policy_register")).to be(false)
  end

  it "revokes approval with an append-only decision" do
    submission = described_class.submit!(capability: "policy_register", attributes: attributes, actor: submitter)
    approval = described_class.approve!(submission: submission, actor: approver)

    revocation = described_class.revoke!(approval: approval, actor: submitter, reason: "Counsel withdrew approval")

    expect(revocation).to be_decision_revocation
    expect(approval.reload).to be_revoked
    expect(PlatformCapabilities.enabled?("policy_register")).to be(false)
  end

  it "rejects submission when provider configuration is incomplete" do
    expect do
      described_class.submit!(capability: "stripe_live", attributes: attributes, actor: submitter)
    end.to raise_error(described_class::ReviewError, /configuration is incomplete/)
  end

  it "accepts only an HTTPS Clover-owned REST Pay endpoint as configured" do
    original_base = ENV["CLOVER_REST_PAY_BASE_URL"]
    original_revision = ENV["PROVIDER_CONFIGURATION_REVISION"]
    ENV["PROVIDER_CONFIGURATION_REVISION"] = "clover-pilot-1"
    ENV["CLOVER_REST_PAY_BASE_URL"] = "https://merchant.example/connect"
    expect(PlatformCapabilities.configured?("clover_card_present")).to be(false)

    ENV["CLOVER_REST_PAY_BASE_URL"] = "https://api.clover.com/connect"
    expect(PlatformCapabilities.configured?("clover_card_present")).to be(true)
  ensure
    original_base.nil? ? ENV.delete("CLOVER_REST_PAY_BASE_URL") : ENV["CLOVER_REST_PAY_BASE_URL"] = original_base
    original_revision.nil? ? ENV.delete("PROVIDER_CONFIGURATION_REVISION") : ENV["PROVIDER_CONFIGURATION_REVISION"] = original_revision
  end

  describe ".quick_approve!" do
    it "needs the draft-policy acknowledgment and records it the same way as the full review" do
      allow(PolicyRegistry).to receive(:draft?).and_return(true)

      expect do
        described_class.quick_approve!(capability: "policy_register", actor: submitter)
      end.to raise_error(described_class::ReviewError, /approving draft policies for launch before legal review/)
      expect(PlatformCapabilityReview.where(capability: "policy_register")).to be_empty

      approval = described_class.quick_approve!(capability: "policy_register", actor: submitter,
        draft_policies_acknowledged: true)
      expect(approval).to be_active
      expect(approval.reason).to eq(PolicyRegistry::DRAFT_ACKNOWLEDGMENT)
      log = AuditLog.find_by!(auditable: approval, action: "platform_capability.approved")
      expect(log.metadata).to include("draft_policies_acknowledged" => true)
    end

    it "refuses a second approval while one is active" do
      described_class.quick_approve!(capability: "policy_register", actor: submitter)

      expect { described_class.quick_approve!(capability: "policy_register", actor: approver) }
        .to raise_error(described_class::ReviewError, /Already approved/)
      expect(PlatformCapabilityReview.where(capability: "policy_register").approvals.count).to eq(1)
    end
  end
end
