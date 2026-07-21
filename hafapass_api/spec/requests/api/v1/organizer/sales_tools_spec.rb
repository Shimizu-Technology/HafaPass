require "rails_helper"

RSpec.describe "Api::V1::Organizer sales tools", type: :request do
  let(:profile) { create(:organizer_profile) }
  let(:user) { profile.user }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:headers) { auth_headers(user) }
  let(:base) { "/api/v1/organizer/events/#{event.id}" }

  it "configures catalog items, registration, waivers, and promoters" do
    post "#{base}/catalog_items", params: { name: "Shirt", kind: "merchandise", price_cents: 2500,
      inventory_quantity: 20 }, headers: headers
    expect(response).to have_http_status(:created)

    post "#{base}/registration_questions", params: { prompt: "Shirt size", kind: "selection", required: true,
      options: %w[S M L] }, headers: headers
    expect(response).to have_http_status(:created)

    post "#{base}/event_waivers", params: { title: "Participation waiver", version: "1", body: "Terms" }, headers: headers
    expect(response).to have_http_status(:created)

    post "#{base}/promoters", params: { name: "Island Team", code: "ISLAND", commission_bps: 750 }, headers: headers
    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("net_commission_cents" => 0)
  end

  it "exports CRM records and queues a segmented campaign" do
    type = create(:ticket_type, event: event)
    order = create(:order, event: event)
    item = create(:order_item, order: order, ticket_type: type)
    create(:ticket, order: order, event: event, ticket_type: type, order_item: item, holder_email: "guest@example.com")

    get "#{base}/crm/export", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/csv")
    expect(response.body).to include("guest@example.com")

    post "#{base}/communication_campaigns", params: { name: "Reminder", subject: "Tonight", body: "See you soon",
      segment: { type: "all_attendees" } }, headers: headers
    campaign = CommunicationCampaign.find(response.parsed_body.fetch("id"))
    post "#{base}/communication_campaigns/#{campaign.id}/send_now", headers: headers

    expect(response).to have_http_status(:accepted)
    expect(campaign.reload.recipient_count).to eq(1)
    expect(campaign.message_deliveries.count).to eq(1)
  end

  it "does not accumulate scheduled jobs for content-only campaign edits" do
    scheduled_at = 2.days.from_now

    expect {
      post "#{base}/communication_campaigns", params: { name: "Reminder", subject: "Tonight", body: "See you soon",
        scheduled_at: scheduled_at.iso8601, segment: { type: "all_attendees" } }, headers: headers
    }.to have_enqueued_job(CommunicationCampaignJob).once

    campaign = CommunicationCampaign.find(response.parsed_body.fetch("id"))
    expect {
      patch "#{base}/communication_campaigns/#{campaign.id}", params: { subject: "Updated reminder" }, headers: headers
    }.not_to have_enqueued_job(CommunicationCampaignJob)

    expect(response).to have_http_status(:ok)
    expect(campaign.reload).to be_scheduled
    expect(campaign.subject).to eq("Updated reminder")
  end

  it "isolates another organizer's event" do
    other = create(:organizer_profile)
    get "/api/v1/organizer/events/#{create(:event, organizer_profile: other).id}/catalog_items", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "records physical item fulfillment separately from the immutable order ledger" do
    type = create(:ticket_type, event: event)
    catalog = create(:catalog_item, event: event, kind: :merchandise)
    order = Commerce::OrderCreator.call(event: event,
      line_items: [{ ticket_type_id: type.id, quantity: 1 }],
      catalog_items: [{ catalog_item_id: catalog.id, quantity: 1 }],
      buyer_email: "buyer@example.com", buyer_name: "Buyer", payment_required: false).order
    item = order.order_items.item_merchandise.first

    post "#{base}/catalog_fulfillments/#{item.id}", headers: headers

    expect(response).to have_http_status(:ok)
    expect(item.catalog_fulfillment.reload).to be_fulfilled
    expect(item.reload.organizer_proceeds_cents).to eq(catalog.price_cents)
  end
end
