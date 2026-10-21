require "rails_helper"

RSpec.describe "Marketing unsubscribe", type: :request do
  it "accepts a signed public link and scopes it to the organizer and address" do
    first = create(:organization)
    second = create(:organization)
    token = MarketingUnsubscribe.token(organization: first, email: "Buyer@Example.com")

    get "/api/v1/marketing/unsubscribe/#{token}"
    expect(response).to have_http_status(:ok)
    expect(MarketingUnsubscribe.exists?(organization: first, email: "buyer@example.com")).to be(true)
    expect(MarketingUnsubscribe.exists?(organization: second, email: "buyer@example.com")).to be(false)

    delete "/api/v1/marketing/unsubscribe/#{token}"
    expect(response).to have_http_status(:ok)
    expect(MarketingUnsubscribe.exists?(organization: first, email: "buyer@example.com")).to be(false)

    post "/api/v1/marketing/unsubscribe/#{token}x"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(MarketingUnsubscribe.count).to eq(0)
  end
end
