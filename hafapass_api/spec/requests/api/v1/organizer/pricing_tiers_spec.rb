require "rails_helper"

RSpec.describe "Api::V1::Organizer::PricingTiers", type: :request do
  let(:user) { create(:user, :organizer) }
  let!(:organizer_profile) { create(:organizer_profile, user: user) }
  let(:headers) { auth_headers(user) }
  let(:event) { create(:event, organizer_profile: organizer_profile) }
  let!(:ticket_type) { create(:ticket_type, event: event) }
  let(:base_path) { "/api/v1/organizer/events/#{event.id}/ticket_types/#{ticket_type.id}/pricing_tiers" }

  describe "GET /pricing_tiers" do
    it "returns pricing tiers for the ticket type" do
      create(:pricing_tier, ticket_type: ticket_type, name: "Early Bird", position: 0)
      create(:pricing_tier, ticket_type: ticket_type, name: "Regular", position: 1, price_cents: 3000, quantity_limit: 100)

      get base_path, headers: headers

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json.length).to eq(2)
      expect(json.first["name"]).to eq("Early Bird")
    end
  end

  describe "POST /pricing_tiers" do
    it "creates a quantity_based pricing tier" do
      params = {
        name: "Early Bird",
        price_cents: 2000,
        tier_type: "quantity_based",
        quantity_limit: 50,
        position: 0
      }

      post base_path, params: params.to_json, headers: headers.merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json["name"]).to eq("Early Bird")
      expect(json["price_cents"]).to eq(2000)
      expect(json["tier_type"]).to eq("quantity_based")
      expect(json["quantity_limit"]).to eq(50)
    end

    it "creates a time_based pricing tier" do
      params = {
        name: "Flash Sale",
        price_cents: 1500,
        tier_type: "time_based",
        starts_at: 1.day.ago.iso8601,
        ends_at: 1.week.from_now.iso8601,
        position: 0
      }

      post base_path, params: params.to_json, headers: headers.merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json["tier_type"]).to eq("time_based")
    end

    it "returns errors for invalid params" do
      params = { name: "", price_cents: -1, tier_type: "quantity_based", position: 0 }
      post base_path, params: params.to_json, headers: headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "PUT /pricing_tiers/:id" do
    let!(:tier) { create(:pricing_tier, ticket_type: ticket_type, name: "Early Bird") }

    it "updates a pricing tier" do
      put "#{base_path}/#{tier.id}", params: { name: "Super Early Bird" }.to_json,
          headers: headers.merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["name"]).to eq("Super Early Bird")
    end
  end

  describe "DELETE /pricing_tiers/:id" do
    let!(:tier) { create(:pricing_tier, ticket_type: ticket_type) }

    it "deletes a pricing tier" do
      delete "#{base_path}/#{tier.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(PricingTier.find_by(id: tier.id)).to be_nil
    end
  end

  describe "authorization" do
    it "returns 401 without authentication" do
      get base_path
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
