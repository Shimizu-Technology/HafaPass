require "rails_helper"

RSpec.describe "Credential API logging", type: :request do
  it "redacts signed ticket/check-in paths and arbitrary query values in actual API request instrumentation" do
    user = create(:user)
    headers = auth_headers(user).merge("X-Request-Id" => "privacy-api-request-123")
    display = SignedCredential.issue(namespace: "ticket_display", payload: { ticket_id: 999_999, version: 1 })
    scan = SignedCredential.issue(namespace: "ticket_scan", payload: { ticket_id: 999_999, version: 1 })
    allow(TicketCredential).to receive(:find_display).with(display).and_return(nil)
    allow(TicketCredential).to receive(:find_scan).with(scan).and_return(nil)
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("process_action.action_controller") do |event|
      events << event.payload.slice(:method, :path, :params, :status, :request_id, :controller, :action)
    end

    get "/api/v1/tickets/#{display}?campaign=synthetic-sensitive-query", headers: headers
    expect(response).to have_http_status(:not_found)
    post "/api/v1/check_in/#{scan}?campaign=synthetic-sensitive-query", params: { qr_code: scan }, headers: headers
    expect(response).to have_http_status(:not_found)

    expect(TicketCredential).to have_received(:find_display).with(display)
    expect(TicketCredential).to have_received(:find_scan).with(scan)
    expect(events.size).to eq(2)
    expect(events.last[:params]["qr_code"]).to eq("[FILTERED]")
    expect(events.map { |event| event[:path] }).to eq(["/api/v1/tickets/[FILTERED]", "/api/v1/check_in/[FILTERED]"])
    expect(events.map { |event| event[:method] }).to eq(%w[GET POST])
    expect(events.map { |event| event[:request_id] }).to all(eq("privacy-api-request-123"))
    expect(JSON.generate(events)).not_to include(display, scan, "synthetic-sensitive-query")
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
