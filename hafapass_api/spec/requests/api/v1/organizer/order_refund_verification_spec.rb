require "rails_helper"

RSpec.describe "Organizer order external refund verification", type: :request do
  let(:user) { create(:user, :organizer) }
  let(:profile) { create(:organizer_profile, user: user) }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:headers) { auth_headers(user) }

  def paid_order(event: self.event, name: "Synthetic buyer")
    order = create(:order, event: event, buyer_name: name)
    create(:payment, :succeeded, order: order)
    order
  end

  def issue_for(order, code: "refund_aggregate_requires_reconciliation", payment_only: false, status: :open)
    create(:reconciliation_exception, order: payment_only ? nil : order, payment: order.payments.first,
      code: code, status: status)
  end

  def list(**params)
    get "/api/v1/organizer/events/#{event.id}/orders", params: params, headers: headers
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body.fetch("orders")
  end

  it "flags open external verification by order or payment and excludes fee-only/resolved issues" do
    aggregate = paid_order
    operation = paid_order
    fee_only = paid_order
    resolved = paid_order
    issue_for(aggregate)
    issue_for(operation, code: "refund_operation_not_found", payment_only: true)
    issue_for(fee_only, code: "stripe_processing_fee_review")
    issue_for(resolved, status: :resolved)

    rows = list.index_by { |row| row.fetch("id") }

    expect(rows.fetch(aggregate.id)).to include("external_refund_verification_required" => true)
    expect(rows.fetch(operation.id)).to include("external_refund_verification_required" => true)
    expect(rows.fetch(fee_only.id)).to include("external_refund_verification_required" => false)
    expect(rows.fetch(resolved.id)).to include("external_refund_verification_required" => false)
    expect(rows.values).to all(satisfy { |row| !row.key?("reconciliation_exception_id") })
  end

  it "recognizes legacy order-only issues without spreading the hold to another order" do
    blocked = paid_order
    normal = paid_order
    create(:reconciliation_exception, order: blocked, payment: nil, code: "refund_operation_not_found")

    rows = list.index_by { |row| row.fetch("id") }

    expect(rows.fetch(blocked.id).fetch("external_refund_verification_required")).to be(true)
    expect(rows.fetch(normal.id).fetch("external_refund_verification_required")).to be(false)
  end

  it "restores the flag after verification resolves while other payout holds remain open" do
    order = paid_order
    payment = order.payments.first
    operation = OpenStruct.new(id: "re_verified_failed", payment_intent: payment.provider_payment_id,
      amount: 1200, currency: payment.currency, status: "failed")
    issue = create(:reconciliation_exception, order: order, payment: payment, code: "refund_operation_not_found",
      details: { provider_refund_id: operation.id, provider_payment_id: payment.provider_payment_id,
        amount_cents: 1200, currency: payment.currency, status: "failed" })
    fee = issue_for(order, code: "independent_fee_review")
    allow(StripeService).to receive(:list_refunds).and_return([operation])
    allow(StripeService).to receive(:refund_payment)
    expect(list.first.fetch("external_refund_verification_required")).to be(true)

    Commerce::ExternalRefundRecovery.call(issue: issue)

    expect(issue.reload).to be_resolved
    expect(list.first.fetch("external_refund_verification_required")).to be(false)
    expect(StripeService).not_to have_received(:refund_payment)
    expect(fee.reload).to be_open
    expect(OrganizationPayoutBalance.available_cents(event.organization)).to eq(0)
  end

  it "keeps an unknown legacy issue blocked after retrieval records failed history without matching its missing evidence" do
    order = paid_order
    payment = order.payments.first
    issue = issue_for(order, code: "refund_operation_not_found")
    allow(StripeService).to receive(:list_refunds).and_return([OpenStruct.new(id: "re_unknown_history",
      payment_intent: payment.provider_payment_id, amount: 1200, currency: payment.currency, status: "failed")])
    allow(StripeService).to receive(:refund_payment)

    Commerce::ExternalRefundRecovery.call(issue: issue)

    expect(issue.reload).to be_open
    expect(order.refunds.sole).to have_attributes(status: "failed", amount_cents: 1200)
    expect(order.refunds.sole).to be_historical_observation
    expect(order.refunds.succeeded).to be_empty
    expect(RefundItem.joins(:refund).where(refunds: { order_id: order.id })).to be_empty
    expect(list.first.fetch("external_refund_verification_required")).to be(true)
    expect(StripeService).not_to have_received(:refund_payment)
  end

  it "does not expose another tenant's orders or apply its verification state to this event" do
    mine = paid_order
    other_event = create(:event, :published)
    other_order = paid_order(event: other_event)
    issue_for(other_order)
    expect(list.map { |row| [row.fetch("id"), row.fetch("external_refund_verification_required")] }).to eq([[mine.id, false]])

    get "/api/v1/organizer/events/#{other_event.id}/orders", headers: headers
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).not_to have_key("orders")
    get "/api/v1/organizer/events/#{event.id}/orders", headers: headers.merge("X-Organization-Id" => other_event.organization_id.to_s)
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).not_to have_key("orders")
  end

  it "computes the flag on filtered order pages independently of reconciliation pagination" do
    blocked = paid_order(name: "Blocked buyer")
    normal = paid_order(name: "Normal buyer")
    issue_for(blocked)

    expect(list(q: "Blocked buyer", per_page: 1)).to contain_exactly(include(
      "id" => blocked.id, "external_refund_verification_required" => true))
    expect(list(q: "Normal buyer", per_page: 1)).to contain_exactly(include(
      "id" => normal.id, "external_refund_verification_required" => false))
  end

  it "uses one verification lookup and bounded SELECTs for fifty orders" do
    orders = 50.times.map { paid_order }
    issue_for(orders.first, payment_only: true)
    captured = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      captured << payload[:sql] if payload[:sql]&.match?(/\ASELECT\b/i) && !payload[:cached] && payload[:name] != "SCHEMA"
    end
    list(per_page: 1)
    one_count = captured.length
    captured.clear
    rows = list(per_page: 50)

    expect(rows.length).to eq(50)
    expect(rows.count { |row| row.fetch("external_refund_verification_required") }).to eq(1)
    expect(captured.count { |sql| sql.include?('FROM "reconciliation_exceptions"') }).to eq(1)
    expect(captured.length).to be <= one_count + 1
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it "keeps the acknowledged original pending operation checkable and rejects a new operation" do
    order = paid_order
    issue_for(order)
    refund = create(:refund, order: order, payment: order.payments.first, status: :pending,
      amount_cents: 1000, idempotency_key: "saved-original", provider_refund_id: "re_saved_original")
    allow(StripeService).to receive(:refund_payment)
    path = "/api/v1/organizer/events/#{event.id}/orders/#{order.id}/refund"

    expect(list.first.fetch("external_refund_verification_required")).to be(true)
    expect do
      post path, params: { amount_cents: 1000 }, headers: headers.merge("Idempotency-Key" => "saved-original")
    end.not_to change(Refund, :count)
    expect(response).to have_http_status(:created), response.body
    expect(response.parsed_body).to include("refund_id" => refund.id, "refund_status" => "pending", "finance_review_required" => true)
    expect do
      post path, params: { amount_cents: 1000 }, headers: headers.merge("Idempotency-Key" => "another-operation")
    end.not_to change(Refund, :count)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include("finance_review_required" => true)
    expect(refund.reload).to be_pending
    expect(StripeService).not_to have_received(:refund_payment)
  end
end
