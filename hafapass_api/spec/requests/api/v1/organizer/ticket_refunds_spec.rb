# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Organizer ticket refunds and cancellations", type: :request do
  let(:profile) { create(:organizer_profile) }
  let(:owner) { profile.user }
  let(:event) { create(:event, :published, organizer_profile: profile, max_capacity: 20) }
  let(:headers) { auth_headers(owner).merge("Idempotency-Key" => "selected-ticket-refund") }
  let(:order) { create(:order, event: event) }
  let(:path) { "/api/v1/organizer/events/#{event.id}/orders/#{order.id}" }

  def issue_tickets(quantity:, price:, fee: 0)
    type = create(:ticket_type, event: event, quantity_sold: quantity, price_cents: price)
    item = create(:order_item, order: order, ticket_type: type, quantity: quantity, unit_price_cents: price, fee_cents: fee)
    create_list(:ticket, quantity, event: event, order: order, order_item: item, ticket_type: type)
  end

  def submit(ids, as_headers: headers, extra: {})
    post "#{path}/refund", params: { ticket_ids: ids }.merge(extra), headers: as_headers, as: :json
  end

  before do
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeService).to receive(:refund_payment) do |_payment, amount_cents:, **|
      OpenStruct.new(id: "re_ticket_refund", status: "succeeded", amount: amount_cents, currency: order.currency)
    end
  end

  context "with five card tickets" do
    let!(:tickets) { issue_tickets(quantity: 5, price: 1000, fee: 250) }
    let!(:payment) { create(:payment, :succeeded, order: order, provider_environment: "live") }

    it "shows the options and explains checked-in, cancelled, transferred and pending tickets" do
      active, used, cancelled, transferred, pending = tickets
      used.update!(status: :checked_in, checked_in_at: Time.current)
      cancelled.update!(status: :cancelled)
      transferred.update!(holder_user: create(:user))
      refund = create(:refund, order: order, payment: payment, status: :pending, amount_cents: 1050)
      refund.refund_tickets.create!(ticket: pending, amount_cents: 1050)

      get "#{path}/refund_options", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("order_id" => order.id, "currency" => order.currency,
        "refundable_cents" => 4200, "is_free_order" => false, "is_cash_order" => false, "event_paid_out" => false,
        "unavailable_reason" => nil)
      expect(response.parsed_body.fetch("tickets")).to match([
        a_hash_including("id" => active.id, "code" => active.qr_code, "status" => "issued",
          "checked_in" => false, "checked_in_at" => nil, "transferred" => false, "refund_pending" => false,
          "refundable_cents" => 1050, "ticket_type_name" => active.ticket_type.name, "attendee_name" => active.attendee_name,
          "is_pass_parent" => false, "selectable" => true, "unavailable_reason" => nil),
        a_hash_including("id" => used.id, "checked_in" => true, "checked_in_at" => used.checked_in_at.as_json,
          "selectable" => false, "unavailable_reason" => "Already used"),
        a_hash_including("id" => cancelled.id, "selectable" => false, "unavailable_reason" => "Already cancelled"),
        a_hash_including("id" => transferred.id, "transferred" => true, "selectable" => false,
          "unavailable_reason" => "Transferred to someone else"),
        a_hash_including("id" => pending.id, "refund_pending" => true, "selectable" => false,
          "unavailable_reason" => "A refund is already in progress")
      ])
    end

    it "requires both permissions and scopes options to the event and organization" do
      manager = create(:user)
      event.organization.organization_memberships.create!(user: manager, role: :manager, status: :active, accepted_at: Time.current)
      get "#{path}/refund_options", headers: auth_headers(manager)
      expect(response).to have_http_status(:forbidden)

      other = create(:order)
      get "/api/v1/organizer/events/#{event.id}/orders/#{other.id}/refund_options", headers: headers
      expect(response).to have_http_status(:not_found)
      get "/api/v1/organizer/events/#{other.event_id}/orders/#{other.id}/refund_options", headers: headers
      expect(response).to have_http_status(:not_found)

      allow(OrganizationAuthorization).to receive(:allowed?).and_call_original
      allow(OrganizationAuthorization).to receive(:allowed?).with(
        user: owner, organization: event.organization, permission: :view_finance, event: event
      ).and_return(false)
      get "#{path}/refund_options", headers: headers
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 3 of 5 ticket prices, keeps the other QR codes valid, and updates financial totals once" do
      selected = tickets.first(3)
      ids = selected.map(&:id)
      remaining = tickets.last(2)
      original_credentials = tickets.to_h { |ticket| [ticket.id, ticket.scan_credential] }
      type = tickets.first.ticket_type
      series = create(:event_series, organization: event.organization, revenue_share_bps: 1600,
        revenue_share_base: "admissions_net_proceeds")
      series.event_series_memberships.create!(event: event, role: :regular_night, position: 0)
      create(:fee_component, order: order, order_item: selected.first.order_item, kind: "platform", amount_cents: 250)
      expect(EventSeriesReport.call(series)[:revenue_share]).to include(base_cents: 5000, share_cents: 800)

      expect { submit(ids) }.to change { type.reload.quantity_sold }.from(5).to(2)
        .and change { EventCapacity.remaining_for(event) }.by(3)
      expect(response).to have_http_status(:created), response.body
      body = response.parsed_body
      expect(body).to include("status" => "succeeded", "amount_cents" => 3150, "remaining_cents" => 2100)
      refund = order.refunds.sole
      expect(refund.refund_tickets.pluck(:ticket_id, :amount_cents)).to match_array(ids.map { |id| [id, 1050] })
      expect(refund.refund_items.sole).to have_attributes(amount_cents: 3150, quantity: 3, organizer_proceeds_cents: 3000, fee_cents: 150)
      expect(order.reload).to be_partially_refunded
      selected.each do |ticket|
        expect(ticket.reload).to be_cancelled
        expect(ticket.admission_block_reason).to eq("cancelled")
        expect(TicketCredential.find_scan(original_credentials.fetch(ticket.id))).to be_nil
      end
      remaining.each do |ticket|
        expect(ticket.reload.admission_block_reason).to be_nil
        expect(TicketCredential.find_scan(original_credentials.fetch(ticket.id))).to eq(ticket)
      end
      expect(Settlements::Calculator.call(event).attributes).to include(refund_cents: 3150, net_cents: 2100,
        organizer_proceeds_cents: 2000, platform_fee_cents: 100)
      expect(EventSeriesReport.call(series)[:revenue_share]).to include(base_cents: 2000, share_cents: 320, primary_cents: 1680)

      expect { submit(ids.reverse) }.not_to change(Refund, :count)
      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to eq(body)
      submit([remaining.first.id])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(StripeService).to have_received(:refund_payment).with(payment.provider_payment_id,
        hash_including(amount_cents: 3150, idempotency_key: "selected-ticket-refund")).once
      expect(type.reload.quantity_sold).to eq(2)
    end

    it "rejects invalid selections and never mutates any ticket on a rejected batch" do
      other = create(:ticket, order: create(:order, event: event))
      used = tickets.last
      used.update!(status: :checked_in, checked_in_at: Time.current)
      [[], tickets.first.id, [tickets.first.id.to_s], [0], [other.id], [Ticket.maximum(:id) + 1],
        [tickets.first.id, used.id]].each do |ids|
        submit(ids)
        expect(response).to have_http_status(:unprocessable_entity), response.body
      end
      submit([tickets.first.id], extra: { amount_cents: 1050 })
      expect(response).to have_http_status(:unprocessable_entity)
      submit([tickets.first.id], as_headers: auth_headers(owner))
      expect(response).to have_http_status(:unprocessable_entity)
      expect(order.refunds).to be_empty
      expect(tickets.first.reload).to be_issued
      expect(StripeService).not_to have_received(:refund_payment)
    end

    it "leaves unselected free tickets usable even when all of the card payment is returned" do
      free_ticket = issue_tickets(quantity: 1, price: 0).sole
      allow(StripeService).to receive(:refund_payment).and_return(
        OpenStruct.new(id: "re_ticket_refund", status: "pending", amount: 5250, currency: order.currency))
      submit(tickets.map(&:id))
      expect(response.parsed_body).to include("status" => "pending")
      expect(tickets.first.reload.admission_block_reason).to eq("refund_pending")
      expect(free_ticket.reload.admission_block_reason).to be_nil

      Commerce::RefundCreator.reconcile_refund!(refund: order.refunds.sole,
        provider_refund: OpenStruct.new(id: "re_ticket_refund", status: "succeeded", amount: 5250, currency: order.currency))

      expect(payment.reload).to be_refunded
      expect(order.reload).to be_partially_refunded
      expect(free_ticket.reload.admission_block_reason).to be_nil
      allow(Rails.env).to receive(:production?).and_return(true)
      expect(free_ticket.admission_block_reason).to be_nil
    end

    it "keeps tickets active for a custom amount and rejects a stale custom amount that would refund the whole order" do
      post "#{path}/refund", params: { amount_cents: 1050, preserve_tickets: true }, headers: headers, as: :json
      expect(response).to have_http_status(:created), response.body
      expect(order.refunds.sole.refund_tickets).to be_empty
      expect(order.tickets).to all(be_admission_allowed)

      post "#{path}/refund", params: { amount_cents: 4200, preserve_tickets: true },
        headers: headers.merge("Idempotency-Key" => "stale-custom-amount"), as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("Choose Full order refund")
      expect(StripeService).to have_received(:refund_payment).once
      expect(order.tickets.reload).to all(be_admission_allowed)
    end
  end

  context "with four free tickets" do
    let(:order) { create(:order, event: event, subtotal_cents: 0, service_fee_cents: 0, total_cents: 0) }
    let!(:tickets) { issue_tickets(quantity: 4, price: 0) }

    it "cancels only the selection, audits and replays the request, and cancels the order when no tickets remain" do
      selected = tickets.first(2)
      ids = selected.map(&:id)
      type = tickets.first.ticket_type
      get "#{path}/refund_options", headers: headers
      expect(response.parsed_body).to include("is_free_order" => true, "refundable_cents" => 0)
      expect(response.parsed_body.fetch("tickets")).to all(include("selectable" => true, "refundable_cents" => 0))

      expect { submit(ids) }.to change { type.reload.quantity_sold }.from(4).to(2)
        .and change { EventCapacity.remaining_for(event) }.by(2)
      expect(response).to have_http_status(:created), response.body
      body = response.parsed_body
      expect(body).to include("status" => "succeeded", "free_ticket_cancellation" => true,
        "ticket_ids" => ids, "amount_cents" => 0, "order_status" => "paid",
        "finance_review_required" => false, "reconciliation_required" => false)
      expect(order.reload).to be_completed
      expect(selected.map { |ticket| ticket.reload.admission_block_reason }).to eq(%w[cancelled cancelled])
      expect(tickets.last(2)).to all(satisfy { |ticket| ticket.reload.admission_allowed? })
      audits = AuditLog.where(auditable: order, action: "order.free_tickets_cancelled")
      expect(audits.sole).to have_attributes(actor_user_id: owner.id, organization_id: event.organization_id,
        metadata: a_hash_including("ticket_ids" => ids))

      expect { submit(ids.reverse) }.not_to change(audits, :count)
      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to eq(body)
      submit([tickets.last.id])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(tickets.last.reload).to be_issued
      final_headers = headers.merge("Idempotency-Key" => "cancel-rest")
      submit(tickets.last(2).map(&:id), as_headers: final_headers)
      expect(response).to have_http_status(:created)
      expect(response.parsed_body.fetch("order_status")).to eq("cancelled")
      expect(order.reload).to be_cancelled
      expect(type.reload.quantity_sold).to eq(0)
      expect { submit(tickets.last(2).map(&:id), as_headers: final_headers) }.not_to change(audits, :count)
      expect(response).to have_http_status(:created)
      expect(order.refunds).to be_empty
      expect(StripeService).not_to have_received(:refund_payment)
    end

    it "rolls back every ticket and its inventory when the cancellation cannot be audited" do
      allow(AuditLogger).to receive(:record!).and_call_original
      allow(AuditLogger).to receive(:record!).with(hash_including(action: "order.free_tickets_cancelled"))
        .and_raise(AuditLogger::WriteError)

      expect { submit(tickets.first(2).map(&:id)) }.to raise_error(AuditLogger::WriteError)
      expect(tickets.first(2).map { |ticket| ticket.reload.status }).to eq(%w[issued issued])
      expect(tickets.first.ticket_type.quantity_sold).to eq(4)
    end
  end
end
