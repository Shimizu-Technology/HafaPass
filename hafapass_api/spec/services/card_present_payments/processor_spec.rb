require "rails_helper"

RSpec.describe CardPresentPayments::Processor do
  let(:user) { create(:user, :organizer) }
  let(:organizer_profile) { create(:organizer_profile, user: user) }
  let(:event) { create(:event, :published, organizer_profile: organizer_profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 2500) }
  let(:account) { create(:card_present_account, :verified, organization: event.organization) }
  let(:gateway) { instance_double(CardPresentGateway) }

  def pending_sale
    Commerce::OrderCreator.call(
      event: event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: "walkin@example.com",
      buyer_name: "Walk-in",
      user: user,
      payment_required: true,
      payment_provider: "boh_clover",
      service_fee: false,
      source: "box_office",
      payment_method: "door_card"
    )
  end

  it "issues the ticket only after an exact confirmed terminal result" do
    sale = pending_sale
    result = CardPresentGateway::Result.new(
      provider_payment_id: "clover-1",
      amount_cents: sale.order.total_cents,
      currency: "usd",
      state: "CLOSED",
      result: "SUCCESS",
      provider_response: { "id" => "clover-1", "result" => "SUCCESS", "state" => "CLOSED" }
    )
    allow(gateway).to receive(:charge).and_return(result)

    attempt = described_class.call(order: sale.order, payment: sale.payment, account: account, user: user,
      idempotency_key: "terminal-sale-1", gateway: gateway)

    expect(attempt).to be_status_succeeded
    expect(sale.order.reload).to be_completed
    expect(sale.order.tickets.count).to eq(1)
    expect(sale.payment.reload).to have_attributes(status: "succeeded", provider_payment_id: "clover-1")
  end

  it "keeps inventory reserved and opens reconciliation when the result is unknown" do
    sale = pending_sale
    original_expiry = sale.order.expires_at
    allow(gateway).to receive(:charge).and_raise(CardPresentGateway::ResultUnknown, "network timeout")

    expect do
      described_class.call(order: sale.order, payment: sale.payment, account: account, user: user,
        idempotency_key: "terminal-sale-unknown", gateway: gateway)
    end.to raise_error(described_class::ProcessingError, /network timeout/)

    attempt = CardPresentPaymentAttempt.find_by!(idempotency_key: "terminal-sale-unknown")
    expect(attempt).to be_status_result_unknown
    expect(sale.order.reload).to be_pending
    expect(sale.order.expires_at).to be > original_expiry
    expect(sale.order.inventory_holds).to all(be_active)
    expect(ReconciliationException.open).to exist(order: sale.order, payment: sale.payment, code: "card_present_result_unknown")
  end

  it "releases inventory after a known terminal failure" do
    sale = pending_sale
    allow(gateway).to receive(:charge).and_raise(CardPresentGateway::PaymentError, "cancelled")

    expect do
      described_class.call(order: sale.order, payment: sale.payment, account: account, user: user,
        idempotency_key: "terminal-sale-failed", gateway: gateway)
    end.to raise_error(described_class::ProcessingError, /cancelled/)

    expect(sale.order.reload).to be_cancelled
    expect(sale.payment.reload).to be_failed
    expect(sale.order.inventory_holds).to all(be_released)
  end

  it "replays a succeeded idempotency key without charging twice" do
    sale = pending_sale
    result = CardPresentGateway::Result.new(provider_payment_id: "clover-replay", amount_cents: sale.order.total_cents,
      currency: "usd", state: "CLOSED", result: "SUCCESS", provider_response: { "id" => "clover-replay" })
    allow(gateway).to receive(:charge).once.and_return(result)

    2.times do
      described_class.call(order: sale.order, payment: sale.payment, account: account, user: user,
        idempotency_key: "terminal-sale-replay", gateway: gateway)
    end

    expect(sale.order.reload.tickets.count).to eq(1)
  end
end
