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

    it "uses the event timezone, accepts a shared cutoff, and rejects an overlapping edit" do
      event.update!(timezone: "Pacific/Guam")
      attributes = { name: "Early Bird", price_cents: 1000, tier_type: "time_based", ends_at: "2027-05-01T23:59:01" }
      post base_path, params: attributes, headers: headers, as: :json

      expect(response).to have_http_status(:created)
      cutoff = response.parsed_body.fetch("ends_at")
      expect(Time.iso8601(cutoff)).to eq(Time.utc(2027, 5, 1, 13, 59, 1))

      post base_path, params: attributes.except(:ends_at).merge(name: "Regular", starts_at: "2027-05-01T23:59:01"),
        headers: headers, as: :json
      expect(response).to have_http_status(:created)
      expect(response.parsed_body.fetch("starts_at")).to eq(cutoff)

      put "#{base_path}/#{response.parsed_body.fetch('id')}", params: { starts_at: "2027-05-01T23:59:00" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch("errors")).to include("This price window overlaps another price window")
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

    it "clears starts_at and ends_at when changing a time-based tier to quantity-based" do
      window = create(:pricing_tier, :time_based, ticket_type: ticket_type, name: "Early Bird",
        starts_at: 1.day.from_now, ends_at: 3.days.from_now)

      put "#{base_path}/#{window.id}", params: { tier_type: "quantity_based", quantity_limit: 25 },
        headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(window.reload.starts_at).to be_nil
      expect(window.ends_at).to be_nil
    end
  end

  describe "PUT /ticket_types/:id sales window invariant" do
    let(:ticket_type_path) { "/api/v1/organizer/events/#{event.id}/ticket_types/#{ticket_type.id}" }

    it "rejects narrowing sales_start_at or sales_end_at past existing time-based tiers and allows exact boundaries" do
      event.update!(timezone: "Pacific/Guam", starts_at: Time.utc(2027, 6, 1, 8, 0), ends_at: Time.utc(2027, 6, 2, 8, 0))
      create(:pricing_tier, :time_based, ticket_type: ticket_type, name: "Early Bird",
        starts_at: Time.utc(2027, 5, 1, 0, 0), ends_at: Time.utc(2027, 5, 10, 0, 0))
      create(:pricing_tier, :time_based, ticket_type: ticket_type, name: "Regular",
        starts_at: Time.utc(2027, 5, 10, 0, 0), ends_at: Time.utc(2027, 5, 20, 0, 0))

      put ticket_type_path, params: { sales_end_at: "2027-05-15T10:00" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch("errors").join(" ")).to include("Regular")

      put ticket_type_path, params: { sales_start_at: "2027-05-02T10:00" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch("errors").join(" ")).to include("Early Bird")

      put ticket_type_path, params: {
        sales_start_at: "2027-05-01T10:00",
        sales_end_at: "2027-05-20T10:00"
      }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
    end

    it "rejects sales-window edits that leave one-sided tiers with no sales overlap" do
      event.update!(timezone: "Pacific/Guam", starts_at: Time.utc(2027, 6, 1, 8, 0), ends_at: Time.utc(2027, 6, 2, 8, 0))
      create(:pricing_tier, :time_based, ticket_type: ticket_type, name: "Early Open",
        starts_at: nil, ends_at: Time.utc(2027, 5, 5, 0, 0))
      create(:pricing_tier, :time_based, ticket_type: ticket_type, name: "Late Open",
        starts_at: Time.utc(2027, 5, 15, 0, 0), ends_at: nil)

      put ticket_type_path, params: { sales_start_at: "2027-05-05T10:00" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch("errors").join(" ")).to include("Early Open")

      put ticket_type_path, params: { sales_end_at: "2027-05-15T10:00" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch("errors").join(" ")).to include("Late Open")

      put ticket_type_path, params: {
        sales_start_at: "2027-05-04T10:00",
        sales_end_at: "2027-05-16T10:00"
      }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
    end
  end

  describe "PATCH /pricing_tiers/:id/move" do
    it "moves a quantity cap ahead of the previous cap even when positions are tied" do
      first = create(:pricing_tier, ticket_type: ticket_type, name: "First", position: 0)
      window = create(:pricing_tier, :time_based, ticket_type: ticket_type, position: 0)
      second = create(:pricing_tier, ticket_type: ticket_type, name: "Second", position: 0)

      patch "#{base_path}/#{second.id}/move", params: { direction: "up" }, headers: headers, as: :json
      expect(response).to have_http_status(:no_content)
      expect(ticket_type.pricing_tiers.pluck(:id)).to eq([second.id, window.id, first.id])
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
