require "rails_helper"

RSpec.describe "Guest purchase account recovery", type: :request do
  let(:user) { create(:user, email: "editable-contact@example.com") }
  let(:headers) { auth_headers(user) }
  let(:event) { create(:event, :published, starts_at: 3.days.from_now) }
  let(:order) { create(:order, event: event, buyer_email: " Buyer@Example.com ") }
  let!(:ticket) { create(:ticket, order: order, ticket_type: create(:ticket_type, event: event)) }

  before do
    headers
    allow(ClerkIdentity).to receive(:verified_email_addresses)
      .with(user.clerk_id, require_available: true).and_return(["buyer@example.com"])
  end

  def recover
    post "/api/v1/me/orders/recover_guest", headers: headers
  end

  it "recovers the original payer and ticket through server-verified email, idempotently" do
    original_credentials = [ticket.display_credential, ticket.scan_credential]
    guest_token = GuestOrderAccess.issue!(order)
    recover

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("recovered_orders_count" => 1, "recovered_tickets_count" => 1)
    expect(order.reload.user).to eq(user)
    expect(ticket.reload.holder_user).to eq(user)
    expect([ticket.display_credential, ticket.scan_credential]).to eq(original_credentials)
    expect(GuestOrderAccess.find(guest_token)).to be_nil
    get "/api/v1/orders/#{order.id}", headers: headers
    expect(response).to have_http_status(:ok)
    get "/api/v1/me/tickets", headers: headers
    expect(response.parsed_body.fetch("tickets").pluck("id")).to include(ticket.id)
    get "/api/v1/tickets/#{ticket.display_credential}", headers: headers
    expect(response.parsed_body.fetch("scan_credential")).to eq(ticket.scan_credential)

    recover
    expect(response.parsed_body).to eq("recovered_orders_count" => 0, "recovered_tickets_count" => 0)
    expect(AuditLog.where(action: "guest_purchase.recovered", auditable: order).count).to eq(1)
  end

  it "does not accept editable contact email or submitted ownership claims" do
    allow(ClerkIdentity).to receive(:verified_email_addresses)
      .with(user.clerk_id, require_available: true).and_return([])
    user.update!(email: "buyer@example.com")
    post "/api/v1/me/orders/recover_guest", params: { buyer_email: "buyer@example.com", order_id: order.id }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(order.reload.user_id).to be_nil
    expect(ticket.reload.holder_user_id).to be_nil
  end

  it "never steals purchases already attached to another account, or unrelated guest purchases" do
    other = create(:user)
    order.update!(user: other)
    unrelated = create(:order, event: event, buyer_email: "someone-else@example.com")
    recover

    expect(order.reload.user).to eq(other)
    expect(unrelated.reload.user_id).to be_nil
    expect(ticket.reload.holder_user_id).to be_nil
  end

  it "preserves transferred holders and original payer access without restoring entry credentials" do
    recipient = create(:user)
    ticket.update!(holder_user: recipient, holder_email: recipient.email)
    ticket.ticket_transfers.create!(recipient_email: recipient.email, status: :accepted,
      accepted_by_user: recipient, accepted_at: Time.current, expires_at: 1.day.from_now)
    recover

    expect(order.reload.user).to eq(user)
    expect(ticket.reload.holder_user).to eq(recipient)
    get "/api/v1/me/tickets", headers: headers
    expect(response.parsed_body.fetch("tickets")).to be_empty
    get "/api/v1/orders/#{order.id}", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("tickets").first.fetch("scan_credential")).to be_nil
    post "/api/v1/orders/#{order.id}/tickets/#{ticket.id}/rotate_scan", headers: headers
    expect(response).to have_http_status(:forbidden)
  end

  it "does not restore a transferred ticket whose holder was subsequently cleared" do
    ticket.ticket_transfers.create!(recipient_email: "recipient@example.com", status: :accepted,
      accepted_at: Time.current, expires_at: 1.day.from_now)
    recover
    expect(order.reload.user).to eq(user)
    expect(ticket.reload.holder_user_id).to be_nil
  end

  it "preserves canceled, used and refunded ticket state and discovers purchases across organizations" do
    ticket.update!(status: :cancelled)
    refunded = create(:order, :refunded, buyer_email: "buyer@example.com")
    used = create(:ticket, :checked_in, order: refunded)
    recover

    expect(response.parsed_body.fetch("recovered_orders_count")).to eq(2)
    expect(ticket.reload).to be_cancelled
    expect(used.reload).to be_checked_in
    expect(refunded.reload).to be_refunded
    expect(used.holder_user).to eq(user)
    expect(used.admission_allowed?).to be(false)
  end

  it "fails closed during identity discovery outages without hiding known owned tickets" do
    known = create(:ticket, order: create(:order, user: user))
    allow(ClerkIdentity).to receive(:verified_email_addresses)
      .with(user.clerk_id, require_available: true).and_raise(ClerkIdentity::LookupUnavailable)
    recover

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to include("code" => "identity_verification_unavailable", "retryable" => true)
    expect(order.reload.user_id).to be_nil
    get "/api/v1/me/tickets", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("tickets").pluck("id")).to eq([known.id])
  end

  it "requires authenticated recovery and does not mutate ownership through the read endpoint" do
    get "/api/v1/me/tickets", headers: headers
    expect(ticket.reload.holder_user_id).to be_nil
    post "/api/v1/me/orders/recover_guest"
    expect(response).to have_http_status(:unauthorized)
    expect(order.reload.user_id).to be_nil
  end
end
