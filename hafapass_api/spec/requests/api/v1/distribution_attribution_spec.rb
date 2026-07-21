require "rails_helper"

RSpec.describe "Privacy-safe distribution attribution", type: :request do
  let(:event) { create(:event, :published) }
  let!(:ticket_type) { create(:ticket_type, event: event) }
  let(:link) { create(:distribution_link, event: event) }
  let(:anonymous_id) { "visitor_1234567890abcdef" }

  it "resolves a governed partner link without storing its raw visitor identifier" do
    get "/api/v1/distribution_links/#{link.code}", params: { anonymous_id: anonymous_id }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("attribution", "distribution_code")).to eq(link.code)
    funnel = MarketplaceFunnelEvent.last
    expect(funnel.visitor_hash).not_to include(anonymous_id)
    expect(funnel).to be_landing
  end


  it "drops personal-looking campaign fields from public telemetry" do
    post "/api/v1/marketplace_funnel_events", params: { event_id: event.id, stage: "event_view",
      anonymous_id: anonymous_id, source: "person@example.com", medium: "partner", campaign: "safe-campaign" }

    expect(response).to have_http_status(:created)
    expect(MarketplaceFunnelEvent.last).to have_attributes(source: nil, medium: "partner", campaign: "safe-campaign")
  end

  it "uses governed partner labels instead of client-supplied labels" do
    post "/api/v1/marketplace_funnel_events", params: { event_id: event.id, stage: "event_view",
      anonymous_id: anonymous_id, distribution_code: link.code, source: "forged", medium: "forged",
      campaign: "forged" }

    expect(response).to have_http_status(:created)
    expect(MarketplaceFunnelEvent.last).to have_attributes(source: link.distribution_partner.kind,
      medium: "partner", campaign: link.campaign)
  end

  it "carries acquisition through completed purchase exactly once" do
    result = Commerce::OrderCreator.call(
      event: event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: "buyer@example.com",
      buyer_name: "Buyer",
      payment_required: false,
      attribution: {
        distribution_code: link.code,
        anonymous_id: anonymous_id,
        source: "forged",
        medium: "forged",
        campaign: "forged"
      }
    )

    attribution = result.order.acquisition_attribution
    expect(attribution.distribution_link).to eq(link)
    expect(attribution).to have_attributes(source: link.distribution_partner.kind, medium: "partner",
      campaign: link.campaign)
    expect(attribution.visitor_hash).not_to eq(anonymous_id)
    expect(result.order.marketplace_funnel_events.purchase.count).to eq(1)

    Commerce::OrderLifecycle.complete!(result.order)
    expect(result.order.marketplace_funnel_events.purchase.count).to eq(1)
  end


  it "creates a fan referral and attributes its conversion without exposing the fan" do
    user = create(:user)
    post "/api/v1/me/event_referrals", params: { event_id: event.id }, headers: auth_headers(user)
    referral = user.event_referrals.find_by!(event: event)

    get "/api/v1/event_referrals/#{referral.code}", params: { anonymous_id: anonymous_id }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("attribution", "event_referral_code")).to eq(referral.code)

    result = Commerce::OrderCreator.call(event: event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }], buyer_email: "friend@example.com",
      buyer_name: "Friend", payment_required: false,
      attribution: { event_referral_code: referral.code, anonymous_id: anonymous_id })

    expect(result.order.acquisition_attribution.event_referral).to eq(referral)
    expect(result.order.acquisition_attribution.source).to eq("user_referral")
    expect(referral.acquisition_attributions.count).to eq(1)
  end

  it "does not misclassify box-office orders as online marketplace acquisitions" do
    result = Commerce::OrderCreator.call(event: event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }], buyer_email: "door@example.com",
      buyer_name: "Door Buyer", payment_required: false, source: "box_office", payment_method: "cash")

    expect(result.order.acquisition_attribution).to be_nil
    expect(result.order.marketplace_funnel_events.purchase).to be_empty
  end
end
