# frozen_string_literal: true

require "rails_helper"
require "csv"

# A2 review finding 5 (17324039): the organizer's sales-by-tier report and CSV,
# and the attendance report, read sales only. A classified (never-fulfilled)
# order is not a sale whatever its status after a return, and payment B's
# refunds and disputes on an order payment A fulfilled never reach A's rows
# or remove A's attendance (Refund/Dispute.on_sale, including the legacy
# ticket refund fallback).
RSpec.describe "Organizer reports with classified payments", type: :request do
  let(:profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: profile, organization: profile.organization) }
  let(:type) { create(:ticket_type, event: event, name: "Adult", price_cents: 2000) }
  let(:headers) { auth_headers(profile.user).merge("X-Organization-Id" => event.organization_id.to_s) }
  let(:base) { "/api/v1/organizer/events/#{event.id}" }

  before { allow(Sentry).to receive(:capture_message) }

  def classify_second!(order, amount:)
    payment = create(:payment, order: order, provider_payment_id: "pi_rep_b_#{SecureRandom.hex(3)}", amount_cents: amount,
      status: :succeeded, succeeded_at: Time.current)
    UnfulfilledCapture.create!(order: order, payment: payment, capture_scope: "payment", code: "unfulfilled_second_capture",
      captured_cents: amount, currency: "usd", proceeds_cents: amount, fee_cents: 0, organizer_fee_cents: 0, tax_cents: 0,
      processing_bearer: "platform", dispute_fee_bearer: "platform", allocation_policy: "item_record",
      policy_version: Commerce::NeverFulfilledClassification::POLICY_VERSION, provenance: "lifecycle")
    payment
  end

  def dispute!(order, payment, amount:, status:)
    Dispute.create!(order: order, payment: payment, amount_cents: amount, currency: "usd", status: status,
      provider_dispute_id: "dp_rep_#{SecureRandom.hex(4)}", opened_at: 1.day.ago, closed_at: (Time.current if status == :lost),
      reason: "fraudulent")
  end

  def tier_rows
    get "#{base}/reports", params: { report_type: "sales_by_tier" }, headers: headers
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  def tier_csv
    get "#{base}/reports/export.csv", params: { report_type: "sales_by_tier" }, headers: headers
    expect(response).to have_http_status(:ok)
    CSV.parse(response.body.delete_prefix("﻿"), headers: true).map(&:to_h)
  end

  def attendance
    get "#{base}/reports", params: { report_type: "attendance" }, headers: headers
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch("attendance")
  end

  it "counts A's sale once, never B's refund or dispute, and never an unfulfilled or no-issuance order" do
    # A: 2 x $20.00 with buyer fees, two issued tickets (one checked in).
    order, item, payment_a = record_card_sale!(event, ticket_type: type, quantity: 2, processing_fee_cents: 0)
    order.update!(fulfilled_by_payment_id: payment_a.id)
    unchecked = create(:ticket, order: order, ticket_type: type, order_item: item)
    create(:ticket, :checked_in, order: order, ticket_type: type, order_item: item)
    # A legacy ticket (no order item) on a second fulfilled sale, so the
    # legacy refund fallback is exercised.
    legacy = create(:order, event: event, subtotal_cents: 2000, service_fee_cents: 100, total_cents: 2100)
    legacy_a = create(:payment, :succeeded, order: legacy, amount_cents: 2100)
    legacy.update!(fulfilled_by_payment_id: legacy_a.id)
    create(:ticket, order: legacy, ticket_type: type)
    baseline_rows = tier_rows
    baseline_csv = tier_csv
    baseline_attendance = attendance
    expect(baseline_attendance).to include("total_active_tickets" => 3, "checked_in_count" => 1)

    # B on A's order: refunded in part and disputed (open). B' on the legacy
    # order: refunded in full and lost.
    payment_b = classify_second!(order, amount: 2100)
    refund_b = create(:refund, order: order, payment: payment_b, amount_cents: 700, status: :succeeded)
    dispute!(order, payment_b, amount: 1400, status: :open)
    # CodeRabbit 4704013229: B's refund also carries an item on A's tier
    # (written before the A1 sale-ownership guard, which now refuses it) and
    # an active selection of A's unchecked ticket. Neither is A's.
    connection = ActiveRecord::Base.connection
    connection.execute("ALTER TABLE refund_items DISABLE TRIGGER refund_items_sale_ownership")
    create(:refund_item, refund: refund_b, order_item: item, amount_cents: 700, organizer_proceeds_cents: 700, quantity: 1)
    connection.execute("ALTER TABLE refund_items ENABLE TRIGGER refund_items_sale_ownership")
    RefundTicket.create!(refund: refund_b, ticket: unchecked, amount_cents: 700)
    expect(RefundItem.where(refund: refund_b)).to exist
    expect(RefundTicket.active.where(refund: refund_b, ticket: unchecked)).to exist
    legacy_b = classify_second!(legacy, amount: 2100)
    create(:refund, order: legacy, payment: legacy_b, amount_cents: 2100, status: :succeeded)
    dispute!(legacy, legacy_b, amount: 2100, status: :lost)

    # An order-scope classified order, partly returned to the buyer (no
    # tickets were ever issued), and a cancelled order with no issuance.
    unfulfilled, unfulfilled_payment, = classified_capture(items: [[2000, 100, 0, 0]], event: event)
    OrderItem.where(order_id: unfulfilled.id).update_all(ticket_type_id: type.id, item_kind: OrderItem.item_kinds[:ticket])
    create(:refund, order: unfulfilled, payment: unfulfilled_payment, amount_cents: 1000, status: :succeeded)
    unfulfilled.update_columns(status: Order.statuses[:partially_refunded])
    create(:order, :cancelled, event: event, subtotal_cents: 2000, service_fee_cents: 0, total_cents: 2000).tap do |cancelled|
      create(:order_item, order: cancelled, ticket_type: type, quantity: 1, unit_price_cents: 2000, subtotal_cents: 2000)
    end

    expect(tier_rows).to eq(baseline_rows)
    expect(tier_csv).to eq(baseline_csv)
    expect(attendance).to eq(baseline_attendance)
    rows = baseline_rows.fetch("sales_by_tier")
    expect(rows.sum { |row| row["tickets_sold"] }).to eq(3)
    expect(rows.sum { |row| row["refund_cents"] }).to eq(0)
    expect(baseline_rows.dig("summary", "total_refunded_cents")).to eq(0)
    expect(baseline_csv.sum { |row| row["Tickets sold"].to_i }).to eq(3)

    # The report stays exact when A's own sale is refunded: only A's refund
    # and A's own selection (the positive control) count. B's selection of
    # the same ticket is released first, as a re-selection requires.
    RefundTicket.where(refund: refund_b).update_all(released_at: Time.current)
    refund_a = record_card_refund!(order, item, payment_a, proceeds_cents: 2000, fee_cents: 100)
    RefundTicket.create!(refund: refund_a, ticket: unchecked, amount_cents: 2100)
    refunded = tier_rows
    expect(refunded.fetch("sales_by_tier").sum { |row| row["refund_cents"] }).to eq(2100)
    expect(refunded.dig("summary", "total_refunded_cents")).to eq(2100)
    expect(tier_csv.sum { |row| row["Refunded (cents)"].to_i }).to eq(2100)
    expect(attendance).to include("total_active_tickets" => baseline_attendance["total_active_tickets"] - 1,
      "checked_in_count" => 1)
  end

  it "removes A's attendance for a dispute on A's own sale" do
    order, item, payment_a = record_card_sale!(event, ticket_type: type, quantity: 1, processing_fee_cents: 0)
    order.update!(fulfilled_by_payment_id: payment_a.id)
    create(:ticket, order: order, ticket_type: type, order_item: item)
    expect(attendance).to include("total_active_tickets" => 1)

    dispute!(order, payment_a, amount: order.total_cents, status: :open)
    expect(attendance).to include("total_active_tickets" => 0)
  end
end
