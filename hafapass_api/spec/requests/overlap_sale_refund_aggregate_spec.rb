# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# A1-R1 recheck blocker 1 (docs/design/never-fulfilled-captures.md §6.8):
# 7bcd97c2's refund finalizer sums every same-mode refund on the order. With
# A's $13.60 sale fulfilled and a $7.00 refund recorded on a classified second
# payment B, its $6.60 refund on A would reach the order total, mark the sale
# fully refunded and cancel its tickets. The database refuses that order-wide
# aggregate for every writer once another payment on the order has a refund
# (orders_sale_refund_aggregate); the refused notice stays failed, and this
# release records the same exact partial return on A once, from Stripe's
# redelivery. An order whose refunds all come from its own payment keeps the
# old behaviour.
RSpec.describe "Sale refund total across releases", type: :request do
  include ActiveJob::TestHelper

  let(:organizer_profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: organizer_profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 1200, quantity_available: 10, quantity_sold: 0) }
  let(:promoter) { create(:promoter, event: event, commission_bps: 1000) }
  let(:legacy) { Legacy7bcd97c2.refund_creator }
  let(:posts) { [] }

  before do
    SiteSetting.instance.update!(payment_mode: "test")
    allow(StripeService).to receive_messages(card_only_intent?: true, payment_enabled?: true)
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(Sentry).to receive(:capture_message)
    allow(StripeService).to receive(:refund_payment) do |intent, amount_cents:, idempotency_key:, **|
      posts << [intent, amount_cents, idempotency_key]
      OpenStruct.new(id: "re_out_#{posts.length}", status: "succeeded", amount: amount_cents, currency: "usd",
        payment_intent: intent, metadata: { "hafapass_refund_key" => idempotency_key })
    end
  end

  def post_stripe_event(type, object, event_id:)
    post "/webhooks/stripe", params: { id: event_id, type: type, data: { object: object } }.to_json,
      headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:ok)
  end

  def succeed!(payment)
    post_stripe_event("payment_intent.succeeded", { id: payment.provider_payment_id, amount: payment.amount_cents,
      amount_received: payment.amount_cents, currency: "usd", status: "succeeded" }, event_id: "evt_agg_ok_#{payment.id}")
  end

  def refund_notice(payment, id, amount)
    { id: id, object: "refund", payment_intent: payment.provider_payment_id, amount: amount, currency: "usd", status: "succeeded" }
  end

  # A fulfilled $13.60 sale (one $12.00 ticket and its fee) paid by A, with a
  # promoter commission.
  def fulfilled_sale(intent: "pi_agg_a")
    allow(StripeService).to receive(:create_payment_intent).and_return(OpenStruct.new(id: intent,
      client_secret: "#{intent}_secret", allowed_payment_method_types: ["card"], payment_method_types: ["card"]))
    result = Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: "buyer@example.com", buyer_name: "Buyer")
    ReferralAttribution.create!(order: result.order, promoter: promoter, code_snapshot: promoter.code, attributed_at: Time.current)
    succeed!(result.payment)
    [result.order.reload, result.payment.reload]
  end

  # B captured after A fulfilled: classified in payment scope, and Stripe's
  # $7.00 refund on it recorded on B alone.
  def classified_second_capture_with_refund(order, a)
    b = order.payments.create!(provider: "stripe", provider_environment: "test",
      provider_platform_account_id: a.provider_platform_account_id, provider_payment_id: "pi_agg_b",
      idempotency_key: "second:#{order.id}", amount_cents: order.total_cents, currency: "usd", status: :pending)
    succeed!(b)
    expect(UnfulfilledCapture.find_by!(payment: b).capture_scope).to eq("payment")
    post_stripe_event("refund.created", refund_notice(b, "re_agg_b", 700), event_id: "evt_agg_b_refund")
    expect(Refund.find_by!(provider_refund_id: "re_agg_b")).to have_attributes(status: "succeeded", payment_id: b.id)
    b.reload
  end

  def sale(order)
    order.reload
    { status: order.status, refund_amount_cents: order.refund_amount_cents, tickets: order.tickets.order(:id).pluck(:status),
      sold: ticket_type.reload.quantity_sold, refund_items: RefundItem.joins(:refund).where(refunds: { order_id: order.id }).sum(:amount_cents),
      retentions: TicketInventoryRetention.joins(:ticket).where(tickets: { order_id: order.id }).count,
      commissions: order.promoter_commission_entries.order(:id).pluck(:kind, :amount_cents) }
  end

  it "refuses 7bcd97c2's inbound $6.60 refund on A, then records it once as a partial return from the redelivery" do
    order, a = fulfilled_sale
    expect(order.total_cents).to eq(1360)
    b = classified_second_capture_with_refund(order, a)
    before = sale(order)
    expect(before).to include(status: "completed", refund_amount_cents: 0, tickets: ["issued"], refund_items: 0)

    # The old release's webhook path for the same signed notice.
    observation = OpenStruct.new(id: "re_agg_a", status: "succeeded", amount: 660, currency: "usd",
      payment_intent: a.provider_payment_id, metadata: {})
    expect do
      legacy.call(order: order, payment: a, amount_cents: 660, reason: "provider_webhook_reconciliation",
        idempotency_key: "provider:stripe:refund:re_agg_a", provider_refund: observation)
    end.to raise_error(ActiveRecord::StatementInvalid, /Sale ownership: order #{order.id} refund total/)
    # Its inbound reservation (committed before finalization) stays pending,
    # keyed by the provider refund; nothing reached the sale.
    leftover = Refund.find_by!(idempotency_key: "provider:stripe:refund:re_agg_a")
    expect(leftover).to have_attributes(status: "pending", provider_refund_id: nil, payment_id: a.id)
    expect(sale(order)).to eq(before)
    expect(EmailService).not_to have_received(:send_refund_notification_async)

    # Stripe redelivers the notice; this release records A's exact partial
    # return: items, a proportional commission reversal, nothing cancelled.
    2.times { post_stripe_event("refund.created", refund_notice(a, "re_agg_a", 660), event_id: "evt_agg_a_refund") }
    refund = Refund.find_by!(provider_refund_id: "re_agg_a")
    expect(refund).to have_attributes(id: leftover.id, status: "succeeded", payment_id: a.id, amount_cents: 660)
    expect(ReconciliationException.where(order: order, code: StripeWebhookProcessor::ORPHAN_CODES)).to be_empty
    after = sale(order)
    expect(after).to include(status: "partially_refunded", refund_amount_cents: 660, tickets: ["issued"], sold: before[:sold],
      refund_items: 660, retentions: 0)
    expect(after[:commissions].map(&:first)).to eq(%w[earned refund_reversal])
    expect(after[:commissions].last.last.abs).to be < before[:commissions].first.last
    expect(Refund.where(order: order, status: :succeeded).pluck(:payment_id, :amount_cents))
      .to contain_exactly([b.id, 700], [a.id, 660])
    expect(EmailService).to have_received(:send_refund_notification_async).once
    expect(Commerce::RefundCreator.remaining_cents(order: order, payment: a)).to eq(700)
    expect(posts).to be_empty
  end

  it "refuses 7bcd97c2's outbound refund on A at finalization, and this release records it by its own key" do
    order, a = fulfilled_sale
    classified_second_capture_with_refund(order, a)
    before = sale(order)

    # The old remaining balance counts B's refund, so it offers $6.60; the
    # money leaves, its order-wide finalization is refused.
    expect do
      legacy.call(order: order, payment: a, amount_cents: 660, reason: "requested_by_customer",
        idempotency_key: "admin-agg-660", admin_initiated: true)
    end.to raise_error(ActiveRecord::StatementInvalid, /refund total would count another payment's refunds/)
    expect(posts.map { |row| row[1] }).to eq([660])
    row = Refund.find_by!(idempotency_key: "admin-agg-660")
    expect(row).to have_attributes(status: "pending", provider_refund_id: nil, failure_code: "provider_result_unknown")
    expect(sale(order)).to eq(before)

    # This release's resync finds it by its own key and records the partial.
    allow(StripeService).to receive(:find_refund) do |intent, idempotency_key:, **|
      OpenStruct.new(id: "re_out_1", status: "succeeded", amount: 660, currency: "usd", payment_intent: intent,
        metadata: { "hafapass_refund_key" => idempotency_key })
    end
    RefundReconciliationActions.call(type: "refund", id: row.id, action: "resync", actor: nil, system: true)
    expect(row.reload).to have_attributes(status: "succeeded", provider_refund_id: "re_out_1")
    expect(sale(order)).to include(status: "partially_refunded", refund_amount_cents: 660, tickets: ["issued"], refund_items: 660)
    expect(posts.length).to eq(1)
  end

  it "still lets the sale's own payment return the sale in full while B has a refund" do
    order, a = fulfilled_sale
    classified_second_capture_with_refund(order, a)

    post_stripe_event("refund.created", refund_notice(a, "re_agg_full", 1360), event_id: "evt_agg_full")

    expect(sale(order)).to include(status: "refunded", refund_amount_cents: 1360, tickets: ["cancelled"], refund_items: 1360)
  end

  it "keeps 7bcd97c2's ordinary single-payment behaviour, partial and full" do
    order, a = fulfilled_sale
    partial = OpenStruct.new(id: "re_agg_single_1", status: "succeeded", amount: 660, currency: "usd",
      payment_intent: a.provider_payment_id, metadata: {})
    legacy.call(order: order, payment: a, amount_cents: 660, reason: "provider_webhook_reconciliation",
      idempotency_key: "provider:stripe:refund:re_agg_single_1", provider_refund: partial)
    expect(sale(order)).to include(status: "partially_refunded", refund_amount_cents: 660, tickets: ["issued"])

    rest = OpenStruct.new(id: "re_agg_single_2", status: "succeeded", amount: 700, currency: "usd",
      payment_intent: a.provider_payment_id, metadata: {})
    legacy.call(order: order, payment: a, amount_cents: 700, reason: "provider_webhook_reconciliation",
      idempotency_key: "provider:stripe:refund:re_agg_single_2", provider_refund: rest)
    expect(sale(order)).to include(status: "refunded", refund_amount_cents: 1360, tickets: ["cancelled"])
  end

  it "refuses the same aggregate from raw SQL" do
    order, a = fulfilled_sale
    classified_second_capture_with_refund(order, a)

    expect { ActiveRecord::Base.transaction(requires_new: true) { Order.where(id: order.id).update_all(refund_amount_cents: 700) } }
      .to raise_error(ActiveRecord::StatementInvalid, /Sale ownership/)
    expect { ActiveRecord::Base.transaction(requires_new: true) { Order.where(id: order.id).update_all(status: Order.statuses[:refunded]) } }
      .to raise_error(ActiveRecord::StatementInvalid, /Sale ownership/)
    expect(order.reload).to have_attributes(status: "completed", refund_amount_cents: 0)
  end
end
