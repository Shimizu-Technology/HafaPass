# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Buyer operations during an audit storage outage", type: :request do
  let(:buyer) { create(:user, email: "buyer@example.test") }
  let(:recipient) { create(:user, email: "recipient@example.test") }
  let(:event) { create(:event, :published, starts_at: 3.days.from_now, venue: create(:venue)) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 0, quantity_available: 100) }
  let(:order) { create(:order, event: event, user: buyer, buyer_email: buyer.email, subtotal_cents: 0, service_fee_cents: 0, total_cents: 0) }
  let(:item) { create(:order_item, order: order, ticket_type: ticket_type, unit_price_cents: 0, fee_cents: 0) }
  let(:ticket) { create(:ticket, event: event, order: order, ticket_type: ticket_type, order_item: item) }

  before do
    allow(EmailService).to receive(:send_ticket_transfer_async)
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(EmailService).to receive(:send_ticket_email_async)
    allow(Sentry).to receive(:capture_exception)
  end

  # Include deduplicated inserts and a real aborted Postgres statement: a Ruby
  # exception alone does not prove the business transaction can still commit.
  def fail_audit_writes!
    %i[create! create_or_find_by!].each do |method|
      allow(AuditLog).to receive(method) do
        AuditLog.connection.execute("SELECT * FROM missing_audit_storage")
      end
    end
  end

  def expect_reported(*actions)
    actions.each do |action|
      expect(AuditWriteFailure.where(action: action)).to exist
      expect(Sentry).to have_received(:capture_exception).with(an_instance_of(AuditLogger::WriteError),
        extra: hash_including(action: action, failure_class: "ActiveRecord::StatementInvalid"))
    end
  end

  def checkout(**attributes)
    Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: buyer.email, buyer_name: "Buyer", **attributes)
  end

  it "commits checkout and the accepted waiver" do
    waiver = create(:event_waiver, event: event)
    ticket_type
    buyer
    fail_audit_writes!
    result = checkout(waiver_acceptances: [{ event_waiver_id: waiver.id, version: waiver.version }])
    expect(result.order.reload).to be_completed
    expect(result.order.tickets.count).to eq(1)
    expect(result.order.waiver_acceptances.sole).to have_attributes(version: waiver.version, content_digest: waiver.content_digest)
    expect_reported("waiver.accepted")
  end

  it "creates a transfer and expires a stale invitation" do
    stale = TicketTransfers::Manager.create!(ticket: ticket, recipient_email: recipient.email, initiated_by: buyer)
    stale.update_columns(expires_at: 1.minute.ago)
    headers = auth_headers(buyer)
    fail_audit_writes!
    post "/api/v1/orders/#{order.id}/tickets/#{ticket.id}/transfer", params: { recipient_email: recipient.email }, headers: headers
    expect(response).to have_http_status(:created)
    expect(stale.reload).to be_expired
    expect(ticket.ticket_transfers.pending.sole.recipient_email).to eq(recipient.email)
    expect_reported("ticket_transfer.created", "ticket_transfer.expired")
  end

  it "accepts a transfer, changes the holder and invalidates old credentials" do
    transfer = TicketTransfers::Manager.create!(ticket: ticket, recipient_email: recipient.email, initiated_by: buyer)
    versions = [ticket.scan_credential_version, ticket.display_credential_version]
    headers = auth_headers(recipient)
    fail_audit_writes!
    post "/api/v1/me/ticket_transfers/accept", params: { token: TicketTransferCredential.issue(transfer) }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(transfer.reload).to be_accepted
    expect(ticket.reload).to have_attributes(holder_user_id: recipient.id,
      scan_credential_version: versions[0] + 1, display_credential_version: versions[1] + 1)
    expect_reported("ticket_transfer.accepted", "ticket.scan_credential_rotated")
  end

  it "cancels a pending transfer" do
    transfer = TicketTransfers::Manager.create!(ticket: ticket, recipient_email: recipient.email, initiated_by: buyer)
    headers = auth_headers(buyer)
    fail_audit_writes!
    delete "/api/v1/me/tickets/#{ticket.id}/transfer", headers: headers
    expect(response).to have_http_status(:ok)
    expect(transfer.reload).to be_cancelled
    expect_reported("ticket_transfer.cancelled")
  end

  it "rotates a buyer's scan credential" do
    version = ticket.scan_credential_version
    headers = auth_headers(buyer)
    fail_audit_writes!
    post "/api/v1/orders/#{order.id}/tickets/#{ticket.id}/rotate_scan", headers: headers
    expect(response).to have_http_status(:ok)
    expect(ticket.reload.scan_credential_version).to eq(version + 1)
    expect_reported("ticket.scan_credential_rotated")
  end

  it "preserves display credential revocation" do
    version = ticket.display_credential_version
    fail_audit_writes!
    ticket.revoke_display_credential!
    expect(ticket.reload.display_credential_version).to eq(version + 1)
    expect_reported("ticket.display_credential_revoked")
  end

  it "cancels a free assigned-seat ticket and releases the seat" do
    configuration = create(:event_seating_configuration, event: event)
    seat = create(:event_seat, event_seating_configuration: configuration, ticket_type: ticket_type)
    ticket.update!(event_seat: seat)
    headers = auth_headers(buyer)
    fail_audit_writes!
    post "/api/v1/orders/#{order.id}/tickets/#{ticket.id}/cancel", headers: headers
    expect(response).to have_http_status(:ok)
    expect(ticket.reload).to be_cancelled
    expect(order.reload).to be_cancelled
    expect(seat.reload.selectable?).to be(true)
    expect_reported("ticket.cancelled", "seat.released_from_ticket")
  end

  it "exchanges the buyer's seat and rotates credentials" do
    configuration = create(:event_seating_configuration, event: event)
    previous = create(:event_seat, event_seating_configuration: configuration, ticket_type: ticket_type)
    target = create(:event_seat, event_seating_configuration: configuration, ticket_type: ticket_type)
    ticket.update!(event_seat: previous)
    headers = auth_headers(buyer)
    fail_audit_writes!
    post "/api/v1/orders/#{order.id}/tickets/#{ticket.id}/exchange_seat", params: { event_seat_id: target.id }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(ticket.reload.event_seat).to eq(target)
    expect_reported("seat.exchanged", "ticket.scan_credential_rotated")
  end

  it "records a buyer's event-change refund request and cancels free tickets" do
    ticket
    change = event.event_changes.create!(change_type: "cancelled", occurred_at: Time.current)
    headers = auth_headers(buyer).merge("Idempotency-Key" => "buyer-audit-outage-refund")
    fail_audit_writes!
    post "/api/v1/orders/#{order.id}/event_change_response",
      params: { event_change_id: change.id, decision: "refund_requested" }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(change.event_change_responses.sole.decision).to eq("refund_requested")
    expect(ticket.reload).to be_cancelled
    expect_reported("refund.buyer_requested", "ticket.cancelled")
  end

  it "lets a public buyer join, cancel and rejoin the waitlist" do
    ticket_type
    fail_audit_writes!
    path = "/api/v1/events/#{event.slug}/waitlist"
    params = { email: "waiter@example.test", ticket_type_id: ticket_type.id, quantity: 1 }
    post path, params: params
    expect(response).to have_http_status(:created)
    entry = WaitlistEntry.find(response.parsed_body.fetch("id"))
    delete path, params: { management_token: entry.management_credential }
    expect(response).to have_http_status(:no_content)
    expect(entry.reload).to be_cancelled
    post path, params: params
    expect(response).to have_http_status(:created)
    expect(entry.reload).to be_waiting
    expect_reported("waitlist.joined", "waitlist.cancelled", "waitlist.rejoined")
  end

  it "cancels the buyer's active offer when they stop alerts" do
    entry = create(:waitlist_entry, event: event, ticket_type: ticket_type, status: :offered)
    offer = create(:waitlist_offer, waitlist_entry: entry)
    fail_audit_writes!
    delete "/api/v1/events/#{event.slug}/waitlist", params: { management_token: entry.management_credential }
    expect(response).to have_http_status(:no_content)
    expect(entry.reload).to be_cancelled
    expect(offer.reload).to be_cancelled
    expect_reported("waitlist.cancelled", "waitlist_offer.cancelled")
  end

  it "claims and converts a waitlist offer during checkout" do
    entry = create(:waitlist_entry, event: event, ticket_type: ticket_type, email: buyer.email, status: :offered)
    offer = create(:waitlist_offer, waitlist_entry: entry)
    fail_audit_writes!
    result = checkout(waitlist_offer_token: WaitlistCredential.offer(offer))
    expect(result.order.reload).to be_completed
    expect(entry.reload).to be_converted
    expect(offer.reload).to be_converted
    expect_reported("waitlist_offer.updated", "waitlist_offer.claimed", "waitlist_offer.converted", "waitlist.converted")
  end

  it "expires an abandoned offer and requeues the entry" do
    entry = create(:waitlist_entry, event: event, ticket_type: ticket_type, status: :offered)
    offer = create(:waitlist_offer, waitlist_entry: entry)
    fail_audit_writes!
    expect(offer.expire!).to be(true)
    expect(offer.reload).to be_expired
    expect(entry.reload).to be_waiting
    expect_reported("waitlist_offer.expired", "waitlist.requeued")
  end

  it "persists waitlist expiry" do
    entry = create(:waitlist_entry, event: event, ticket_type: ticket_type)
    fail_audit_writes!
    entry.update!(status: :expired)
    expect(entry.reload).to be_expired
    expect_reported("waitlist.expired")
  end

  it "reconciles provider delivery success into a buyer availability notification" do
    entry = create(:waitlist_entry, event: event, ticket_type: ticket_type,
      notified_at: 1.minute.ago, delivery_failure: "Previously failed")
    delivery = create(:message_delivery, event: event, template: "waitlist_notification", status: :delivered,
      metadata: { waitlist_entry_id: entry.id, notified_at: entry.notified_at.iso8601(6) })
    fail_audit_writes!
    WaitlistDelivery.reconcile_success!(delivery)
    expect(entry.reload).to be_notified
    expect(entry.delivery_failure).to be_nil
    expect_reported("waitlist.notification_requested")
  end

  it "accepts an authenticated buyer's privacy request" do
    headers = auth_headers(buyer)
    allow(ClerkIdentity).to receive(:verified_email_addresses).with(buyer.clerk_id, require_available: true).and_return([buyer.email])
    fail_audit_writes!
    post "/api/v1/me/privacy_requests", params: { kind: "access" }, headers: headers
    expect(response).to have_http_status(:created)
    expect(PrivacyRequest.last.user).to eq(buyer)
    expect_reported("privacy_request.submitted")
  end

  it "submits and verifies a guest privacy challenge" do
    guest = create(:order, event: event)
    token = GuestOrderAccess.issue!(guest)
    code = nil
    allow(EmailService).to receive(:send_guest_privacy_challenge_now) { |_item, value| code = value }
    fail_audit_writes!
    post "/api/v1/guest_privacy_requests", params: { kind: "access", order_id: guest.id, guest_token: token }
    expect(response).to have_http_status(:created)
    request = PrivacyRequest.last
    post "/api/v1/guest_privacy_requests/#{request.id}/verify", params: { code: code }
    expect(response).to have_http_status(:ok)
    expect(request.reload.verified?).to be(true)
    expect_reported("privacy_request.submitted", "privacy_request.verified")
  end
end
