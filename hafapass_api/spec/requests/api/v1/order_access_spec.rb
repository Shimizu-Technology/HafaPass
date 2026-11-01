require "rails_helper"

RSpec.describe "Buyer order access", type: :request do
  let(:event) { create(:event, :published, starts_at: 5.days.from_now) }
  let(:ticket_type) { create(:ticket_type, event: event, quantity_sold: 1) }
  let(:order) { create(:order, event: event, user: nil) }
  let(:token) { GuestOrderAccess.issue!(order) }
  let(:access_headers) { { "X-Guest-Order-Token" => token } }

  it "restores an authoritative guest order only with its secure token" do
    get "/api/v1/orders/#{order.id}", headers: access_headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("id" => order.id, "reference" => order.reference, "status" => "completed")

    get "/api/v1/orders/#{order.id}"
    expect(response).to have_http_status(:not_found)
  end

  it "restores guest access from the confirmation email without an account or prior browser storage", :webmock do
    create(:ticket, order: order, event: event, ticket_type: ticket_type)
    delivery = create(:message_delivery, order: order)
    html = EmailService.prepare_delivery_payload(delivery).fetch("html")
    link = URI.parse(Nokogiri::HTML(html).at_css("a")["href"])
    # The token travels in the fragment, which browsers never send to servers.
    expect(link.query).to be_nil
    headers = { "X-Guest-Order-Token" => Rack::Utils.parse_query(link.fragment).fetch("guest_token") }

    expect(link.path).to eq("/orders/#{order.id}/confirmation")
    get "/api/v1/orders/#{order.id}", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("id" => order.id, "status" => "completed")
    expect(response.parsed_body.fetch("tickets").length).to eq(1)

    get "/api/v1/orders/#{create(:order).id}", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "keeps frozen email wire bytes and digest out of buyer order responses" do
    payload = { "to" => "buyer@synthetic.invalid", "html" => "<a href='https://synthetic.invalid/?guest_token=private-fixture-link'>Order</a>" }
    body = JSON.generate(payload)
    digest = Digest::SHA256.hexdigest(body)
    create(:message_delivery, order: order, recipient: payload.fetch("to"), outbound_payload: payload,
      outbound_wire_body: body, wire_body_digest: digest)

    get "/api/v1/orders/#{order.id}", headers: access_headers

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("outbound_wire_body", "wire_body_digest", "private-fixture-link", digest)
  end

  it "accepts a URL token only for read-only bootstrap access" do
    get "/api/v1/orders/#{order.id}", params: { guest_token: token }
    expect(response).to have_http_status(:ok)

    post "/api/v1/orders/#{order.id}/resend", params: { guest_token: token }
    expect(response).to have_http_status(:not_found)
  end

  it "resends fulfillment through the delivery service" do
    delivery = create(:message_delivery, order: order, template: "fulfillment_resend")
    allow(FulfillmentResender).to receive(:call).and_return(delivery)

    post "/api/v1/orders/#{order.id}/resend", headers: access_headers

    expect(response).to have_http_status(:accepted)
    expect(FulfillmentResender).to have_received(:call).with(order: order, requested_by: nil)
  end

  it "reports unconfirmed ticket-email recovery without creating a fresh request or exposing provider data" do
    payload = { "html" => "private-fixture-email-body", "to" => order.buyer_email }
    body = JSON.generate(payload)
    digest = Digest::SHA256.hexdigest(body)
    delivery = create(:message_delivery, order: order, template: "order_confirmation", status: :failed,
      provider_outcome_unknown: true, provider_id: "private-provider-id", outbound_payload: payload,
      outbound_wire_body: body, wire_body_digest: digest, transport_context_digest: "private-context",
      idempotency_key: "private-provider-key")
    snapshot = delivery.reload.attributes
    allow(EmailService).to receive(:send_order_confirmation_async)

    expect { post "/api/v1/orders/#{order.id}/resend", headers: access_headers }.not_to change(MessageDelivery, :count)
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to include("reconciliation_required" => true)
    expect(delivery.reload.attributes).to eq(snapshot)
    expect(EmailService).not_to have_received(:send_order_confirmation_async)

    get "/api/v1/orders/#{order.id}", headers: access_headers
    expect(response.parsed_body.fetch("confirmation_delivery").keys).to contain_exactly(
      "status", "simulated", "updated_at", "reconciliation_required"
    )
    expect(response.parsed_body.dig("confirmation_delivery", "reconciliation_required")).to be(true)
    expect(response.body).not_to include("private-fixture-email-body", "private-provider-id", "private-context", "private-provider-key", digest,
      "outbound_wire_body", "wire_body_digest", "transport_context", "idempotency_key")
  end

  it "keeps a quickly delivered resend inside the two-minute cooldown" do
    create(:message_delivery, order: order, template: "fulfillment_resend", status: :delivered)
    allow(EmailService).to receive(:send_order_confirmation_async)
    expect { post "/api/v1/orders/#{order.id}/resend", headers: access_headers }.not_to change(MessageDelivery, :count)
    expect(response).to have_http_status(:too_many_requests)
    expect(EmailService).not_to have_received(:send_order_confirmation_async)
  end

  it "does not resend unusable tickets for a fully refunded order" do
    order.update!(status: :refunded, refund_amount_cents: order.total_cents, refunded_at: Time.current)

    post "/api/v1/orders/#{order.id}/resend", headers: access_headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq("Tickets are not available for this order")
  end

  it "cancels a free ticket, releases inventory, and rotates its scan credential" do
    free_type = create(:ticket_type, :free, event: event, quantity_sold: 1)
    free_order = create(:order, event: event, user: nil, subtotal_cents: 0, service_fee_cents: 0, total_cents: 0)
    item = create(:order_item, order: free_order, ticket_type: free_type, unit_price_cents: 0,
      subtotal_cents: 0, fee_cents: 0, organizer_proceeds_cents: 0)
    ticket = create(:ticket, order: free_order, order_item: item, event: event, ticket_type: free_type)
    credential = ticket.scan_credential
    free_token = GuestOrderAccess.issue!(free_order)

    post "/api/v1/orders/#{free_order.id}/tickets/#{ticket.id}/cancel",
      headers: { "X-Guest-Order-Token" => free_token }

    expect(response).to have_http_status(:ok)
    expect(ticket.reload).to be_cancelled
    expect(free_order.reload).to be_cancelled
    expect(AuditLog.find_by!(action: "order.cancelled", auditable: free_order)).to have_attributes(
      event_id: event.id, organization_id: event.organization_id, outcome: "succeeded")
    expect(free_type.reload.quantity_sold).to eq(0)
    expect(TicketCredential.find_scan(credential)).to be_nil

    get "/api/v1/orders/#{free_order.id}", headers: { "X-Guest-Order-Token" => free_token }
    expect(response.parsed_body.dig("tickets", 0, "status")).to eq("cancelled")
  end

  it "records that the buyer accepts an event change" do
    order
    change = event.event_changes.create!(change_type: "rescheduled", reason: "Later start",
      before_data: {}, after_data: {}, occurred_at: Time.current)

    post "/api/v1/orders/#{order.id}/event_change_response",
      params: { event_change_id: change.id, decision: "accepted" }, headers: access_headers

    expect(response).to have_http_status(:ok)
    expect(change.event_change_responses.find_by(order: order).decision).to eq("accepted")
  end

  it "hides legacy cosmetic changes and rejects a refund request for their IDs" do
    material = event.event_changes.create!(change_type: "rescheduled", occurred_at: 2.hours.ago)
    cosmetic = event.event_changes.create!(change_type: "rescheduled", occurred_at: 1.hour.ago)
    EventChange.where(id: cosmetic.id).update_all(change_type: "customized")
    cosmetic.reload
    allow(Commerce::RefundCreator).to receive(:call)

    get "/api/v1/orders/#{order.id}", headers: access_headers
    expect(response.parsed_body.dig("latest_event_change", "id")).to eq(material.id)

    post "/api/v1/orders/#{order.id}/event_change_response",
      params: { event_change_id: cosmetic.id, decision: "refund_requested" },
      headers: access_headers.merge("Idempotency-Key" => SecureRandom.uuid)
    expect(response).to have_http_status(:not_found)
    expect(cosmetic.event_change_responses).to be_empty
    expect(Commerce::RefundCreator).not_to have_received(:call)
    expect(cosmetic.event_change_responses.build(order: order, decision: "accepted", responded_at: Time.current)).not_to be_valid
    expect { EmailService.send_event_change_notifications_async(cosmetic) }.not_to change(MessageDelivery, :count)
  end

  it "rejects a changed decision before performing refund side effects" do
    change = event.event_changes.create!(change_type: "rescheduled", reason: "Later start",
      before_data: {}, after_data: {}, occurred_at: Time.current)
    change.event_change_responses.create!(order: order, decision: "accepted", responded_at: Time.current)
    allow(Commerce::RefundCreator).to receive(:call)

    post "/api/v1/orders/#{order.id}/event_change_response",
      params: { event_change_id: change.id, decision: "refund_requested" },
      headers: access_headers.merge("Idempotency-Key" => SecureRandom.uuid)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(Commerce::RefundCreator).not_to have_received(:call)
    expect(change.event_change_responses.find_by(order: order).decision).to eq("accepted")
  end

  it "reports pending and terminal failed event refunds without reporting completion or resubmitting a replay" do
    order.update!(subtotal_cents: 1000, service_fee_cents: 0, total_cents: 1000)
    item = create(:order_item, order: order, ticket_type: ticket_type, unit_price_cents: 1000,
      subtotal_cents: 1000, fee_cents: 0, organizer_proceeds_cents: 1000)
    ticket = create(:ticket, order: order, order_item: item, event: event, ticket_type: ticket_type)
    create(:payment, :succeeded, order: order)
    event.update!(status: :postponed)
    change = event.event_changes.create!(change_type: "postponed", occurred_at: Time.current)
    provider_pending = OpenStruct.new(id: "re_buyer_pending", status: "pending", amount: 1000, currency: "usd")
    allow(StripeService).to receive(:refund_payment).and_return(provider_pending)
    headers = access_headers.merge("Idempotency-Key" => "buyer-event-outcome")
    params = { event_change_id: change.id, decision: "refund_requested" }

    post "/api/v1/orders/#{order.id}/event_change_response", params: params, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("decision" => "refund_requested", "refund_status" => "pending", "reconciliation_required" => true)
    refund = order.refunds.sole
    intent = AuditLog.find_by!(action: "refund.buyer_requested", auditable: change.event_change_responses.sole)
    expect(intent).to have_attributes(source: "user", outcome: "requested", event_id: event.id,
      organization_id: event.organization_id, actor_user_id: nil)
    expect(response.parsed_body["refund_id"]).to eq(refund.id)
    expect(ticket.reload).to be_issued

    Commerce::RefundCreator.reconcile_refund!(refund: refund,
      provider_refund: OpenStruct.new(id: provider_pending.id, status: "failed", amount: 1000, currency: "usd"))
    post "/api/v1/orders/#{order.id}/event_change_response", params: params, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("refund_id" => refund.id, "refund_status" => "failed", "reconciliation_required" => false)
    expect(StripeService).to have_received(:refund_payment).once
    expect(order.refunds.count).to eq(1)
    expect(AuditLog.where(action: "refund.buyer_requested", auditable: change.event_change_responses.sole).count).to eq(1)
    expect(AuditLog.find_by!(action: "refund.failed", auditable: refund)).to have_attributes(
      source: "provider", outcome: "failed", event_id: event.id, organization_id: event.organization_id)
    expect(ticket.reload).to be_issued
  end

  it "recovers a completed ticket refund with the original key after its response was lost" do
    event.update!(status: :cancelled)
    order.update!(subtotal_cents: 1000, service_fee_cents: 0, total_cents: 1000)
    item = create(:order_item, order: order, ticket_type: ticket_type, unit_price_cents: 1000,
      subtotal_cents: 1000, fee_cents: 0, organizer_proceeds_cents: 1000)
    ticket = create(:ticket, order: order, order_item: item, event: event, ticket_type: ticket_type)
    create(:payment, :succeeded, order: order)
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_buyer_complete", status: "succeeded"))
    headers = access_headers.merge("Idempotency-Key" => "buyer-ticket-outcome")
    path = "/api/v1/orders/#{order.id}/tickets/#{ticket.id}/cancel"

    post path, headers: headers
    expect(response).to have_http_status(:created)
    expect(ticket.reload).to be_cancelled
    first_outcome = response.parsed_body.slice("refund_id", "refund_status", "reconciliation_required")
    post path, headers: headers
    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include(first_outcome.merge("refund_status" => "succeeded", "reconciliation_required" => false))
    expect(StripeService).to have_received(:refund_payment).once

    audits = AuditLog.where(auditable: order.refunds.sole)
    expect(audits.pluck(:action)).to contain_exactly("refund.requested", "refund.submission_requested", "refund.succeeded")
    expect(audits).to all(have_attributes(event_id: event.id, organization_id: event.organization_id))

    other = create(:ticket, :cancelled, order: order, event: event, ticket_type: ticket_type)
    post "/api/v1/orders/#{order.id}/tickets/#{other.id}/cancel", headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).not_to have_key("refund_id")
  end

  describe "administrator access" do
    let(:admin) { create(:user, :admin) }
    let!(:ticket) { create(:ticket, order: order, event: event, ticket_type: ticket_type) }

    it "lets an administrator view the order and resend its tickets" do
      delivery = create(:message_delivery, order: order, template: "fulfillment_resend")
      allow(FulfillmentResender).to receive(:call).and_return(delivery)

      get "/api/v1/orders/#{order.id}", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)

      post "/api/v1/orders/#{order.id}/resend", headers: auth_headers(admin)
      expect(response).to have_http_status(:accepted)
    end

    it "does not let an administrator act as the buyer" do
      change = event.event_changes.create!(change_type: "rescheduled", occurred_at: Time.current,
        before_data: { starts_at: 1.day.from_now.iso8601 }, after_data: { starts_at: event.starts_at.iso8601 })
      headers = auth_headers(admin).merge("Idempotency-Key" => SecureRandom.uuid)
      allow(Commerce::RefundCreator).to receive(:call)

      [
        [:post, "/api/v1/orders/#{order.id}/event_change_response", { event_change_id: change.id, decision: "refund_requested" }],
        [:post, "/api/v1/orders/#{order.id}/cancel", {}],
        [:post, "/api/v1/orders/#{order.id}/tickets/#{ticket.id}/cancel", {}],
        [:post, "/api/v1/orders/#{order.id}/tickets/#{ticket.id}/rotate_scan", {}],
        [:post, "/api/v1/orders/#{order.id}/tickets/#{ticket.id}/transfer", { recipient_email: "friend@example.test" }],
        [:delete, "/api/v1/orders/#{order.id}/tickets/#{ticket.id}/transfer", {}],
        [:post, "/api/v1/orders/#{order.id}/tickets/#{ticket.id}/exchange_seat", { event_seat_id: 1 }],
        [:get, "/api/v1/orders/#{order.id}/receipt", {}]
      ].each do |verb, path, params|
        public_send(verb, path, params: params, headers: headers)
        expect(response).to have_http_status(:not_found), "#{verb.upcase} #{path} returned #{response.status}"
      end
      expect(change.event_change_responses).to be_empty
      expect(Commerce::RefundCreator).not_to have_received(:call)
      expect(ticket.reload).to be_issued
    end
  end

  describe "event-change refund eligibility" do
    include ActiveSupport::Testing::TimeHelpers

    let(:holder) { create(:user) }

    def paid_order(created_at: 2.days.ago, tickets: 1, user: nil)
      paid = create(:order, event: event, user: user, created_at: created_at,
        subtotal_cents: 1000 * tickets, service_fee_cents: 0, total_cents: 1000 * tickets)
      item = create(:order_item, order: paid, ticket_type: ticket_type, quantity: tickets, unit_price_cents: 1000,
        subtotal_cents: 1000 * tickets, fee_cents: 0, organizer_proceeds_cents: 1000 * tickets)
      tickets.times { create(:ticket, order: paid, order_item: item, event: event, ticket_type: ticket_type) }
      create(:payment, :succeeded, order: paid)
      paid
    end

    def date_change(occurred_at: 1.day.ago)
      event.event_changes.create!(change_type: "rescheduled", reason: "New date", occurred_at: occurred_at,
        before_data: { starts_at: (event.starts_at - 1.day).iso8601, doors_open_at: event.doors_open_at&.iso8601 },
        after_data: { starts_at: event.starts_at.iso8601, doors_open_at: event.doors_open_at&.iso8601 })
    end

    def doors_change(occurred_at: 1.day.ago)
      event.event_changes.create!(change_type: "rescheduled", reason: "Doors later", occurred_at: occurred_at,
        before_data: { starts_at: event.starts_at.iso8601, doors_open_at: (event.starts_at - 1.hour).iso8601 },
        after_data: { starts_at: event.starts_at.iso8601, doors_open_at: (event.starts_at - 30.minutes).iso8601 })
    end

    def headers_for(paid, key: SecureRandom.uuid)
      { "X-Guest-Order-Token" => GuestOrderAccess.issue!(paid), "Idempotency-Key" => key }
    end

    def respond_to_change(paid, change, decision: "refund_requested")
      post "/api/v1/orders/#{paid.id}/event_change_response",
        params: { event_change_id: change.id, decision: decision }, headers: headers_for(paid)
    end

    def latest_change_for(paid)
      get "/api/v1/orders/#{paid.id}", headers: headers_for(paid)
      response.parsed_body.fetch("latest_event_change")
    end

    before do
      allow(StripeService).to receive(:refund_payment) do |_intent, amount_cents:, **|
        OpenStruct.new(id: "re_#{SecureRandom.hex(4)}", status: "succeeded", amount: amount_cents, currency: "usd")
      end
    end

    it "refunds an order placed before a start-time change until the event starts" do
      paid = paid_order
      change = date_change

      expect(latest_change_for(paid)).to include("refund_eligible" => true, "response_available" => true,
        "refund_deadline_at" => event.starts_at.as_json)
      respond_to_change(paid, change)

      expect(response).to have_http_status(:ok)
      expect(paid.refunds.succeeded.sole).to have_attributes(amount_cents: 1000, reason: "event_change_refund")
    end

    it "refuses refunds and responses for orders placed after the change" do
      change = date_change(occurred_at: 3.days.ago)
      paid = paid_order(created_at: 2.days.ago)

      expect(latest_change_for(paid)).to include("refund_eligible" => false, "response_available" => false,
        "refund_deadline_at" => nil)
      respond_to_change(paid, change)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include("code" => "ordered_after_change")
      respond_to_change(paid, change, decision: "accepted")
      expect(response).to have_http_status(:unprocessable_content)
      expect(change.event_change_responses).to be_empty
      expect(StripeService).not_to have_received(:refund_payment)
    end

    it "closes the refund window when a published event starts" do
      paid = paid_order
      change = date_change

      travel_to(event.starts_at + 1.minute) do
        expect(latest_change_for(paid)).to include("refund_eligible" => false, "response_available" => true)
        respond_to_change(paid, change)
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include("code" => "deadline_passed")
      expect(paid.refunds).to be_empty
    end

    it "keeps postponed events open with no deadline, then closes them once resumed and started" do
      paid = paid_order
      event.update!(status: :postponed)
      change = event.event_changes.create!(change_type: "postponed", reason: "Storm", occurred_at: 1.day.ago)

      travel_to(event.starts_at + 1.day) do
        expect(latest_change_for(paid)).to include("refund_eligible" => true, "refund_deadline_at" => nil)
        event.update!(status: :published)
        expect(latest_change_for(paid)).to include("refund_eligible" => false)
        respond_to_change(paid, change)
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include("code" => "deadline_passed")
    end

    it "leaves cancelled events to the automatic cancellation refunds" do
      paid = paid_order
      event.update!(status: :cancelled)
      change = event.event_changes.create!(change_type: "cancelled", reason: "Venue closed", occurred_at: 1.day.ago)

      expect(latest_change_for(paid)).to include("refund_eligible" => false)
      respond_to_change(paid, change)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include("code" => "event_cancelled")
    end

    it "lets buyers accept a doors-only change without offering a refund" do
      paid = paid_order
      change = doors_change

      expect(latest_change_for(paid)).to include("refund_eligible" => false, "response_available" => true)
      respond_to_change(paid, change)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include("code" => "change_not_refundable")

      respond_to_change(paid, change, decision: "accepted")
      expect(response).to have_http_status(:ok)
      expect(change.event_change_responses.sole.decision).to eq("accepted")
    end

    it "keeps an earlier start-time change refundable after a later doors-only correction" do
      paid = paid_order
      date_change(occurred_at: 1.day.ago)
      correction = doors_change(occurred_at: 1.hour.ago)

      expect(latest_change_for(paid)).to include("id" => correction.id, "refund_eligible" => true)
      respond_to_change(paid, correction)

      expect(response).to have_http_status(:ok)
      expect(paid.refunds.succeeded.sole.amount_cents).to eq(1000)
    end

    it "refunds only tickets the order still controls" do
      paid = paid_order(tickets: 2)
      kept, given = paid.tickets.order(:id).to_a
      given.update!(holder_user: holder, holder_email: holder.email)
      change = date_change

      respond_to_change(paid, change)

      expect(response).to have_http_status(:ok)
      refund = paid.refunds.sole
      expect(refund.refund_tickets.pluck(:ticket_id)).to eq([kept.id])
      expect(refund.amount_cents).to eq(1000)
      expect(given.reload).to be_issued
      expect(given.holder_user).to eq(holder)
    end

    it "refuses a change refund when every ticket was transferred away" do
      paid = paid_order
      paid.tickets.sole.update!(holder_user: holder, holder_email: holder.email)
      change = date_change

      expect(latest_change_for(paid)).to include("refund_eligible" => false)
      respond_to_change(paid, change)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include("code" => "no_tickets")
      expect(paid.refunds).to be_empty
    end

    it "does not fail the free-ticket path after refunding paid tickets when a free ticket was transferred" do
      paid = paid_order
      free_type = create(:ticket_type, :free, event: event, quantity_sold: 1)
      free_item = create(:order_item, order: paid, ticket_type: free_type, unit_price_cents: 0,
        subtotal_cents: 0, fee_cents: 0, organizer_proceeds_cents: 0)
      free_ticket = create(:ticket, order: paid, order_item: free_item, event: event, ticket_type: free_type,
        holder_user: holder, holder_email: holder.email)
      change = date_change

      respond_to_change(paid, change)

      expect(response).to have_http_status(:ok)
      expect(paid.refunds.succeeded.count).to eq(1)
      expect(free_ticket.reload).to be_issued
    end

    it "applies the same rules to paid ticket refunds while an event is postponed" do
      early = paid_order(created_at: 3.days.ago)
      event.update!(status: :postponed)
      event.event_changes.create!(change_type: "postponed", reason: "Storm", occurred_at: 2.days.ago)
      late = paid_order(created_at: 1.day.ago)

      late_ticket = late.tickets.sole
      post "/api/v1/orders/#{late.id}/tickets/#{late_ticket.id}/cancel", headers: headers_for(late)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include("code" => "ordered_after_change")
      expect(late_ticket.reload).to be_issued

      early_ticket = early.tickets.sole
      post "/api/v1/orders/#{early.id}/tickets/#{early_ticket.id}/cancel", headers: headers_for(early)
      expect(response).to have_http_status(:created)
      expect(early_ticket.reload).to be_cancelled
    end
  end
end
