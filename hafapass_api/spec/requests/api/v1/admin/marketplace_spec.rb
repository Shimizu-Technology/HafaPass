require "rails_helper"

RSpec.describe "Admin marketplace governance", type: :request do
  let(:admin) { create(:user, role: :admin) }
  let(:headers) { auth_headers(admin) }
  let(:event) { create(:event, :published) }
  let!(:ticket_type) { create(:ticket_type, event: event) }

  it "governs collections, venues, partners, links, and supply health" do
    post "/api/v1/admin/venues", params: { name: "Guam Museum", address: "193 Chalan Santo Papa",
      village: "Hagåtña", verified: true }, headers: headers
    expect(response).to have_http_status(:created)

    post "/api/v1/admin/marketplace_collections", params: { title: "Tonight on Guam", status: "published",
      event_ids: [event.id] }, headers: headers
    expect(response).to have_http_status(:created)

    post "/api/v1/admin/distribution_partners", params: { name: "Tumon Concierge", kind: "concierge" }, headers: headers
    partner_id = response.parsed_body.fetch("id")
    post "/api/v1/admin/distribution_links", params: { distribution_partner_id: partner_id, event_id: event.id,
      campaign: "front-desk" }, headers: headers
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("url")).to include("/go/")

    get "/api/v1/admin/marketplace", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("supply", "purchasable_upcoming")).to eq(1)
    expect(response.parsed_body.dig("supply", "categories_without_inventory")).not_to include(event.category)
  end

  it "rejects non-admin governance access" do
    get "/api/v1/admin/marketplace", headers: auth_headers(create(:user))
    expect(response).to have_http_status(:forbidden)
  end
end
