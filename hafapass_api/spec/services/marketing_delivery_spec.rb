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
    one_click_path = URI(payload.dig("headers", "List-Unsubscribe").delete_prefix("<").delete_suffix(">")).path
    expect(Rails.application.routes.recognize_path(one_click_path, method: :post))
      .to include(controller: "api/v1/marketing_unsubscribes", action: "create")
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

  it "uses the latest completed organizer checkout choice across events" do
    first = attendee(email: "buyer@example.com", opted_in: true)
    sender = CommunicationCampaigns::Sender.new(campaign)
    expect(MarketingConsent.opted_in?(organization: event.organization, email: first.buyer_email)).to be(true)
    expect(sender.audience_counts[:eligible]).to eq(1)

    other_event = create(:event, :published, organization: event.organization,
      organizer_profile: event.organizer_profile)
    withdrawn = create(:order, event: other_event, buyer_email: "BUYER@example.com", marketing_opt_in: false)
    expect(MarketingConsent.opted_in?(organization: event.organization, email: first.buyer_email)).to be(false)
    expect(sender.audience_counts[:eligible]).to eq(0)

    withdrawn.update!(status: :refunded)
    expect(sender.audience_counts[:eligible]).to eq(0)
    renewed = create(:order, event: other_event, buyer_email: "buyer@example.com", marketing_opt_in: true)
    expect(sender.audience_counts[:eligible]).to eq(1)
    sender.call
    expect(campaign.message_deliveries.sole.order).to eq(renewed)
  end

  it "suppresses a queued campaign when a later checkout withdraws consent" do
    attendee(email: "buyer@example.com", opted_in: true)
    CommunicationCampaigns::Sender.call(campaign)
    delivery = campaign.message_deliveries.sole
    create(:order, event: event, buyer_email: "buyer@example.com", marketing_opt_in: false)

    MessageDeliveryJob.perform_now(delivery.id)

    expect(delivery.reload).to be_suppressed
    expect(delivery.provider_id).to be_nil
  end
end
