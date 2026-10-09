# frozen_string_literal: true

require "rails_helper"

RSpec.describe "General admission launch scope", type: :request do
  around do |example|
    original = ENV["HAFAPASS_LAUNCH_SCOPE"]
    ENV["HAFAPASS_LAUNCH_SCOPE"] = "general_admission"
    example.run
  ensure
    original ? ENV["HAFAPASS_LAUNCH_SCOPE"] = original : ENV.delete("HAFAPASS_LAUNCH_SCOPE")
  end

  it "exposes server-owned feature availability to every client" do
    get "/api/v1/config"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("launch_capabilities").values).to all(eq(false))
  end

  it "refuses direct seat reservation requests" do
    post "/api/v1/events/example/seat_holds", params: { seat_ids: [1] }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["code"]).to eq("launch_capability_disabled")
  end

  it "refuses add-on checkout requests before creating an order" do
    expect do
      post "/api/v1/orders", params: { catalog_items: [{ catalog_item_id: 1, quantity: 1 }] }, as: :json
    end.not_to change(Order, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["code"]).to eq("launch_capability_disabled")
  end

  it "refuses recurring event setup for an authenticated organizer" do
    profile = create(:organizer_profile)
    post "/api/v1/organizer/events", params: { title: "Recurring", recurrence_rule: "weekly" },
      headers: auth_headers(profile.user), as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["code"]).to eq("launch_capability_disabled")
  end

  it "fails closed for a misspelled scope" do
    ENV["HAFAPASS_LAUNCH_SCOPE"] = "ful"
    expect(LaunchCapabilities).not_to be_configured
    expect(LaunchCapabilities.enabled?(:assigned_seating)).to be(false)
  end

  it "preserves ordinary guest checkout input in the capability guard" do
    expect(LaunchCapabilities.required_for(controller: "api/v1/orders", action: "create",
      params: { line_items: [{ ticket_type_id: 1, quantity: 1 }] })).to be_nil
  end

  it "blocks both held-ticket transfer entry points while retaining cancellation" do
    user = create(:user)
    allow(TicketTransfers::Manager).to receive(:create!)
    allow(TicketTransfers::Manager).to receive(:accept!)
    post "/api/v1/me/tickets/999/transfer", params: { recipient_email: "recipient@example.invalid" }, headers: auth_headers(user)
    expect(response.parsed_body["code"]).to eq("launch_capability_disabled")
    post "/api/v1/me/ticket_transfers/accept", params: { token: "synthetic" }, headers: auth_headers(user)
    expect(response.parsed_body["code"]).to eq("launch_capability_disabled")
    expect(TicketTransfers::Manager).not_to have_received(:create!)
    expect(TicketTransfers::Manager).not_to have_received(:accept!)
    expect(LaunchCapabilities.required_for(controller: "api/v1/me/ticket_transfers", action: "destroy", params: {})).to be_nil
  end

  it "disables an existing transfer setting when an unrelated event update omits it" do
    profile = create(:organizer_profile)
    event = create(:event, organizer_profile: profile, transfers_enabled: true)
    patch "/api/v1/organizer/events/#{event.id}", params: { description: "Updated event details" }, headers: auth_headers(profile.user)
    expect(response).to have_http_status(:ok)
    expect(event.reload.transfers_enabled).to be(false)
  end
end
