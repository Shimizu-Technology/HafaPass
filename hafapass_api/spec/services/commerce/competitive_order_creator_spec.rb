require "rails_helper"

RSpec.describe Commerce::OrderCreator do
  let(:event) { create(:event, :published, fee_policy: :split_fees, buyer_fee_percent: 40) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 2000, quantity_available: 10) }
  let(:catalog_item) { create(:catalog_item, event: event, price_cents: 1000, inventory_quantity: 2) }
  let(:question) { create(:registration_question, event: event, prompt: "Dietary needs?") }
  let(:waiver) { create(:event_waiver, event: event) }
  let(:promoter) { create(:promoter, event: event, code: "ISLAND10", commission_bps: 1000) }

  def create_order(**overrides)
    described_class.call(**{
      event: event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      catalog_items: [{ catalog_item_id: catalog_item.id, quantity: 1 }],
      registration_answers: { question.id.to_s => "Vegetarian" },
      waiver_acceptances: [{ event_waiver_id: waiver.id, version: waiver.version }],
      referral_code: promoter.code,
      attribution: { source: "partner", campaign: "summer" },
      buyer_email: "buyer@example.com",
      buyer_name: "Buyer",
      payment_required: false
    }.merge(overrides))
  end

  it "keeps fees, catalog revenue, consent, attribution, and commission in one completed ledger" do
    result = create_order
    order = result.order.reload

    expect(order).to be_completed
    expect(order.subtotal_cents).to eq(3000)
    expect(order.service_fee_cents).to eq(44)
    expect(order.organizer_fee_cents).to eq(66)
    expect(order.total_cents).to eq(3044)
    expect(order.order_items.pluck(:item_kind)).to contain_exactly("ticket", "add_on")
    expect(order.catalog_item_holds.first).to be_consumed
    expect(catalog_item.reload.quantity_sold).to eq(1)
    expect(order.registration_responses.first.answer).to eq("value" => "Vegetarian")
    expect(order.registration_responses.first).to have_attributes(required_snapshot: true, options_snapshot: [])
    expect(order.waiver_acceptances.first.content_digest).to eq(waiver.content_digest)
    expect(order.referral_attribution.code_snapshot).to eq("ISLAND10")
    expect(order.promoter_commission_entries.earned.first.amount_cents).to eq(293)
    expect(order.fee_components.find_by!(kind: "platform").metadata).to include(
      "buyer_paid_cents" => 44, "organizer_absorbed_cents" => 66
    )
    expect(waiver.update(body: "Rewritten after acceptance")).to be(false)
    expect(waiver.errors.full_messages.join).to include("create a new version")
  end

  it "rejects checkout before creating an order when required registration or waiver consent is missing" do
    expect do
      create_order(registration_answers: {}, waiver_acceptances: [])
    end.to raise_error(described_class::CheckoutError, /Invalid answer/)
    expect(Order.count).to eq(0)
  end

  it "converts an inventory-reserving waitlist offer exactly once" do
    ticket_type.update!(quantity_available: 1)
    entry = create(:waitlist_entry, event: event, ticket_type: ticket_type, email: "buyer@example.com", quantity: 1)
    offer = create(:waitlist_offer, waitlist_entry: entry, event: event, ticket_type: ticket_type, quantity: 1)
    token = WaitlistCredential.offer(offer)

    result = create_order(catalog_items: [], waitlist_offer_token: token)

    expect(result.order.waitlist_offer.reload).to be_converted
    expect(entry.reload).to be_converted
    expect(WaitlistCredential.find_offer(token)).to be_nil
    expect do
      create_order(catalog_items: [], waitlist_offer_token: token)
    end.to raise_error(described_class::CheckoutError, /invalid or expired/)
  end

  it "releases catalog inventory and requeues a claimed waitlist entry when a pending order expires" do
    allow(StripeService).to receive(:create_payment_intent).and_return(double(id: "pi_phase8", client_secret: "secret"))
    entry = create(:waitlist_entry, event: event, ticket_type: ticket_type, email: "buyer@example.com")
    offer = create(:waitlist_offer, waitlist_entry: entry, event: event, ticket_type: ticket_type)
    result = create_order(waitlist_offer_token: WaitlistCredential.offer(offer), payment_required: true)
    result.order.update!(expires_at: 1.minute.ago)

    expect(Commerce::OrderLifecycle.expire!(result.order)).to be(true)
    expect(result.order.catalog_item_holds.first.reload).to be_expired
    expect(offer.reload).to be_expired
    expect(entry.reload).to be_waiting
  end

  it "fully reverses buyer and organizer fee shares, catalog inventory, and promoter commission on refund" do
    order = create_order.order
    refund = Commerce::RefundCreator.call(order: order, idempotency_key: "phase8-full-refund")

    expect(refund.refund_items.sum(:amount_cents)).to eq(order.total_cents)
    expect(refund.refund_items.sum(:fee_cents)).to eq(order.service_fee_cents)
    expect(refund.refund_items.sum(:organizer_fee_cents)).to eq(order.organizer_fee_cents)
    expect(catalog_item.reload.quantity_sold).to eq(0)
    expect(order.promoter_commission_entries.sum(:amount_cents)).to eq(0)
    expect(Commerce::LedgerTotals.call(Order.where(id: order.id))).to include(
      net_cents: 0, fee_cents: 0, organizer_proceeds_cents: 0
    )
  end
end
