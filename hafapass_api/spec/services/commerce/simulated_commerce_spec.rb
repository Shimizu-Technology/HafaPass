# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Safe simulated commerce" do
  let(:event) { create(:event, :published) }
  let(:type) { create(:ticket_type, event: event, price_cents: 1000, quantity_available: 5) }

  def simulated_order
    SiteSetting.instance.update!(payment_mode: "simulate")
    Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: type.id, quantity: 2 }],
      buyer_name: "Simulation guest", buyer_email: "simulation@example.invalid")
  end

  it "records a simulated capture and can refund it without any external SDK call" do
    allow(Rails.env).to receive(:staging?).and_return(true)
    allow(Stripe::PaymentIntent).to receive(:create)
    allow(Stripe::Refund).to receive(:create)
    result = simulated_order
    expect(result.order).to be_completed
    expect(result.payment).to be_succeeded
    expect(result.payment.provider_payload).to include("simulated" => true)
    expect(result.payment_intent).to be_nil
    refund = Commerce::RefundCreator.call(order: result.order, tickets: [result.order.tickets.first],
      idempotency_key: "simulation-refund")
    expect(refund).to be_succeeded
    expect(Stripe::PaymentIntent).not_to have_received(:create)
    expect(Stripe::Refund).not_to have_received(:create)
  end

  it "never turns a simulated paid ticket into valid production admission" do
    result = simulated_order
    allow(Rails.env).to receive(:production?).and_return(true)
    expect(result.order).not_to be_ticket_fulfilled
    expect(result.order.tickets.first).not_to be_admission_allowed
    expect do
      Commerce::RefundCreator.call(order: result.order, amount_cents: 100,
        idempotency_key: "production-simulation-rejected")
    end.to raise_error(Commerce::RefundCreator::RefundError, /Simulated payments/)
  end

  it "does not treat an unrecorded paid capture as fulfilled in production" do
    order = create(:order, event: event, total_cents: 1000, subtotal_cents: 1000, service_fee_cents: 0)
    allow(Rails.env).to receive(:production?).and_return(true)
    expect(order).not_to be_ticket_fulfilled
    create(:payment, :succeeded, order: order, amount_cents: 1000, provider_payment_id: "pi_verified_capture", provider_environment: "live")
    expect(order).to be_ticket_fulfilled
  end

  it "requires an explicit provider operation for ambiguous multiple captures" do
    result = simulated_order
    create(:payment, :succeeded, order: result.order, provider_payment_id: "pi_second_capture")
    expect do
      Commerce::RefundCreator.call(order: result.order, amount_cents: 100, idempotency_key: "ambiguous")
    end.to raise_error(Commerce::RefundCreator::RefundError, /Multiple captured payments/)
    expect(result.order.refunds).to be_empty
  end
  it "does not grant production admission from a captured Stripe sandbox payment" do
    order = create(:order, event: event, total_cents: 1000, subtotal_cents: 1000, service_fee_cents: 0)
    create(:payment, :succeeded, order: order, amount_cents: 1000, provider_environment: "test")
    allow(Rails.env).to receive(:production?).and_return(true)
    expect(order).not_to be_ticket_fulfilled
  end
end
