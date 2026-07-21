require "rails_helper"

RSpec.describe Wallet::GoogleSaveLink do
  it "creates a signed Save to Google Wallet URL with an event class and rotated ticket object" do
    key = OpenSSL::PKey::RSA.new(2048)
    stub_const("ENV", ENV.to_h.merge(
      "GOOGLE_WALLET_ISSUER_ID" => "3388000000000000000",
      "GOOGLE_WALLET_SERVICE_ACCOUNT_EMAIL" => "wallet@example.iam.gserviceaccount.com",
      "GOOGLE_WALLET_PRIVATE_KEY" => key.to_pem,
      "FRONTEND_URL" => "https://hafapass.com"
    ))
    event = create(:event, :published)
    type = create(:ticket_type, event: event)
    order = create(:order, event: event)
    item = create(:order_item, order: order, ticket_type: type)
    ticket = create(:ticket, order: order, event: event, ticket_type: type, order_item: item)

    url = described_class.call(ticket)
    token = url.delete_prefix("https://pay.google.com/gp/v/save/")
    payload, = JWT.decode(token, key.public_key, true, algorithm: "RS256")

    expect(payload).to include("iss" => "wallet@example.iam.gserviceaccount.com", "aud" => "google")
    expect(payload.dig("payload", "eventTicketClasses", 0, "eventName", "defaultValue", "value")).to eq(event.title)
    expect(payload.dig("payload", "eventTicketObjects", 0, "barcode", "value")).to eq(ticket.scan_credential)
  end
end
