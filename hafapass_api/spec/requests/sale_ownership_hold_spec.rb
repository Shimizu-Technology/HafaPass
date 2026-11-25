# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# A1-R1 review finding 1 (docs/design/never-fulfilled-captures.md §6.7): a
# refund or lost dispute on a payment that does not positively own the sale
# is recorded as a provider fact, but never changes the sale paid by another
# payment, never uses its balances, and holds the event until ownership or
# classification is decided. The held effects are replayed exactly once when
# ownership is proven, and closed without effect when the payment is
# classified as a payment-scope capture. Database guards refuse the same
# sale effects from any writer, including the 7bcd97c2 release.
RSpec.describe "Sale ownership holds", type: :request do
  include ActiveJob::TestHelper

  let(:organizer_profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: organizer_profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 1200, quantity_available: 10, quantity_sold: 0) }
  let(:promoter) { create(:promoter, event: event, commission_bps: 1000) }
  let(:admin) { create(:user, :admin) }

  before do
    SiteSetting.instance.update!(payment_mode: "test")
    allow(StripeService).to receive(:card_only_intent?).and_return(true)
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(Sentry).to receive(:capture_message)
    allow(StripeService).to receive(:refund_payment).and_raise("no outbound refund in these examples")
  end

  def post_stripe_event(type, object, event_id: "evt_own_#{SecureRandom.hex(4)}")
    post "/webhooks/stripe", params: { id: event_id, type: type, data: { object: object } }.to_json,
      headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:ok)
  end

  def succeed!(payment)
    post_stripe_event("payment_intent.succeeded", { id: payment.provider_payment_id, amount: payment.amount_cents,
      amount_received: payment.amount_cents, currency: "usd", status: "succeeded" })
  end

  def provider_refund!(payment, id, amount)
    post_stripe_event("refund.created", { id: id, object: "refund", payment_intent: payment.provider_payment_id,
      amount: amount, currency: "usd", status: "succeeded" })
  end

  def lose_dispute!(payment, id, amount: payment.amount_cents)
    object = { id: id, payment_intent: payment.provider_payment_id, amount: amount, currency: "usd",
      status: "needs_response", reason: "fraudulent" }
    post_stripe_event("charge.dispute.created", object)
    post_stripe_event("charge.dispute.closed", object.merge(status: "lost"))
    Dispute.find_by!(provider_dispute_id: id)
  end

  # A fulfilled two-ticket sale paid by A, with a promoter commission.
  def fulfilled_sale
    allow(StripeService).to receive(:create_payment_intent).and_return(OpenStruct.new(id: "pi_own_a",
      client_secret: "pi_own_a_secret", allowed_payment_method_types: ["card"], payment_method_types: ["card"]))
    result = Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: ticket_type.id, quantity: 2 }],
      buyer_email: "buyer@example.com", buyer_name: "Buyer")
    ReferralAttribution.create!(order: result.order, promoter: promoter, code_snapshot: promoter.code, attributed_at: Time.current)
    succeed!(result.payment)
    [result.order.reload, result.payment.reload]
  end

  def second_payment(order, a, status: :pending, intent: "pi_own_b")
    order.payments.create!(provider: "stripe", provider_environment: "test",
      provider_platform_account_id: a.provider_platform_account_id, provider_payment_id: intent,
      idempotency_key: "second:#{order.id}:#{intent}", amount_cents: 1500, currency: "usd", status: status)
  end

  def sale_snapshot(order)
    order.reload
    { status: order.status, refund_amount_cents: order.refund_amount_cents, refunded_cents: order.refunded_cents,
      refundable_cents: order.refundable_cents, tickets: order.tickets.order(:id).pluck(:id, :status),
      sold: ticket_type.reload.quantity_sold, refund_items: RefundItem.joins(:refund).where(refunds: { order_id: order.id }).count,
      commissions: order.promoter_commission_entries.order(:id).pluck(:kind, :amount_cents),
      blocked: order.ticket_access_blocked?, remaining_a: Commerce::RefundCreator.remaining_cents(order: order, payment: order.payments.order(:id).first) }
  end

  def holds(order)
    ReconciliationException.where(order: order, code: Commerce::SaleEffectHold::CODE)
  end

  it "keeps a lost dispute on B, before B's capture is recorded, off A's tickets and admission, then closes it at classification" do
    order, a = fulfilled_sale
    b = second_payment(order, a)
    before = sale_snapshot(order)

    dispute = lose_dispute!(b, "dp_own_b")

    expect(dispute.reload).to have_attributes(status: "lost", payment_id: b.id)
    expect(sale_snapshot(order)).to eq(before)
    expect(order.tickets).to all(be_issued)
    expect(order.ticket_access_blocked?).to be(false)
    hold = holds(order).sole
    expect(hold).to be_open
    expect(hold.details).to include("source_type" => "Dispute", "source_id" => dispute.id, "reason" => "not_fulfilling_payment")
    expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(true)

    # B is captured and classified in payment scope: its loss posts on B's
    # own ledger and the hold closes without touching the sale.
    expect { succeed!(b) }.to have_enqueued_job(SaleEffectHoldJob).with(order.id)
    perform_enqueued_jobs(only: SaleEffectHoldJob)

    capture = UnfulfilledCapture.find_by!(payment: b)
    expect(capture.capture_scope).to eq("payment")
    expect(posting_rows(capture)).to eq([["dispute_loss", 1500, 1500, 0, [1500, 0, 0, 0]]])
    expect(hold.reload).to be_resolved
    expect(AuditLog.find_by!(auditable: hold, action: "never_fulfilled_capture.sale_effects_released").metadata)
      .to include("outcome" => "isolated", "source_id" => dispute.id)
    expect(sale_snapshot(order)).to eq(before)
  end

  it "records a refund on an unclassified captured B without using A's balances, and holds payouts" do
    order, a = fulfilled_sale
    b = second_payment(order, a, status: :succeeded)
    before = sale_snapshot(order)

    provider_refund!(b, "re_own_b", 700)

    refund = Refund.find_by!(provider_refund_id: "re_own_b")
    expect(refund).to have_attributes(status: "succeeded", payment_id: b.id, amount_cents: 700)
    expect(b.reload).to be_partially_refunded
    expect(sale_snapshot(order)).to eq(before)
    expect(EmailService).not_to have_received(:send_refund_notification_async)
    expect(holds(order).sole.details).to include("source_type" => "Refund", "source_id" => refund.id)
    expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(true)
    expect(Settlements::Calculator.call(event).attributes[:refund_cents]).to eq(0)

    # Nothing decides ownership yet: the job leaves it held.
    expect(Commerce::SaleEffectHold.release!(order)).to eq(holds(order).sole.id => "held")
  end

  it "replays a held refund exactly once when a legacy order's fulfilling payment is proven, and keeps B's held loss" do
    order, a = fulfilled_sale
    # A legacy order: completed before A1 recorded its fulfilling payment.
    ActiveRecord::Base.connection.execute("ALTER TABLE orders DISABLE TRIGGER orders_fulfillment_guard")
    Order.where(id: order.id).update_all(fulfilled_by_payment_id: nil)
    ActiveRecord::Base.connection.execute("ALTER TABLE orders ENABLE TRIGGER orders_fulfillment_guard")
    b = second_payment(order, a, status: :succeeded)
    ReconciliationException.create!(order: order, payment: b, code: Commerce::NeverFulfilledClassification::OWNERSHIP_AMBIGUOUS_CODE,
      details: { reason: "no_completion_evidence" })
    before = sale_snapshot(order)

    provider_refund!(a, "re_own_a", 1200)
    loss = lose_dispute!(b, "dp_own_b2")

    refund = Refund.find_by!(provider_refund_id: "re_own_a")
    expect(refund).to be_succeeded
    # Nothing acts on the sale. With no fulfilling payment recorded, the
    # reversible readers stay conservative: every refund counts against the
    # remaining balance, and a lost dispute blocks admission order-wide.
    conservative = %i[blocked refunded_cents refundable_cents remaining_a]
    expect(sale_snapshot(order).except(*conservative)).to eq(before.except(*conservative))
    expect(sale_snapshot(order)).to include(blocked: true, refunded_cents: 1200, refundable_cents: before[:refundable_cents] - 1200)
    expect(order.tickets).to all(be_issued)
    expect(holds(order).map { |issue| issue.details.values_at("source_type", "reason") })
      .to contain_exactly(["Refund", "ownership_unproven"], ["Dispute", "ownership_unproven"])

    # Positive completion evidence later names A.
    order.update!(fulfilled_by_payment_id: a.id)
    outcomes = Commerce::SaleEffectHold.release!(order)
    expect(outcomes.values).to contain_exactly("applied", "held")

    order.reload
    expect(order).to have_attributes(status: "partially_refunded", refund_amount_cents: 1200)
    expect(RefundItem.where(refund: refund).sum(:amount_cents)).to eq(1200)
    expect(order.promoter_commission_entries.refund_reversal.count).to eq(1)
    expect(EmailService).to have_received(:send_refund_notification_async).once
    expect(order.tickets).to all(be_issued) # B's loss is not the sale's
    expect(holds(order).open.sole.details).to include("source_type" => "Dispute", "source_id" => loss.id)

    # Exactly once.
    expect { Commerce::SaleEffectHold.release!(order) }
      .not_to(change { [RefundItem.count, PromoterCommissionEntry.count, order.reload.status] })
    expect(EmailService).to have_received(:send_refund_notification_async).once
  end

  it "refuses every sale effect of a non-owning payment in the database, for old and new writers alike" do
    order, a = fulfilled_sale
    b = second_payment(order, a, status: :succeeded)
    provider_refund!(b, "re_own_db", 500)
    refund = Refund.find_by!(provider_refund_id: "re_own_db")
    dispute = Dispute.create!(order: order, payment: b, provider: "stripe", provider_dispute_id: "dp_own_db",
      amount_cents: 1500, currency: "usd", status: :lost, opened_at: 1.day.ago, closed_at: Time.current)
    ticket = order.tickets.order(:id).first
    item = order.order_items.first

    savepoint = ->(&block) { expect { ActiveRecord::Base.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, /Sale ownership/) }
    savepoint.call { RefundItem.create!(refund: refund, order_item: item, amount_cents: 100, organizer_proceeds_cents: 100, fee_cents: 0, organizer_fee_cents: 0, tax_cents: 0, quantity: 0) }
    savepoint.call do
      refund.promoter_commission_entries.create!(promoter: promoter, order: order, kind: :refund_reversal, amount_cents: -10,
        currency: "usd", idempotency_key: "commission:refund:#{refund.id}", occurred_at: Time.current)
    end
    savepoint.call { Commerce::FinancialReversalInventory.call(ticket: ticket, dispute: dispute, reason: "payment_dispute_lost") }
    savepoint.call { Ticket.where(id: ticket.id).update_all(status: Ticket.statuses[:cancelled], cancellation_reason: "payment_dispute_lost") }
    expect(ticket.reload).to be_issued

    # The 7bcd97c2 refund writer finalizing an inbound refund on B: its sale
    # path rolls back whole, and the provider fact stays in the receipt.
    legacy = Legacy7bcd97c2.refund_creator
    observation = OpenStruct.new(id: "re_own_legacy", status: "succeeded", amount: 300, currency: "usd",
      payment_intent: b.provider_payment_id, metadata: {})
    expect do
      legacy.call(order: order, payment: b, amount_cents: 300, reason: "provider_webhook_reconciliation",
        idempotency_key: "provider:stripe:refund:re_own_legacy", provider_refund: observation)
    end.to raise_error(ActiveRecord::StatementInvalid, /Sale ownership/)
    expect(Refund.where(provider_refund_id: "re_own_legacy")).to be_empty
    expect(RefundItem.joins(:refund).where(refunds: { order_id: order.id }).count).to eq(0)
    expect(order.reload).to be_completed
  end

  it "closes a sale-effect hold only through its evidence path, never by a note" do
    order, a = fulfilled_sale
    b = second_payment(order, a, status: :succeeded)
    provider_refund!(b, "re_own_note", 500)
    hold = holds(order).sole
    sign_in_as(admin) if respond_to?(:sign_in_as)

    expect { ActiveRecord::Base.transaction(requires_new: true) { hold.resolve! } }
      .to raise_error(ActiveRecord::StatementInvalid, /Evidence hold/)
    expect(hold.reload).to be_open
    controller = Api::V1::Admin::ReconciliationExceptionsController.new
    expect(controller.send(:resolution_rule, hold)[:blocked]).to match(/a note cannot close it/)
  end
end
