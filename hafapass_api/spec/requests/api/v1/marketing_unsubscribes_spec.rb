require "rails_helper"

RSpec.describe "Marketing unsubscribe", type: :request do
  it "accepts a signed public link and scopes it to the organizer and address" do
    first = create(:organization)
    second = create(:organization)
    token = MarketingUnsubscribe.token(organization: first, email: "Buyer@Example.com")

    get "/api/v1/marketing/unsubscribe/#{token}"
    expect(response).to have_http_status(:ok)
    expect(MarketingUnsubscribe.exists?(organization: first, email: "buyer@example.com")).to be(false)
    expect(MarketingUnsubscribe.exists?(organization: second, email: "buyer@example.com")).to be(false)

    post "/api/v1/marketing/unsubscribe/#{token}", headers: { "List-Unsubscribe" => "One-Click" }
    expect(response).to have_http_status(:ok)
    expect(MarketingUnsubscribe.exists?(organization: first, email: "buyer@example.com")).to be(true)

    get "/api/v1/marketing/unsubscribe/#{token}"
    expect(response.parsed_body).to include("unsubscribed" => true)
    delete "/api/v1/marketing/unsubscribe/#{token}"
    expect(response).to have_http_status(:not_found)
    expect(MarketingUnsubscribe.exists?(organization: first, email: "buyer@example.com")).to be(true)

    post "/api/v1/marketing/unsubscribe/#{token}x"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(MarketingUnsubscribe.count).to eq(1)
  end

  it "allows a fresh checkout opt-in only after the order completes" do
    event = create(:event)
    token = MarketingUnsubscribe.token(organization: event.organization, email: "buyer@example.com")
    post "/api/v1/marketing/unsubscribe/#{token}"
    order = create(:order, event: event, buyer_email: "buyer@example.com", marketing_opt_in: true, status: :pending)
    expect(MarketingUnsubscribe.where(organization: event.organization)).to exist

    order.update!(status: :completed)
    expect(MarketingUnsubscribe.where(organization: event.organization)).not_to exist
    post "/api/v1/marketing/unsubscribe/#{token}"
    expect(MarketingUnsubscribe.where(organization: event.organization)).to exist
  end
end
