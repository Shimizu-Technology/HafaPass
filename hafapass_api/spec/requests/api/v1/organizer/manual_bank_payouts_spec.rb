# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Manual bank transfer payout details", type: :request do
  let(:profile) { create(:organizer_profile) }
  let(:organization) { profile.organization }
  let(:admin) { create(:user, :admin) }
  let(:headers) { auth_headers(profile.user).merge("X-Organization-Id" => organization.id.to_s) }
  let(:details) { { bank_name: "Bank of Guam", account_holder_name: "Island Events LLC", account_number: "123456789012" } }

  it "encrypts account numbers, allows safe re-editing, and invalidates approval even when the last four digits stay the same" do
    create(:organizer_tax_information, organization: organization)
    post "/api/v1/organizer/connected_accounts", headers: headers, params: { provider: "manual", payout_details: details }
    expect(response).to have_http_status(:created), response.body
    expect(response.parsed_body["payout_details"]).to eq("bank_name" => "Bank of Guam", "account_holder_name" => "Island Events LLC", "masked_account" => "•••• 9012")
    account = organization.connected_accounts.find_by!(provider: "manual")
    expect(account.bank_account_number).to eq("123456789012")
    ciphertext = ConnectedAccount.connection.select_value("SELECT bank_account_number FROM connected_accounts WHERE id = #{account.id.to_i}")
    expect(ciphertext).not_to include("123456789012")
    PayoutMethodReview.approve!(account: account, actor: admin, controls: PaymentReadinessReview::MANUAL_CONTROL_KEYS.index_with(true),
      expected_digest: PayoutMethodReview.digest(account))
    expect(account.reload).to be_payout_ready
    original_digest = account.readiness_state_digest
    patch "/api/v1/organizer/connected_accounts/#{account.id}", headers: headers,
      params: { payout_details: details.except(:account_number) }
    expect(response).to have_http_status(:ok)
    expect(account.reload).to be_payout_ready
    expect(account.bank_account_number).to eq("123456789012")
    patch "/api/v1/organizer/connected_accounts/#{account.id}", headers: headers,
      params: { payout_details: details.merge(account_number: "987654329012") }
    expect(response).to have_http_status(:ok)
    expect(account.reload.readiness_state_digest).not_to eq(original_digest)
    expect(account).not_to be_payout_ready
    get "/api/v1/admin/organizations/#{organization.id}", headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("123456789012", "987654329012", "012345678", "bank_account_number")
    expect(response.parsed_body["payout_accounts"].first.dig("payout_review", "can_approve")).to be(true)
    get "/api/v1/admin/dashboard", headers: auth_headers(admin)
    expect(response.body).not_to include("123456789012", "987654329012", "012345678")
    get "/api/v1/organizer/connected_accounts", headers: headers
    expect(response.body).not_to include("123456789012", "987654329012", "012345678")
    expect(account.payment_readiness_reviews.to_json).not_to include("123456789012", "987654329012", "012345678")
    expect(AuditLog.where(organization: organization).to_json).not_to include("123456789012", "987654329012", "012345678")
  end

  it "reloads stale provider syncs instead of restoring an invalidated bank approval" do
    account = ConnectedAccounts::Manager.start!(organization: organization, provider: "manual", actor: profile.user, payout_details: details)
    create(:organizer_tax_information, organization: organization)
    stale_account = ConnectedAccount.find(account.id)
    PayoutMethodReview.approve!(account: account, actor: admin, controls: PaymentReadinessReview::MANUAL_CONTROL_KEYS.index_with(true),
      expected_digest: PayoutMethodReview.digest(account))
    patch "/api/v1/organizer/connected_accounts/#{account.id}", headers: headers,
      params: { payout_details: details.merge(account_number: "987654329012") }
    revision = account.reload.readiness_revision
    ConnectedAccounts::Manager.sync!(account: stale_account, actor: admin,
      attributes: { charges_enabled: true, payouts_enabled: true, details_submitted: true, requirements_due: [] })
    expect(account.reload.readiness_revision).to eq(revision)
    expect(account.bank_account_number).to eq("987654329012")
    expect(account).not_to be_payout_ready
  end

  %i[pending processing held].each do |status|
    it "preserves bank details during a #{status} bank payout" do
      account = ConnectedAccounts::Manager.start!(organization: organization, provider: "manual", actor: profile.user, payout_details: details)
      event = create(:event, organization: organization, organizer_profile: profile)
      create(:payout, organization: organization, event: event, connected_account: account, status: status)
      patch "/api/v1/organizer/connected_accounts/#{account.id}", headers: headers,
        params: { payout_details: details.merge(account_number: "987654329012") }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("bank payout is in progress")
      expect(account.reload.bank_account_number).to eq("123456789012")
    end
  end

  it "never reveals the complete number of a short bank account" do
    post "/api/v1/organizer/connected_accounts", headers: headers,
      params: { provider: "manual", payout_details: details.merge(account_number: "1234") }
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("payout_details", "masked_account")).to eq("••••")
    expect(response.body).not_to include("1234")
    account = organization.connected_accounts.find_by!(provider: "manual")
    create(:organizer_tax_information, organization: organization)
    post "/api/v1/admin/connected_accounts/#{account.id}/approve_payout_method", headers: auth_headers(admin),
      params: { controls: PaymentReadinessReview::MANUAL_CONTROL_KEYS.index_with(true),
        expected_digest: PayoutMethodReview.digest(account), note: "Account 1234" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(account.payment_readiness_reviews).to be_empty
  end

  it "reports incomplete banking details and refuses approval without recording provider status" do
    create(:organizer_tax_information, organization: organization)
    post "/api/v1/organizer/connected_accounts", headers: headers, params: { provider: "manual" }
    expect(response).to have_http_status(:created)
    expect(response.parsed_body["payout_review"]).to include("can_approve" => false, "missing" => ["Payout details incomplete"])
    account = organization.connected_accounts.find_by!(provider: "manual")
    expect {
      PayoutMethodReview.approve!(account: account, actor: admin, controls: PaymentReadinessReview::MANUAL_CONTROL_KEYS.index_with(true),
        expected_digest: PayoutMethodReview.digest(account))
    }.to raise_error(PayoutMethodReview::ReviewError, "Payout details incomplete")
    expect(account.reload.charges_enabled).to be(false)
  end
end
