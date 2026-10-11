require "rails_helper"
require "ostruct"

RSpec.describe Commerce::OrderCreator do
  let(:event) { create(:event, :published) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 1000) }

  it "blocks internal and box-office checkout in production without current pilot readiness" do
    allow(Rails.env).to receive(:production?).and_return(true)

    expect do
      described_class.call(
        event: event,
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
        buyer_email: "walkin@example.com",
        buyer_name: "Walk-in",
        payment_required: false,
        source: "box_office",
        payment_method: "door_cash"
      )
    end.to raise_error(described_class::CheckoutError, /current pilot readiness approval/)

    expect(event.orders).to be_empty
  end

  it "blocks every commerce channel in production without current Gate F validation" do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(event).to receive(:production_release_gate_status).and_return(:pilot_validation)

    expect do
      described_class.call(
        event: event,
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
        buyer_email: "walkin@example.com",
        buyer_name: "Walk-in",
        payment_required: false,
        source: "box_office",
        payment_method: "door_cash"
      )
    end.to raise_error(described_class::CheckoutError, /current Gate F validation approval/)

    expect(event.orders).to be_empty
  end

  it "blocks every commerce channel in production without current Gate G rehearsal approval" do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(event).to receive(:production_release_gate_status).and_return(:event_day_rehearsal)

    expect do
      described_class.call(
        event: event,
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
        buyer_email: "walkin@example.com",
        buyer_name: "Walk-in",
        payment_required: false,
        source: "box_office",
        payment_method: "door_cash"
      )
    end.to raise_error(described_class::CheckoutError, /current Gate G rehearsal approval/)

    expect(event.orders).to be_empty
  end

  it "blocks every commerce channel without Gate I approval or an active pilot sales window" do
    allow(Rails.env).to receive(:production?).and_return(true)
    call = lambda do
      described_class.call(
        event: event,
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
        buyer_email: "walkin@example.com", buyer_name: "Walk-in",
        payment_required: false, source: "box_office", payment_method: "door_cash"
      )
    end

    allow(event).to receive(:production_release_gate_status).and_return(:live_pilot)
    expect(&call).to raise_error(described_class::CheckoutError, /current Gate I bounded-pilot approval/)
    allow(event).to receive(:production_release_gate_status).and_return(:live_pilot_operation)
    expect(&call).to raise_error(described_class::CheckoutError, /sales window is not active/)
    expect(event.orders).to be_empty
  end

  it "rejects checkout for events that ended or are no longer published" do
    allow(StripeService).to receive(:payment_enabled?).and_return(false)
    checkout = lambda do
      described_class.call(
        event: event,
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
        buyer_email: "buyer@example.com",
        buyer_name: "Buyer"
      )
    end

    event.update!(starts_at: 2.days.ago, ends_at: 1.day.ago, doors_open_at: 2.days.ago - 30.minutes)
    expect(&checkout).to raise_error(described_class::CheckoutError, /not currently on sale/)

    event.update!(starts_at: 2.days.from_now, ends_at: 2.days.from_now + 2.hours,
      doors_open_at: 2.days.from_now - 30.minutes, status: :postponed)
    expect(&checkout).to raise_error(described_class::CheckoutError, /not currently on sale/)
    expect(event.orders).to be_empty
  end

  it "does not create a Stripe intent for an immediately settled box-office payment" do
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:create_payment_intent)

    result = described_class.call(
      event: event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: "walkin@example.com",
      buyer_name: "Walk-in",
      payment_required: false,
      service_fee: false,
      source: "box_office",
      payment_method: "door_cash"
    )

    expect(StripeService).not_to have_received(:create_payment_intent)
    expect(result.order).to be_completed
    expect(result.payment).to have_attributes(provider: "door_cash", status: "succeeded")
    expect(result.payment_intent).to be_nil
  end

  it "counts pending card-present holds against the dedicated door allocation" do
    ticket_type.update!(door_allocation: 1)
    first = described_class.call(
      event: event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: "walkin@example.com",
      buyer_name: "Walk-in",
      payment_required: true,
      payment_provider: "boh_clover",
      service_fee: false,
      source: "box_office",
      payment_method: "door_card"
    )

    expect(first.order).to be_pending
    expect(ticket_type.reload.door_available_quantity).to eq(0)
    expect do
      described_class.call(
        event: event,
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
        buyer_email: "second@example.com",
        buyer_name: "Second walk-in",
        payment_required: false,
        service_fee: false,
        source: "box_office",
        payment_method: "door_cash"
      )
    end.to raise_error(described_class::CheckoutError, /Only 0 door tickets remain/)
  end

  it "cancels the provider intent and releases inventory when attaching it fails" do
    intent = OpenStruct.new(id: "pi_orphan_candidate", client_secret: "secret")
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:create_payment_intent).and_return(intent)
    allow(StripeService).to receive(:cancel_payment_intent).and_return(
      OpenStruct.new(id: intent.id, status: "canceled")
    )
    allow_any_instance_of(Order).to receive(:update!).and_wrap_original do |original, attributes|
      raise ActiveRecord::StatementInvalid, "attach failed" if attributes.key?(:stripe_payment_intent_id)

      original.call(attributes)
    end

    expect do
      described_class.call(
        event: event,
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
        buyer_email: "buyer@example.com",
        buyer_name: "Buyer"
      )
    end.to raise_error(described_class::CheckoutError, "Payment setup failed")

    order = event.orders.last
    expect(StripeService).to have_received(:cancel_payment_intent).with(
      intent.id,
      idempotency_key: "cancel:payment-setup:#{order.payments.first.id}", payment: order.payments.first
    )
    expect(order.reload).to be_cancelled
    expect(order.inventory_holds).to all(be_released)
  end

  it "cancels an attached intent without exposing its secret if setup outlasts the reservation" do
    SiteSetting.instance.update!(payment_mode: "test")
    intent = OpenStruct.new(id: "pi_expired_setup", client_secret: "expired_secret",
      allowed_payment_method_types: ["card"], payment_method_types: ["card"])
    allow(StripeService).to receive(:create_payment_intent) do |sale_order, **|
      sale_order.update!(expires_at: 1.minute.ago)
      intent
    end
    allow(StripeService).to receive(:cancel_payment_intent).and_return(OpenStruct.new(status: "canceled"))
    result = described_class.call(event: event, line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: "expired@example.invalid", buyer_name: "Expired Buyer", payment_required: true)
    expect(result.payment_intent).to be_nil
    expect(result.order).to be_expired
    expect(result.payment).to have_attributes(status: "cancelled", provider_payment_id: intent.id)
    expect(result.order.inventory_holds).to all(be_expired)
    expect(StripeService).to have_received(:cancel_payment_intent).with(intent.id,
      idempotency_key: "cancel:payment:#{result.payment.id}", payment: result.payment)
  end

  it "rejects a checkout that exceeds the active pricing tier allocation before payment setup" do
    create(
      :pricing_tier,
      ticket_type: ticket_type,
      tier_type: :quantity_based,
      quantity_limit: 2,
      quantity_sold: 1,
      price_cents: 500
    )
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:create_payment_intent)

    expect do
      described_class.call(
        event: event,
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 2 }],
        buyer_email: "buyer@example.com",
        buyer_name: "Buyer"
      )
    end.to raise_error(described_class::CheckoutError, /Only 1 ticket remains at the/)

    expect(StripeService).not_to have_received(:create_payment_intent)
    expect(event.orders).to be_empty
  end

  it "keeps the purchased name and price when current ticket inventory is edited" do
    allow(StripeService).to receive(:payment_enabled?).and_return(false)
    purchased_name = ticket_type.name

    result = described_class.call(
      event: event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: "buyer@example.com",
      buyer_name: "Buyer"
    )
    item = result.order.order_items.first

    ticket_type.update!(name: "Renamed admission", price_cents: 9000)

    expect(item.reload).to have_attributes(name: purchased_name, unit_price_cents: 1000)
  end

  it "keeps a free ticket fully free with no flat service fee" do
    ticket_type.update!(price_cents: 0)
    allow(StripeService).to receive(:payment_enabled?).and_return(true)

    result = described_class.call(
      event: event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 2 }],
      buyer_email: "free@example.com",
      buyer_name: "Free Buyer"
    )

    expect(result.order).to have_attributes(subtotal_cents: 0, service_fee_cents: 0, total_cents: 0, status: "completed")
    expect(result.payment).to be_nil
    expect(result.payment_intent).to be_nil
  end

  it "enforces a buyer limit across prior purchases using normalized email" do
    ticket_type.update!(max_per_buyer: 2, quantity_sold: 1)
    previous_order = create(:order, event: event, buyer_email: "BUYER@EXAMPLE.COM")
    create(:ticket, order: previous_order, event: event, ticket_type: ticket_type)
    allow(StripeService).to receive(:payment_enabled?).and_return(false)

    expect do
      described_class.call(
        event: event,
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 2 }],
        buyer_email: " buyer@example.com ",
        buyer_name: "Buyer"
      )
    end.to raise_error(described_class::CheckoutError, /Purchase limit is 2/)
  end
  describe "initial release scope" do
    def scoped_checkout(**overrides)
      described_class.call(**{
        event: event, line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
        buyer_email: "test@example.com", buyer_name: "Tester", payment_required: false
      }.merge(overrides))
    end

    before { allow(LaunchCapabilities).to receive(:enabled?).and_return(false) }

    it "rejects an explicit seat hold before creating records" do
      expect { scoped_checkout(seat_hold_token: "disabled-seat-hold") }.to raise_error(described_class::CheckoutError, /Assigned seating/)
      expect(event.orders).to be_empty
    end

    it "rejects reserved ticket inventory even when no seat hold is supplied" do
      event.update!(venue: create(:venue))
      configuration = create(:event_seating_configuration, event: event)
      create(:event_seat, event_seating_configuration: configuration, ticket_type: ticket_type)
      expect { scoped_checkout }.to raise_error(described_class::CheckoutError, /Assigned seating/)
      expect(event.orders).to be_empty
    end

    it "rejects explicit advanced input" do
      expect { scoped_checkout(registration_answers: { "123" => "answer" }) }.to raise_error(described_class::CheckoutError, /custom registration/)
      expect(event.orders).to be_empty
    end

    it "rejects required active registration definitions without submitted answers" do
      create(:registration_question, event: event, required: true)
      expect { scoped_checkout }.to raise_error(described_class::CheckoutError, /custom registration/)
      expect(event.orders).to be_empty
    end

    it "rejects required active waivers without submitted acceptance" do
      create(:event_waiver, event: event, required: true)
      expect { scoped_checkout }.to raise_error(described_class::CheckoutError, /custom registration/)
      expect(event.orders).to be_empty
    end
  end

  describe "production paid checkout" do
    before do
      allow(Rails.env).to receive(:production?).and_return(true)
      allow(event).to receive(:production_release_gate_status).and_return(nil)
      allow(LivePilot).to receive(:enforce_inventory_cap!)
    end

    it "rejects simulated paid checkout without creating an order or contacting Stripe" do
      allow(StripeService).to receive(:create_payment_intent)
      expect do
        described_class.call(event: event, line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
          buyer_email: "test@example.com", buyer_name: "Tester", payment_required: true)
      end.to raise_error(described_class::CheckoutError, /Simulated payments/)
      expect(event.orders).to be_empty
      expect(StripeService).not_to have_received(:create_payment_intent)
    end

    it "rejects an unrecorded positive-total checkout bypass" do
      expect do
        described_class.call(event: event, line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
          buyer_email: "test@example.com", buyer_name: "Tester", payment_required: false)
      end.to raise_error(described_class::CheckoutError, /recorded payment/)
      expect(event.orders).to be_empty
    end
  end
  it "retains a contradictory created intent and reservation for review without exposing or recreating the operation" do
    SiteSetting.instance.update!(payment_mode: "test")
    intent = OpenStruct.new(id: "pi_policy_mismatch", client_secret: "private_secret",
      allowed_payment_method_types: ["card"], payment_method_types: ["card", "us_bank_account"])
    allow(StripeService).to receive(:create_payment_intent).and_return(intent)
    allow(StripeService).to receive(:cancel_payment_intent)
    options = { event: event, line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: "buyer@example.invalid", buyer_name: "Buyer", checkout_key_digest: "c" * 64,
      checkout_request_digest: "d" * 64 }
    expect { described_class.call(**options) }.to raise_error(described_class::CheckoutError, /support review/)
    order = event.orders.last
    expect(order).to be_pending
    expect(order.payments.last.provider_payment_id).to eq("pi_policy_mismatch")
    expect(order.inventory_holds).to all(be_active)
    expect(order.reconciliation_exceptions.open).to exist(code: "payment_method_policy_mismatch")
    expect(StripeService).not_to have_received(:cancel_payment_intent)
    allow(StripeService).to receive(:retrieve_payment_intent).and_return(
      OpenStruct.new(id: intent.id, client_secret: intent.client_secret, amount: order.total_cents,
        currency: "usd", livemode: false, status: "requires_payment_method",
        allowed_payment_method_types: ["card"], payment_method_types: ["card", "us_bank_account"]))
    expect { described_class.call(**options) }.to raise_error(Commerce::PaymentRecovery::RecoveryError, /support review/)
    expect(event.orders.count).to eq(1)
    expect(StripeService).to have_received(:create_payment_intent).once
  end
end
