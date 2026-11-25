# frozen_string_literal: true

require "rails_helper"

# The verified fulfilling payment and the never-fulfilled marker in the
# fulfilment predicate (docs/design/never-fulfilled-captures.md §4.3, C-18, C-20).
RSpec.describe "Order fulfilment ownership" do
  def expired_order_with_capture
    order = create(:order, status: :expired, completed_at: nil, subtotal_cents: 1200, service_fee_cents: 160, total_cents: 1360)
    [order, create(:payment, order: order, status: :succeeded, succeeded_at: Time.current)]
  end

  describe "completion" do
    it "is written by completion with the verified payment and left empty for free orders" do
      allow(EmailService).to receive(:send_order_confirmation_async)
      allow(StripeService).to receive(:payment_enabled?).and_return(true)
      allow(StripeService).to receive(:create_payment_intent)
        .and_return(OpenStruct.new(id: "pi_fulfilling_#{SecureRandom.hex(4)}", client_secret: "secret"))
      event = create(:event, :published, starts_at: 5.days.from_now, max_capacity: 10)
      paid_type = create(:ticket_type, event: event, price_cents: 2500, quantity_available: 10, max_per_order: 10)
      result = Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: paid_type.id, quantity: 1 }],
        buyer_email: "buyer@example.com", buyer_name: "Buyer")

      expect(Commerce::OrderLifecycle.complete!(result.order, payment: result.payment)).to eq(:completed)
      expect(result.order.reload.fulfilled_by_payment_id).to eq(result.payment.id)
      expect(result.payment.reload.capture_recorded_at).to be_present

      free_type = create(:ticket_type, :free, event: event, quantity_available: 10, max_per_order: 10)
      free = Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: free_type.id, quantity: 1 }],
        buyer_email: "free@example.com", buyer_name: "Free Buyer")
      expect(free.order.reload).to be_completed
      expect(free.order.fulfilled_by_payment_id).to be_nil
    end
  end

  describe "Order#ticket_fulfilled? (C-20)" do
    it "is false for a never-fulfilled order even when it is partially refunded" do
      order, payment = expired_order_with_capture
      UnfulfilledCapture.create!(order: order, payment: payment, capture_scope: "order",
        code: "late_payment_success_after_hold_expiry", captured_cents: 1360, currency: payment.currency,
        proceeds_cents: 1200, fee_cents: 160, organizer_fee_cents: 0, tax_cents: 0, processing_bearer: "platform",
        dispute_fee_bearer: "platform", allocation_policy: "item_record", policy_version: "nfc-v2.1", provenance: "lifecycle")
      order.update!(status: :partially_refunded)
      expect(order.reload.ticket_fulfilled?).to be(false)
      expect(order).to be_never_fulfilled
    end
  end
end
