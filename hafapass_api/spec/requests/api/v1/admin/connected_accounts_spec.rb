# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin connected accounts and payout controls", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:organization) { create(:organization) }
  let(:account) do
    ConnectedAccounts::Manager.start!(organization: organization, provider: "paypal", actor: admin)
  end
  let(:headers) { auth_headers(admin) }

  it "keeps readiness blocked until an admin approves complete evidence, even the submitter" do
    patch "/api/v1/admin/connected_accounts/#{account.id}", params: {
      provider_account_id: "paypal-merchant-verified",
      charges_enabled: true,
      payouts_enabled: true,
      details_submitted: true,
      requirements_due: []
    }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("status" => "requirements_due", "payout_ready" => false)
    expect(response.parsed_body.fetch("requirements_due")).to include("independent_readiness_approval")
    expect(account.reload).not_to be_payout_ready
    expect(AuditLog.where(auditable: account, action: "connected_account.synced")).to exist

    controls = PaymentReadinessReview::CONTROL_KEYS.index_with(true)
    post "/api/v1/admin/connected_accounts/#{account.id}/payment_readiness_reviews", params: {
      evidence_reference: "restricted/gate-b/paypal-account-1",
      evidence_digest: Digest::SHA256.hexdigest("redacted-provider-evidence"),
      provider_approval_reference: "paypal-partner-approval-1",
      merchant_of_record: "organizer",
      fee_tax_schedule_reference: "approved/fee-tax/2026-07",
      liability_schedule_reference: "approved/liability/2026-07",
      controls: controls,
      effective_at: 1.hour.ago.iso8601,
      expires_at: 6.months.from_now.iso8601
    }, headers: headers

    expect(response).to have_http_status(:created), response.body
    expect(response.parsed_body.fetch("provider_state_digest")).to eq(account.reload.readiness_state_digest)
    submission_id = response.parsed_body.fetch("id")

    # One administrator may submit and approve; the audit trail keeps both acts.
    patch "/api/v1/admin/payment_readiness_reviews/#{submission_id}/approve", headers: headers

    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("decision" => "approval", "connected_account_payout_ready" => true)
    expect(account.reload).to be_payout_ready
    expect(AuditLog.where(action: %w[payment_readiness.submitted payment_readiness.approved]).pluck(:actor_user_id).uniq)
      .to eq([admin.id])
  end

  it "rejects cross-organization adjustment references" do
    other_event = create(:event)

    post "/api/v1/admin/balance_adjustments", params: {
      organization_id: organization.id,
      order_id: create(:order, event: other_event).id,
      kind: "manual_debit",
      amount_cents: -500,
      reason: "Invalid cross-organization debit"
    }, headers: headers

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("errors")).to include(/same organization/)
  end
end
