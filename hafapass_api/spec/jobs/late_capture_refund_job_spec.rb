# frozen_string_literal: true

require "rails_helper"

RSpec.describe LateCaptureRefundJob do
  include ActiveJob::TestHelper

  let(:event) { create(:event, :published, starts_at: 5.days.from_now) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 2500, quantity_available: 10) }
  let(:refunds) { [] }

  before do
    SiteSetting.instance.update!(payment_mode: "test")
    allow(StripeService).to receive_messages(payment_enabled?: true, card_only_intent?: true)
    allow(StripeService).to receive(:create_payment_intent).and_return(OpenStruct.new(id: "pi_late_#{SecureRandom.hex(4)}", client_secret: "secret"))
    allow(StripeService).to receive(:cancel_payment_intent).and_return(OpenStruct.new(status: "canceled"))
    allow(StripeService).to receive(:refund_payment) do |intent_id, amount_cents:, reason:, idempotency_key:, payment:|
      refunds << { intent_id: intent_id, amount_cents: amount_cents, reason: reason, idempotency_key: idempotency_key }
      OpenStruct.new(id: "re_late_#{refunds.length}", status: "succeeded", amount: amount_cents, currency: "usd",
        payment_intent: intent_id, metadata: { "hafapass_refund_key" => idempotency_key })
    end
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(Sentry).to receive(:capture_message)
  end

  # A buyer pays after HåfaPass released the order: the success webhook
  # records the late capture and enqueues this job.
  def late_capture
    result = Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: ticket_type.id, quantity: 2 }],
      buyer_email: "late@example.com", buyer_name: "Late Buyer")
    Commerce::OrderLifecycle.cancel!(result.order)
    expect do
      Commerce::OrderLifecycle.complete!(result.order, payment: result.payment,
        provider_amount_cents: result.payment.amount_cents, provider_currency: "usd")
    end.to have_enqueued_job(described_class).with(result.payment.id)
    [result.order.reload, result.payment.reload]
  end

  it "refunds the whole late payment once, emails the buyer and resolves the exception with an audit note" do
    order, payment = late_capture
    issue = ReconciliationException.find_by!(order: order, code: "late_payment_success_after_inventory_release")

    2.times { described_class.perform_now(payment.id) }

    expect(refunds).to eq([{ intent_id: payment.provider_payment_id, amount_cents: payment.amount_cents,
      reason: "late_capture_refund", idempotency_key: "late-capture:payment:#{payment.id}" }])
    refund = order.refunds.sole
    expect(refund).to have_attributes(status: "succeeded", reason: "late_capture_refund", amount_cents: payment.amount_cents)
    expect(order.reload).to be_refunded
    expect(payment.reload).to be_refunded
    expect(issue.reload).to be_resolved
    audit = AuditLog.find_by!(auditable: issue, action: "reconciliation_exception.resolved")
    expect(audit.metadata).to include("refund_id" => refund.id, "code" => "late_payment_success_after_inventory_release")
    expect(MessageDelivery.where(order: order, template: "refund_notification").count).to eq(1)
    expect(Sentry).to have_received(:capture_message).with(/refunding automatically/, hash_including(level: :warning)).once
    expect(ticket_type.reload.quantity_sold).to eq(0)
  end

  it "writes the buyer email for an expired hold rather than a generic refund" do
    order, payment = late_capture
    described_class.perform_now(payment.id)
    delivery = MessageDelivery.find_by!(order: order, template: "refund_notification")
    payload = EmailService.prepare_delivery_payload(delivery)
    amount = UsdMoney.format_cents(payment.amount_cents)
    expect(payload.fetch("subject")).to eq("Your payment of #{amount} was refunded — #{event.title}")
    expect(payload.fetch("html")).to include("Your payment was refunded", "Your ticket hold for",
      "We refunded your payment of #{amount} in full")
    expect(payload.fetch("html")).not_to include("late_capture_refund", "Refund Processed")
  end

  it "does nothing without an open late-capture exception or for simulated payments" do
    order, payment = late_capture
    ReconciliationException.where(order: order).find_each(&:resolve!)
    described_class.perform_now(payment.id)
    described_class.perform_now(0)
    expect(refunds).to be_empty
  end

  it "keeps the exception open for finance review when another financial exception blocks the refund" do
    order, payment = late_capture
    create(:reconciliation_exception, order: order, payment: payment, code: "payment_amount_mismatch")

    perform_enqueued_jobs { described_class.perform_later(payment.id) }

    expect(refunds).to be_empty
    expect(ReconciliationException.open.where(order: order, code: Commerce::LateCaptureRefund::CODES)).to exist
    expect(Sentry).to have_received(:capture_message).with(/finance review required/, hash_including(level: :error))
  end
end
