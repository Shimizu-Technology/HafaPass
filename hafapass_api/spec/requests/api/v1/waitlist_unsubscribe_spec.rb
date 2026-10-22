require "rails_helper"

RSpec.describe "Event waitlist request and unsubscribe", type: :request do
  let(:event) { create(:event, :published) }

  it "records a dated event-specific request after an organizer opt-out" do
    MarketingUnsubscribe.create!(organization: event.organization, email: "buyer@example.com",
      unsubscribed_at: 1.day.ago)
    post "/api/v1/events/#{event.slug}/waitlist", params: { email: "buyer@example.com", name: "Buyer" },
      headers: { "User-Agent" => "Waitlist spec" }
    expect(response).to have_http_status(:created)
    entry = WaitlistEntry.find(response.parsed_body.fetch("id"))
    expect(entry).to have_attributes(event_id: event.id, email: "buyer@example.com", request_user_agent: "Waitlist spec")
    expect(entry.requested_at).to be_present
    expect(entry.request_ip).to be_present
    delivery = MessageDelivery.new(event: event, template: "waitlist_notification", channel: "email",
      recipient: entry.email, metadata: { "waitlist_entry_id" => entry.id })
    expect(delivery.marketing_unsubscribed?).to be(false)
    offer = create(:waitlist_offer, event: event, waitlist_entry: entry)
    offer_delivery = MessageDelivery.new(event: event, template: "waitlist_offer", channel: "email",
      recipient: entry.email, metadata: { "waitlist_offer_id" => offer.id })
    expect(offer_delivery.marketing_unsubscribed?).to be(false)
  end

  it "stops only this event through one-click and releases an unsent offer" do
    other = create(:event, :published, organization: event.organization, organizer_profile: event.organizer_profile)
    entry = create(:waitlist_entry, event: event, email: "buyer@example.com", status: :offered)
    another = create(:waitlist_entry, event: other, email: entry.email)
    offer = create(:waitlist_offer, event: event, waitlist_entry: entry, status: :offered)
    token = WaitlistUnsubscribe.token(entry)

    get "/api/v1/marketing/unsubscribe/#{token}"
    expect(response.parsed_body).to include("scope" => "waitlist", "event" => event.title)
    post "/api/v1/marketing/unsubscribe/#{token}", params: { "List-Unsubscribe" => "One-Click" }
    expect(entry.reload).to be_cancelled
    expect(offer.reload).to be_cancelled
    expect(another.reload).to be_waiting
    expect(MarketingUnsubscribe.exists?(organization: event.organization, email: entry.email)).to be(false)
  end

  it "allows a fresh event request after event-only unsubscribe" do
    entry = create(:waitlist_entry, event: event, email: "buyer@example.com")
    old_time = entry.requested_at
    old_token = WaitlistUnsubscribe.token(entry)
    post "/api/v1/marketing/unsubscribe/#{old_token}"
    post "/api/v1/events/#{event.slug}/waitlist", params: { email: entry.email, name: "Buyer" }
    expect(response).to have_http_status(:created)
    expect(entry.reload).to be_waiting
    expect(entry.requested_at).to be > old_time
    expect(WaitlistUnsubscribe.from_token(old_token)).to be_nil
  end

  it "records an organizer opt-out and stops its active event waitlists when chosen" do
    entry = create(:waitlist_entry, event: event)
    other = create(:event, :published, organization: event.organization, organizer_profile: event.organizer_profile)
    another = create(:waitlist_entry, event: other, email: entry.email)
    post "/api/v1/marketing/unsubscribe/#{WaitlistUnsubscribe.token(entry)}", params: { scope: "organizer" }
    expect(response).to have_http_status(:ok)
    expect(entry.reload).to be_cancelled
    expect(another.reload).to be_cancelled
    expect(MarketingUnsubscribe.exists?(organization: event.organization, email: entry.email)).to be(true)
  end

  it "does not change an inactive entry or its offer on a repeated event unsubscribe" do
    entry = create(:waitlist_entry, event: event, status: :cancelled)
    offer = create(:waitlist_offer, event: event, waitlist_entry: entry, status: :offered)
    token = WaitlistUnsubscribe.token(entry)
    post "/api/v1/marketing/unsubscribe/#{token}", params: { scope: "event" }
    expect(response).to have_http_status(:ok)
    expect(entry.reload).to be_cancelled
    expect(offer.reload).to be_offered
  end
end
