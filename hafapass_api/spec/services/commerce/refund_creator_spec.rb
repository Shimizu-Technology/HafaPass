require "rails_helper"

RSpec.describe Commerce::RefundCreator do
  let(:event) { create(:event, :published, starts_at: 5.days.from_now) }
  let(:ticket_type) { create(:ticket_type, event: event, quantity_sold: 2) }
  let(:order) do
    create(:order, event: event, total_cents: 5250, subtotal_cents: 5000, service_fee_cents: 250)
  end
  let!(:item) do
    create(
      :order_item,
      order: order,
      ticket_type: ticket_type,
      unit_price_cents: 2500,
      quantity: 2,
      subtotal_cents: 5000,
      fee_cents: 250,
      organizer_proceeds_cents: 5000
    )
  end
  let!(:payment) do
    create(:payment, :succeeded, order: order, amount_cents: 5250, provider_payment_id: "sim_pi_refunds")
  end

  before do
    2.times { create(:ticket, order: order, order_item: item, event: event, ticket_type: ticket_type) }
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(event).to receive(:notify_waitlist_if_available)
  end

  it "records multiple partial refunds as additive item allocations" do
    first = described_class.call(order: order, amount_cents: 1000, reason: "first", idempotency_key: "refund-one")
    second = described_class.call(order: order, amount_cents: 500, reason: "second", idempotency_key: "refund-two")

    expect(first).to be_succeeded
    expect(second).to be_succeeded
    expect(order.reload).to be_partially_refunded
    expect(order.refunded_cents).to eq(1500)
    expect(order.refunds.count).to eq(2)
    expect(order.refunds.joins(:refund_items).sum("refund_items.amount_cents")).to eq(1500)
    expect(payment.reload).to be_partially_refunded
  end

  it "returns the original refund for a repeated idempotency key" do
    first = described_class.call(order: order, amount_cents: 1000, idempotency_key: "same-refund")

    expect do
      second = described_class.call(order: order, amount_cents: 1000, idempotency_key: "same-refund")
      expect(second.id).to eq(first.id)
    end.not_to change(Refund, :count)
  end

  it "finalizes an existing pending refund during provider reconciliation" do
    pending = create(
      :refund,
      order: order,
      payment: payment,
      amount_cents: 1000,
      currency: order.currency,
      status: :pending,
      idempotency_key: "original-refund"
    )

    expect do
      result = described_class.reconcile_provider_total!(
        order: order,
        payment: payment,
        amount_cents: 1000,
        provider_refund_id: "re_webhook",
        idempotency_key: "webhook-refund"
      )
      expect(result.id).to eq(pending.id)
      expect(result).to be_succeeded
      expect(result.provider_refund_id).to eq("re_webhook")
    end.not_to change(Refund, :count)
  end

  it "preserves an unrelated refund validation failure" do
    allow_any_instance_of(Refund).to receive(:save!).and_raise(
      ActiveRecord::RecordInvalid.new(Refund.new)
    )

    expect do
      described_class.call(order: order, amount_cents: 1000, idempotency_key: "invalid-refund")
    end.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "passes the local refund idempotency key to Stripe" do
    payment.update!(provider_payment_id: "pi_real_refund")
    allow(StripeService).to receive(:refund_payment).and_return(
      OpenStruct.new(id: "re_provider", status: "succeeded")
    )

    described_class.call(order: order, amount_cents: 1000, idempotency_key: "provider-refund-key")

    expect(StripeService).to have_received(:refund_payment).with(
      "pi_real_refund",
      amount_cents: 1000,
      reason: nil,
      idempotency_key: "provider-refund-key"
    )
  end

  it "prevents committed refunds from exceeding the order under serialized requests" do
    described_class.call(order: order, amount_cents: 5000, idempotency_key: "almost-all")

    expect do
      described_class.call(order: order, amount_cents: 251, idempotency_key: "too-much")
    end.to raise_error(described_class::RefundError, /exceeds refundable balance/)
  end

  it "fully refunds, cancels tickets, and releases sold inventory" do
    refund = described_class.call(order: order, amount_cents: 5250, reason: "cancelled event")

    expect(refund).to be_succeeded
    expect(order.reload).to be_refunded
    expect(order.tickets.reload).to all(be_cancelled)
    expect(ticket_type.reload.quantity_sold).to eq(0)
    expect(payment.reload).to be_refunded
  end

  it "refunds and revokes only the selected unused ticket" do
    selected, remaining = order.tickets.order(:id).to_a
    old_scan = selected.scan_credential

    refund = described_class.call(order: order, tickets: [selected], reason: "buyer choice", idempotency_key: "one-ticket")

    expect(refund).to be_succeeded
    expect(refund.amount_cents).to eq(2625)
    expect(refund.tickets).to contain_exactly(selected)
    expect(selected.reload).to be_cancelled
    expect(remaining.reload).to be_issued
    expect(order.reload).to be_partially_refunded
    expect(ticket_type.reload.quantity_sold).to eq(1)
    expect(TicketCredential.find_scan(old_scan)).to be_nil
  end

  it "rejects a selective refund for a used ticket before contacting the provider" do
    used = order.tickets.first
    used.update!(status: :checked_in, checked_in_at: Time.current)
    allow(StripeService).to receive(:refund_payment)

    expect do
      described_class.call(order: order, tickets: [used], idempotency_key: "used-ticket")
    end.to raise_error(described_class::RefundError, /unused active/)

    expect(StripeService).not_to have_received(:refund_payment)
  end
end
