require "rails_helper"

RSpec.describe "Card-present account administration", type: :request do
  let(:profile) { create(:organizer_profile) }
  let(:organization) { profile.organization }
  let(:owner_headers) { auth_headers(profile.user).merge("X-Organization-Id" => organization.id.to_s) }
  let(:admin) { create(:user, :admin) }
  let(:admin_headers) { auth_headers(admin) }

  it "requires a HafaPass administrator to record Guam merchant verification evidence" do
    post "/api/v1/admin/card_present_accounts", params: {
      organization_id: organization.id,
      merchant_id: "merchant-guam-1",
      device_id: "clover-device-1",
      pos_id: "hafapass-pos-1",
      status: "verified",
      guam_merchant_approved: true,
      verification_reference: "BOH approval case 1001"
    }, headers: owner_headers
    expect(response).to have_http_status(:forbidden)

    post "/api/v1/admin/card_present_accounts", params: {
      organization_id: organization.id,
      merchant_id: "merchant-guam-1",
      device_id: "clover-device-1",
      pos_id: "hafapass-pos-1",
      status: "verified",
      guam_merchant_approved: false,
      verification_reference: "BOH approval case 1001"
    }, headers: admin_headers
    expect(response).to have_http_status(:unprocessable_entity)

    post "/api/v1/admin/card_present_accounts", params: {
      organization_id: organization.id,
      merchant_id: "merchant-guam-1",
      device_id: "clover-device-1",
      pos_id: "hafapass-pos-1",
      status: "verified",
      guam_merchant_approved: true,
      verification_reference: "BOH approval case 1001"
    }, headers: admin_headers
    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("provider" => "boh_clover", "status" => "verified", "payment_ready" => true)
    expect(CardPresentAccount.last.verified_by_user).to eq(admin)
  end

  it "shows staff only the operational readiness state, not merchant or device identifiers" do
    create(:card_present_account, :verified, organization: organization)

    get "/api/v1/organizer/card_present_account", headers: owner_headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("provider" => "boh_clover", "payment_ready" => true)
    expect(response.parsed_body).not_to have_key("merchant_id")
    expect(response.parsed_body).not_to have_key("device_id")
  end
end
