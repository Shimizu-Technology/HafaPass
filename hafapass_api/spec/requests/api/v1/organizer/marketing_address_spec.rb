require "rails_helper"

RSpec.describe "Organizer marketing postal address", type: :request do
  let(:profile) { create(:organizer_profile) }
  let(:organization) { profile.organization }
  let(:path) { "/api/v1/organizer/organization" }
  let(:headers) { auth_headers(profile.user).merge("X-Organization-Id" => organization.id.to_s) }

  it "requires owner certification and a plausible physical postal address" do
    patch path, params: { organization: { marketing_mailing_address: "123 Marine Drive, Hagåtña, GU 96910" } },
      headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("marketing_address_ready")).to be(false)

    patch path, params: { organization: { marketing_mailing_address: "https://example.com", certified: true } },
      headers: headers
    expect(response).to have_http_status(:unprocessable_entity)

    patch path, params: { organization: { marketing_mailing_address: "123 Marine Drive, Hagåtña, GU 96910",
      certified: true } }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("marketing_address_ready" => true,
      "marketing_mailing_address" => "123 Marine Drive, Hagåtña, GU 96910")
  end

  it "keeps a marketer from changing the owner-certified sender address" do
    marketer = create(:user)
    create(:organization_membership, organization: organization, user: marketer, role: :marketer)
    patch path, params: { organization: { marketing_mailing_address: "9 Beach Road, Tamuning, GU 96913",
      certified: true } }, headers: auth_headers(marketer).merge("X-Organization-Id" => organization.id.to_s)

    expect(response).to have_http_status(:forbidden)
    expect(organization.reload.marketing_mailing_address).to be_nil
  end
end
