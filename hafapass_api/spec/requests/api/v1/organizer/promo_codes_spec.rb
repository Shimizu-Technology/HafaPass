require "rails_helper"

RSpec.describe "Organizer promo code discount bounds", type: :request do
  let(:profile) { create(:organizer_profile) }
  let(:event) { create(:event, organizer_profile: profile) }
  let(:path) { "/api/v1/organizer/events/#{event.id}/promo_codes" }
  let(:headers) { auth_headers(profile.user).merge("X-Organization-Id" => profile.organization.id.to_s) }

  it "persists the largest fixed discount and rejects an overflowing create without writing" do
    post path, params: { code: "MAX", discount_type: "fixed", discount_value: 2_147_483_647 }, headers: headers
    expect(response).to have_http_status(:created)
    expect(event.promo_codes.find_by!(code: "MAX").discount_value).to eq(2_147_483_647)

    expect {
      post path, params: { code: "OVER", discount_type: "fixed", discount_value: 2_147_483_648 }, headers: headers
    }.not_to change(PromoCode, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include("Discount value must be less than or equal to 2147483647")
  end

  it "rejects an overflowing edit and retains the saved discount" do
    code = create(:promo_code, event: event, discount_type: "fixed", discount_value: 500)
    patch "#{path}/#{code.id}", params: { discount_value: 2_147_483_648 }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(code.reload.discount_value).to eq(500)
  end

  it "accepts 100 percent and rejects percentages above 100 or fractional points" do
    post path, params: { code: "ALL", discount_type: "percentage", discount_value: 100 }, headers: headers
    expect(response).to have_http_status(:created)
    [101, "5.5"].each do |value|
      post path, params: { code: "INVALID", discount_type: "percentage", discount_value: value }, headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
