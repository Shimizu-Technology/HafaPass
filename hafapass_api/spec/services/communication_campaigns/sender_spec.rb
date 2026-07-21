require "rails_helper"

RSpec.describe CommunicationCampaigns::Sender do
  it "deduplicates recipients and records durable deliveries" do
    event = create(:event, :published)
    type = create(:ticket_type, event: event)
    order = create(:order, event: event, buyer_email: "buyer@example.com")
    item = create(:order_item, order: order, ticket_type: type, quantity: 2, subtotal_cents: 5000)
    create_list(:ticket, 2, order: order, event: event, ticket_type: type, order_item: item,
      holder_email: "Buyer@Example.com")
    campaign = create(:communication_campaign, event: event)

    expect { described_class.call(campaign) }.to change(MessageDelivery, :count).by(1)
    expect(campaign.reload).to be_sent
    expect(campaign.recipient_count).to eq(1)
    expect(campaign.message_deliveries.first.metadata).to include("subject" => campaign.subject, "body" => campaign.body)
  end
end
