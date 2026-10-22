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

  it "does not let a content-only editor change an event's transfer setting" do
    profile = create(:organizer_profile)
    event = create(:event, organizer_profile: profile, transfers_enabled: true)
    editor = create(:user)
    event.organization.organization_memberships.create!(user: editor, role: :marketer, status: :active, accepted_at: Time.current)
    patch "/api/v1/organizer/events/#{event.id}", params: { description: "New content" }, headers: auth_headers(editor)
    expect(response).to have_http_status(:ok)
    expect(event.reload.description).to eq("New content")
    expect(event.transfers_enabled).to be(true)
    expect(LaunchCapabilities.enabled?(:ticket_transfers)).to be(false)
  end
end

RSpec.describe "Per-capability launch control", type: :request do
  around do |example|
    keys = %w[HAFAPASS_LAUNCH_SCOPE HAFAPASS_LAUNCH_CAPABILITIES]
    original = keys.index_with { |key| ENV[key] }
    ENV["HAFAPASS_LAUNCH_SCOPE"] = "general_admission"
    ENV["HAFAPASS_LAUNCH_CAPABILITIES"] = "ticket_transfers"
    example.run
  ensure
    original.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  it "keeps the scope preset unchanged when no extra capability is listed" do
    ENV.delete("HAFAPASS_LAUNCH_CAPABILITIES")
    expect(LaunchCapabilities.public_configuration.values).to all(eq(false))
    ENV["HAFAPASS_LAUNCH_SCOPE"] = "full"
    expect(LaunchCapabilities.public_configuration.values).to all(eq(true))
  end

  it "enables only the listed capability on top of general admission" do
    get "/api/v1/config"
    expect(response.parsed_body.fetch("launch_capabilities")).to eq(
      "assigned_seating" => false, "recurring_events" => false, "advanced_sales_tools" => false,
      "ticket_transfers" => true, "door_card" => false
    )
    expect(LaunchCapabilities).to be_configured
  end

  it "accepts spacing and case in a comma list" do
    ENV["HAFAPASS_LAUNCH_CAPABILITIES"] = " Ticket_Transfers , door_card,"
    expect(LaunchCapabilities.enabled?(:ticket_transfers)).to be(true)
    expect(LaunchCapabilities.enabled?(:door_card)).to be(true)
    expect(LaunchCapabilities.enabled?(:assigned_seating)).to be(false)
  end

  it "fails closed and refuses to validate an unknown capability" do
    ENV["HAFAPASS_LAUNCH_CAPABILITIES"] = "ticket_transfers,ticket_transfer"
    expect(LaunchCapabilities.enabled?(:ticket_transfers)).to be(false)
    expect(LaunchCapabilities).not_to be_configured
    expect(ProductionConfiguration.call.dig(:checks, :launch_scope)).to be(false)
    expect { LaunchCapabilities.validate! }.to raise_error(LaunchCapabilities::ConfigurationError, /ticket_transfer\b/)
  end

  it "refuses to validate a misspelled scope even with valid capabilities" do
    ENV["HAFAPASS_LAUNCH_SCOPE"] = "ful"
    expect(LaunchCapabilities.enabled?(:ticket_transfers)).to be(false)
    expect { LaunchCapabilities.validate! }.to raise_error(LaunchCapabilities::ConfigurationError, /HAFAPASS_LAUNCH_SCOPE/)
  end

  it "keeps other general-admission guards in place" do
    post "/api/v1/events/example/seat_holds", params: { seat_ids: [1] }, as: :json
    expect(response.parsed_body["code"]).to eq("launch_capability_disabled")
  end

  it "runs a transfer end to end: organizer enables, holder sends, recipient accepts, codes rotate" do
    allow(EmailService).to receive(:send_ticket_transfer_async)
    profile = create(:organizer_profile)
    event = create(:event, :published, organizer_profile: profile, starts_at: 3.days.from_now, transfers_enabled: false)
    owner = create(:user, email: "owner@example.com")
    recipient = create(:user, email: "recipient@example.com")
    order = create(:order, event: event, user: owner, buyer_email: owner.email)
    type = create(:ticket_type, event: event)
    ticket = create(:ticket, order: order, event: event, ticket_type: type,
      order_item: create(:order_item, order: order, ticket_type: type))
    old_scan = ticket.scan_credential
    old_display = ticket.display_credential

    patch "/api/v1/organizer/events/#{event.id}", params: { transfers_enabled: true }, headers: auth_headers(profile.user)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["transfers_enabled"]).to be(true)

    get "/api/v1/me/tickets", headers: auth_headers(owner)
    expect(response.parsed_body.fetch("tickets").first.dig("event", "transfers_enabled")).to be(true)

    post "/api/v1/me/tickets/#{ticket.id}/transfer", params: { recipient_email: recipient.email }, headers: auth_headers(owner)
    expect(response).to have_http_status(:created)
    transfer = TicketTransfer.find(response.parsed_body.fetch("id"))

    post "/api/v1/me/ticket_transfers/accept", params: { token: TicketTransferCredential.issue(transfer) },
      headers: auth_headers(recipient)
    expect(response).to have_http_status(:ok)
    ticket.reload
    expect(ticket.holder_user).to eq(recipient)
    expect(TicketCredential.valid_scan_for?(ticket, old_scan)).to be(false)
    expect(TicketCredential.valid_scan_for?(ticket, ticket.scan_credential)).to be(true)
    expect(TicketCredential.find_display(old_display)).to be_nil
  end

  it "hides and refuses transfers once the capability is removed" do
    ENV.delete("HAFAPASS_LAUNCH_CAPABILITIES")
    owner = create(:user)
    event = create(:event, :published, starts_at: 3.days.from_now, transfers_enabled: true)
    order = create(:order, event: event, user: owner, buyer_email: owner.email)
    type = create(:ticket_type, event: event)
    ticket = create(:ticket, order: order, event: event, ticket_type: type,
      order_item: create(:order_item, order: order, ticket_type: type))

    get "/api/v1/me/tickets", headers: auth_headers(owner)
    expect(response.parsed_body.fetch("tickets").first.dig("event", "transfers_enabled")).to be(false)
    post "/api/v1/me/tickets/#{ticket.id}/transfer", params: { recipient_email: "next@example.com" }, headers: auth_headers(owner)
    expect(response.parsed_body["code"]).to eq("launch_capability_disabled")
    expect { TicketTransfers::Manager.create!(ticket: ticket, recipient_email: "next@example.com") }
      .to raise_error(TicketTransfers::Manager::TransferError, /disabled/)
  end
end
