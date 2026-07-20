require "rails_helper"

RSpec.describe "Commerce order lifecycle" do
  let(:organizer_profile) { create(:organizer_profile) }
  let(:event) do
    create(:event, :published, organizer_profile: organizer_profile, starts_at: 5.days.from_now, max_capacity: 10)
  end
  let(:ticket_type) do
    create(:ticket_type, event: event, name: "Launch GA", price_cents: 2500, quantity_available: 10, max_per_order: 10)
  end

  before do
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(EmailService).to receive(:send_ticket_email_async)
  end

  def create_pending_order(quantity: 1, promo_code_id: nil, intent_id: "pi_#{SecureRandom.hex(4)}")
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:create_payment_intent).and_return(
      OpenStruct.new(id: intent_id, client_secret: "#{intent_id}_secret")
    )

    Commerce::OrderCreator.call(
      event: event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: quantity }],
      buyer_email: "buyer@example.com",
      buyer_name: "Buyer",
      promo_code_id: promo_code_id
    )
  end

  it "creates immutable item snapshots and expiring holds without claiming sold inventory" do
    result = create_pending_order(quantity: 2)
    item = result.order.order_items.first

    expect(result.order).to be_pending
    expect(item).to have_attributes(name: "Launch GA", unit_price_cents: 2500, quantity: 2, subtotal_cents: 5000)
    expect(result.order.inventory_holds.first).to be_active
    expect(ticket_type.reload.quantity_sold).to eq(0)
    expect(ticket_type.available_quantity).to eq(8)
    expect(result.order.tickets).to be_empty

    ticket_type.update!(name: "Renamed", price_cents: 9000)
    expect(item.reload).to have_attributes(name: "Launch GA", unit_price_cents: 2500)
    expect(item.update(name: "Tampered")).to be(false)
  end

  it "uses the durable local payment idempotency key for the provider call" do
    create_pending_order(intent_id: "pi_idempotent")

    expect(StripeService).to have_received(:create_payment_intent).with(
      an_instance_of(Order),
      idempotency_key: match(/payment:order:/)
    )
  end

  it "finalizes inventory and issues each entitlement exactly once" do
    result = create_pending_order(quantity: 2)

    expect do
      Commerce::OrderLifecycle.complete!(
        result.order,
        payment: result.payment,
        provider_amount_cents: result.payment.amount_cents,
        provider_currency: "usd"
      )
    end.to change(Ticket, :count).by(2)

    expect(result.order.reload).to be_completed
    expect(result.payment.reload).to be_succeeded
    expect(result.order.inventory_holds).to all(be_consumed)
    expect(ticket_type.reload.quantity_sold).to eq(2)
    expect(result.order.tickets.pluck(:qr_code)).to all(be_present)

    expect do
      Commerce::OrderLifecycle.complete!(
        result.order,
        payment: result.payment,
        provider_amount_cents: result.payment.amount_cents,
        provider_currency: "usd"
      )
    end.not_to change(Ticket, :count)
  end

  it "quarantines provider amount and currency mismatches without issuing inventory" do
    result = create_pending_order

    expect do
      Commerce::OrderLifecycle.complete!(
        result.order,
        payment: result.payment,
        provider_amount_cents: result.payment.amount_cents + 1,
        provider_currency: "eur"
      )
    end.to change(ReconciliationException, :count).by(1)

    expect(result.order.reload).to be_pending
    expect(result.payment.reload).to be_pending
    expect(result.order.tickets).to be_empty
    expect(ticket_type.reload.quantity_sold).to eq(0)
  end

  it "records late payment success after an expired hold instead of overselling" do
    result = create_pending_order
    allow(StripeService).to receive(:cancel_payment_intent).and_return(
      OpenStruct.new(id: result.payment.provider_payment_id, status: "canceled")
    )
    result.order.update_columns(expires_at: 1.minute.ago)
    result.order.inventory_holds.update_all(expires_at: 1.minute.ago)

    ExpireInventoryHoldsJob.perform_now(Time.current)
    expect(result.order.reload).to be_expired
    expect(StripeService).to have_received(:cancel_payment_intent).with(
      result.payment.provider_payment_id,
      idempotency_key: "cancel:payment:#{result.payment.id}"
    )

    expect do
      Commerce::OrderLifecycle.complete!(
        result.order,
        payment: result.payment,
        provider_amount_cents: result.payment.amount_cents,
        provider_currency: "usd"
      )
    end.to change(ReconciliationException, :count).by(1)

    expect(result.order.reload).to be_expired
    expect(result.payment.reload).to be_succeeded
    expect(ticket_type.reload.quantity_sold).to eq(0)
  end

  it "enforces event capacity across ticket types using active holds" do
    event.update!(max_capacity: 1)
    other_type = create(:ticket_type, event: event, quantity_available: 10, max_per_order: 10)
    create_pending_order

    expect do
      Commerce::OrderCreator.call(
        event: event,
        line_items: [{ ticket_type_id: other_type.id, quantity: 1 }],
        buyer_email: "other@example.com",
        buyer_name: "Other"
      )
    end.to raise_error(Commerce::OrderCreator::CheckoutError, /event capacity/)
  end

  it "reserves, releases, and finalizes limited and unlimited promo uses" do
    limited = create(:promo_code, event: event, code: "ONLYONE", max_uses: 1, discount_type: "fixed", discount_value: 500)
    first = create_pending_order(promo_code_id: limited.id)
    expect(first.order.promo_redemption).to be_reserved

    expect do
      create_pending_order(promo_code_id: limited.id)
    end.to raise_error(Commerce::OrderCreator::CheckoutError, /no longer available/)

    Commerce::OrderLifecycle.cancel!(first.order)
    expect(first.order.promo_redemption.reload).to be_released

    third = create_pending_order(promo_code_id: limited.id)
    Commerce::OrderLifecycle.complete!(
      third.order,
      payment: third.payment,
      provider_amount_cents: third.payment.amount_cents,
      provider_currency: "usd"
    )
    expect(limited.reload.current_uses).to eq(1)
    expect(third.order.promo_redemption.reload).to be_finalized

    unlimited = create(:promo_code, event: event, code: "OPEN", max_uses: nil, discount_type: "fixed", discount_value: 100)
    unlimited_order = create_pending_order(promo_code_id: unlimited.id)
    Commerce::OrderLifecycle.complete!(
      unlimited_order.order,
      payment: unlimited_order.payment,
      provider_amount_cents: unlimited_order.payment.amount_cents,
      provider_currency: "usd"
    )
    expect(unlimited.reload.current_uses).to eq(1)
  end
end
