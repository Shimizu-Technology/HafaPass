require "rails_helper"

RSpec.describe "Waitlist commercial email" do
  let(:event) { create(:event, :published) }
  let(:entry) { create(:waitlist_entry, event: event) }

  before do
    event.organization.update!(marketing_mailing_address: "123 Marine Drive, Hagåtña, GU 96910",
      marketing_address_certified_at: Time.current)
  end

  it "identifies the organizer and includes its address and one-click unsubscribe in an availability alert" do
    delivery = EmailService.send_waitlist_notification_async(entry)
    payload = EmailService.prepare_delivery_payload(delivery)

    expect(delivery).to be_promotional
    expect(delivery).not_to be_requires_marketing_consent
    expect(payload.fetch("from")).to eq("#{event.organization.name} via HåfaPass <#{EmailService.from_email}>")
    expect(payload.fetch("html")).to include("123 Marine Drive", "Unsubscribe from")
    expect(payload.dig("headers", "List-Unsubscribe")).to include("/api/v1/marketing/unsubscribe/")
    expect(payload.dig("headers", "List-Unsubscribe-Post")).to eq("List-Unsubscribe=One-Click")
  end

  it "applies the same commercial footer and headers to a waitlist offer" do
    offer = create(:waitlist_offer, waitlist_entry: entry, event: event)
    delivery = EmailService.send_waitlist_offer_async(offer)
    payload = EmailService.prepare_delivery_payload(delivery)

    expect(delivery).to be_promotional
    expect(payload.fetch("html")).to include("123 Marine Drive", "Unsubscribe from")
    expect(payload.dig("headers", "List-Unsubscribe-Post")).to eq("List-Unsubscribe=One-Click")
  end

  it "suppresses an alert after opt-out or address certification withdrawal" do
    unsubscribed = EmailService.send_waitlist_notification_async(entry)
    MarketingUnsubscribe.create!(organization: event.organization, email: entry.email,
      unsubscribed_at: Time.current)
    MessageDeliveryJob.perform_now(unsubscribed.id)
    expect(unsubscribed.reload).to be_suppressed

    MarketingUnsubscribe.delete_all
    offer = create(:waitlist_offer, waitlist_entry: entry, event: event)
    uncertified = EmailService.send_waitlist_offer_async(offer)
    event.organization.update!(marketing_address_certified_at: nil)
    MessageDeliveryJob.perform_now(uncertified.id)
    expect(uncertified.reload).to be_suppressed
  end
end
