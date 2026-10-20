require "rails_helper"

RSpec.describe "Api::V1 ticket transfers", type: :request do
  let(:owner) { create(:user, email: "owner@example.com") }
  let(:recipient) { create(:user, email: "recipient@example.com") }
  let(:event) { create(:event, :published, starts_at: 3.days.from_now) }
  let(:order) { create(:order, event: event, user: owner, buyer_email: owner.email) }
  let(:type) { create(:ticket_type, event: event) }
  let(:item) { create(:order_item, order: order, ticket_type: type) }
  let(:ticket) { create(:ticket, order: order, event: event, ticket_type: type, order_item: item) }

  before { allow(EmailService).to receive(:send_ticket_transfer_async) }

  it "creates and accepts a transfer through authenticated buyer endpoints" do
    post "/api/v1/orders/#{order.id}/tickets/#{ticket.id}/transfer",
      params: { recipient_email: recipient.email }, headers: auth_headers(owner)

    expect(response).to have_http_status(:created)
    transfer = TicketTransfer.find(response.parsed_body.fetch("id"))
    post "/api/v1/me/ticket_transfers/accept", params: { token: TicketTransferCredential.issue(transfer) },
      headers: auth_headers(recipient)

    expect(response).to have_http_status(:ok)
    expect(ticket.reload.holder_user).to eq(recipient)

    get "/api/v1/me/tickets", headers: auth_headers(recipient)
    expect(response.parsed_body.fetch("tickets").map { |value| value.fetch("id") }).to include(ticket.id)

    post "/api/v1/orders/#{order.id}/tickets/#{ticket.id}/rotate_scan", headers: auth_headers(owner)
    expect(response).to have_http_status(:forbidden)
  end

  it "does not let an unrelated user initiate a transfer" do
    post "/api/v1/orders/#{order.id}/tickets/#{ticket.id}/transfer",
      params: { recipient_email: recipient.email }, headers: auth_headers(create(:user))

    expect(response).to have_http_status(:not_found)
  end

  it "lets an accepted holder send the ticket onward from their account" do
    ticket.update!(holder_user: recipient, holder_email: recipient.email)

    post "/api/v1/me/tickets/#{ticket.id}/transfer", params: { recipient_email: "next@example.com" },
      headers: auth_headers(recipient)

    expect(response).to have_http_status(:created)
    expect(ticket.ticket_transfers.pending.first.recipient_email).to eq("next@example.com")
  end

  it "shows the holder their pending transfer until they cancel it" do
    ticket
    post "/api/v1/me/tickets/#{ticket.id}/transfer", params: { recipient_email: "Friend@Example.com" }, headers: auth_headers(owner)
    transfer = TicketTransfer.find(response.parsed_body.fetch("id"))

    get "/api/v1/me/tickets", headers: auth_headers(owner)
    pending = response.parsed_body.fetch("tickets").sole.fetch("pending_transfer")
    expect(pending).to include("id" => transfer.id, "recipient_email" => "friend@example.com")
    expect(Time.zone.parse(pending.fetch("expires_at"))).to be_within(1.second).of(transfer.expires_at)

    get "/api/v1/orders/#{order.id}", headers: auth_headers(owner)
    expect(response.parsed_body.fetch("tickets").sole.dig("pending_transfer", "recipient_email")).to eq("friend@example.com")

    delete "/api/v1/me/tickets/#{ticket.id}/transfer", headers: auth_headers(owner)
    expect(response).to have_http_status(:ok)
    get "/api/v1/me/tickets", headers: auth_headers(owner)
    expect(response.parsed_body.fetch("tickets").sole["pending_transfer"]).to be_nil
  end

  it "drops the ticket from the sender's list once the recipient accepts" do
    allow(ClerkIdentity).to receive(:verified_email_addresses).and_return([recipient.email])
    transfer = TicketTransfers::Manager.create!(ticket: ticket, recipient_email: recipient.email)
    TicketTransfers::Manager.accept!(token: TicketTransferCredential.issue(transfer), user: recipient)

    get "/api/v1/me/tickets", headers: auth_headers(owner)
    expect(response.parsed_body.fetch("tickets")).to be_empty
    get "/api/v1/orders/#{order.id}", headers: auth_headers(owner)
    expect(response.parsed_body.fetch("tickets").sole).to include("status" => "transferred", "pending_transfer" => nil)
  end

  it "does not report an expired invitation as pending" do
    TicketTransfers::Manager.create!(ticket: ticket, recipient_email: recipient.email).update_columns(expires_at: 1.minute.ago)
    get "/api/v1/me/tickets", headers: auth_headers(owner)
    expect(response.parsed_body.fetch("tickets").sole["pending_transfer"]).to be_nil
  end
end
