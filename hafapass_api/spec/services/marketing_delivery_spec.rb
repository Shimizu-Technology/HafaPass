require "rails_helper"

RSpec.describe "Marketing delivery" do
  let(:event) { create(:event, :published) }
  let(:campaign) { create(:communication_campaign, event: event) }

  before { SiteSetting.instance.update!(business_mailing_address: "123 Marine Drive, Hagåtña, GU 96910") }

  def attendee(email:, opted_in:)
    order = create(:order, event: event, buyer_email: email, marketing_opt_in: opted_in)
    type = create(:ticket_type, event: event)
    item = create(:order_item, order: order, ticket_type: type)
    create(:ticket, order: order, event: event, ticket_type: type, order_item: item)
    order
  end

  it "queues only opted-in buyers and includes sender, address and one-click headers" do
    attendee(email: "yes@example.com", opted_in: true)
    attendee(email: "no@example.com", opted_in: false)
    sender = CommunicationCampaigns::Sender.new(campaign)
    expect(sender.audience_counts).to include(attendees: 2, opted_in: 1, excluded: 1, eligible: 1)
    sender.call
    delivery = campaign.message_deliveries.sole
    expect(delivery).to be_promotional
    expect(delivery).not_to be_transactional
    payload = EmailService.prepare_delivery_payload(delivery)
    expect(payload.fetch("html")).to include("123 Marine Drive", "Unsubscribe", event.organization.name)
    expect(payload.dig("headers", "List-Unsubscribe")).to include("/api/v1/marketing/unsubscribe/")
    expect(payload.dig("headers", "List-Unsubscribe-Post")).to eq("List-Unsubscribe=One-Click")
  end

  it "blocks missing mailing address and respects unsubscribe and provider complaints" do
    attendee(email: "yes@example.com", opted_in: true)
    SiteSetting.instance.update!(business_mailing_address: nil)
    expect { CommunicationCampaigns::Sender.call(campaign) }.to raise_error(/Business mailing address/)
    SiteSetting.instance.update!(business_mailing_address: "123 Marine Drive, Hagåtña, GU 96910")
    MarketingUnsubscribe.create!(organization: event.organization, email: "yes@example.com", unsubscribed_at: Time.current)
    expect(CommunicationCampaigns::Sender.new(campaign).audience_counts[:eligible]).to eq(0)
    MarketingUnsubscribe.delete_all
    create(:message_delivery, event: event, recipient: "yes@example.com", status: :complained)
    expect(CommunicationCampaigns::Sender.new(campaign).audience_counts[:eligible]).to eq(0)
  end

  it "stops an already queued campaign when the buyer unsubscribes" do
    attendee(email: "yes@example.com", opted_in: true)
    CommunicationCampaigns::Sender.call(campaign)
    delivery = campaign.message_deliveries.sole
    MarketingUnsubscribe.create!(organization: event.organization, email: delivery.recipient,
      unsubscribed_at: Time.current)
    MessageDeliveryJob.perform_now(delivery.id)
    expect(delivery.reload).to be_suppressed
    expect(delivery.provider_id).to be_nil
  end
end
