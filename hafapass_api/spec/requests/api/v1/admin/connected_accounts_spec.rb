# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin connected accounts and payout controls", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:organization) { create(:organization) }
  let(:account) do
    ConnectedAccounts::Manager.start!(organization: organization, provider: "paypal", actor: admin)
  end
  let(:headers) { auth_headers(admin) }

  it "records verified readiness evidence and writes an audit log" do
    patch "/api/v1/admin/connected_accounts/#{account.id}", params: {
      provider_account_id: "paypal-merchant-verified",
      charges_enabled: true,
      payouts_enabled: true,
      details_submitted: true,
      requirements_due: []
    }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("status" => "ready", "payout_ready" => true)
    expect(account.reload).to be_payout_ready
    expect(AuditLog.where(auditable: account, action: "connected_account.synced")).to exist
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
