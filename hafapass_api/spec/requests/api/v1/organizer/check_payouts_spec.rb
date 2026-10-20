# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Check payout method", type: :request do
  let(:owner) { create(:user, :organizer) }
  let(:profile) { create(:organizer_profile, user: owner) }
  let(:organization) { profile.organization }
  let(:headers) { auth_headers(owner).merge("X-Organization-Id" => organization.id.to_s) }
  let(:details) do
    { payee_name: "Ambros Inc.", delivery_method: "mail", mailing_address: "PO Box 1, Hagåtña, GU 96910",
      memo: "Event proceeds" }
  end

  it "saves a check payee with a plain next step" do
    post "/api/v1/organizer/connected_accounts", params: { provider: "check", payout_details: details }, headers: headers

    expect(response).to have_http_status(:created)
    body = response.parsed_body
    expect(body).to include("provider" => "check", "status" => "onboarding", "payout_ready" => false)
    expect(body["payout_details"]).to include("payee_name" => "Ambros Inc.", "delivery_method" => "mail")
    expect(body["requirements_due"]).to include("payee_details_review")
    expect(body["next_action"]).to include("HåfaPass finance")
  end

  it "requires a payee and a mailing address for mailed checks" do
    post "/api/v1/organizer/connected_accounts",
      params: { provider: "check", payout_details: { payee_name: "", delivery_method: "mail" } }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("name to write on the check", "mailing address")

    post "/api/v1/organizer/connected_accounts",
      params: { provider: "check", payout_details: { payee_name: "Ambros", delivery_method: "pickup",
                                                     pickup_note: "Front desk" } }, headers: headers
    expect(response).to have_http_status(:created)
    expect(response.parsed_body["payout_details"]).not_to have_key("mailing_address")
  end

  it "invalidates an earlier readiness approval when the payee changes" do
    account = create(:connected_account, organization: organization, provider: "check",
      provider_account_id: nil, payout_details: details.stringify_keys)
    expect(account.reload).to be_payout_ready

    patch "/api/v1/organizer/connected_accounts/#{account.id}",
      params: { payout_details: details.merge(payee_name: "Someone Else") }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(account.reload.readiness_revision).to eq(2)
    expect(account).not_to be_payout_ready
    expect(AuditLog.where(action: "connected_account.payout_details_updated", auditable: account)).to exist
  end

  it "keeps legacy accounts' readiness digests unchanged" do
    account = create(:connected_account, organization: organization, provider: "manual", provider_account_id: nil)
    digest = account.provider_configuration_digest
    expect(account.reload.payout_details).to eq({})
    expect(account.provider_configuration_digest).to eq(digest)
    expect(account).to be_payout_ready
  end

  it "is limited to people who manage payouts" do
    manager = create(:user)
    create(:organization_membership, organization: organization, user: manager, role: :manager)
    post "/api/v1/organizer/connected_accounts", params: { provider: "check", payout_details: details },
      headers: auth_headers(manager).merge("X-Organization-Id" => organization.id.to_s)
    expect(response).to have_http_status(:forbidden)

    other = create(:connected_account, provider: "check", provider_account_id: nil)
    patch "/api/v1/organizer/connected_accounts/#{other.id}", params: { payout_details: details }, headers: headers
    expect(response).to have_http_status(:not_found)
  end
end

RSpec.describe "Recording a check payout", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:organization) { create(:organization) }
  let(:profile) { create(:organizer_profile, organization: organization) }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:settlement) { create(:settlement, organization: organization, event: event) }
  let(:account) do
    create(:connected_account, organization: organization, provider: "check", provider_account_id: nil,
      with_readiness_approval: false,
      payout_details: { "payee_name" => "Ambros Inc.", "delivery_method" => "pickup", "pickup_note" => "Front desk" })
  end
  let!(:payout) do
    create(:payout, organization: organization, event: event, settlement: settlement, connected_account: account,
      status: :processing, provider_payout_id: "manual_po_fixture", created_at: 1.hour.ago)
  end

  it "shows who the check is for and records the check number and date" do
    get "/api/v1/admin/payouts", headers: auth_headers(admin)
    listed = response.parsed_body.fetch("payouts").find { |item| item["id"] == payout.id }
    expect(listed).to include("provider" => "check")
    expect(listed["payee"]).to include("payee_name" => "Ambros Inc.", "delivery_method" => "pickup")

    check_date = 10.minutes.ago
    patch "/api/v1/admin/payouts/#{payout.id}", headers: auth_headers(admin), params: {
      status: "paid", provider_payout_id: "Check 1042",
      evidence: { reference: "Check 1042", confirmed_at: check_date.iso8601(6), reason: "Check written and picked up" }
    }
    expect(response).to have_http_status(:ok)
    expect(payout.reload).to have_attributes(status: "paid", provider_payout_id: "Check 1042")
    expect(payout.paid_at).to be_within(1.second).of(check_date)
  end
end
