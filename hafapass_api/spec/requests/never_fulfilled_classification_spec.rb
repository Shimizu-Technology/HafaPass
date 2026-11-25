# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# A1 tranche 2 lifecycle writers (docs/design/never-fulfilled-captures.md
# §4.3): every late-capture boundary classifies the exact payment from the
# provider fact that proved it, through the real Stripe webhook and expiry
# paths with synthetic Stripe objects.
RSpec.describe "Never-fulfilled classification at late-capture boundaries", type: :request do
  include ActiveJob::TestHelper

  let(:organizer_profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: organizer_profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 1200, quantity_available: 10, quantity_sold: 0) }

  before do
    SiteSetting.instance.update!(payment_mode: "test")
    allow(StripeService).to receive(:card_only_intent?).and_return(true)
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(Sentry).to receive(:capture_message)
    allow(StripeService).to receive(:cancel_payment_intent)
  end

  def post_stripe_event(type, object, event_id: "evt_nfc_#{SecureRandom.hex(4)}")
    post "/webhooks/stripe", params: { id: event_id, type: type, data: { object: object } }.to_json,
      headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:ok)
  end

  def checkout(intent_id, quantity: 1)
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:create_payment_intent).and_return(OpenStruct.new(id: intent_id,
      client_secret: "#{intent_id}_secret", allowed_payment_method_types: ["card"], payment_method_types: ["card"]))
    Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: ticket_type.id, quantity: quantity }],
      buyer_email: "buyer@example.com", buyer_name: "Buyer")
  end

  def succeed!(payment, event_id: "evt_nfc_#{SecureRandom.hex(4)}", amount: payment.amount_cents, currency: "usd")
    post_stripe_event("payment_intent.succeeded", { id: payment.provider_payment_id, amount: amount,
      amount_received: amount, currency: currency, status: "succeeded" }.compact, event_id: event_id)
  end

  def lapse!(result)
    result.order.update_columns(expires_at: 1.minute.ago)
    result.order.inventory_holds.update_all(expires_at: 1.minute.ago)
  end

  def expect_order_scope_row(order, payment, code)
    capture = UnfulfilledCapture.find_by!(payment: payment)
    expect(capture).to have_attributes(order_id: order.id, capture_scope: "order", code: code,
      captured_cents: payment.amount_cents, currency: payment.currency, provenance: "lifecycle",
      processing_bearer: "platform", dispute_fee_bearer: "platform", allocation_policy: "item_record",
      policy_version: "nfc-v2.1")
    expect(capture.capture_recorded_at).to eq(payment.reload.capture_recorded_at)
    items = order.order_items
    expect([capture.proceeds_cents, capture.fee_cents, capture.organizer_fee_cents, capture.tax_cents])
      .to eq([items.sum(:organizer_proceeds_cents), items.sum(:fee_cents), items.sum(:organizer_fee_cents), items.sum(:tax_cents)])
    expect(capture.proceeds_cents + capture.fee_cents + capture.organizer_fee_cents + capture.tax_cents).to eq(order.total_cents)
    expect(order.reload.never_fulfilled_at).to eq(capture.created_at)
    expect(order.tickets.where.not(status: :cancelled)).to be_empty
    capture
  end

  describe "online checkout" do
    it "classifies a capture after the order was released, once, from the signed webhook" do
      result = checkout("pi_nfc_released")
      post_stripe_event("payment_intent.payment_failed", { id: "pi_nfc_released", amount: result.payment.amount_cents,
        currency: "usd" })
      expect(result.order.reload).to be_cancelled

      expect { succeed!(result.payment, event_id: "evt_nfc_released") }.to have_enqueued_job(LateCaptureRefundJob).once
      capture = expect_order_scope_row(result.order, result.payment, "late_payment_success_after_inventory_release")
      issue = ReconciliationException.find_by!(payment: result.payment, code: "late_payment_success_after_inventory_release")
      receipt = WebhookEvent.find_by!(provider_event_id: "evt_nfc_released")
      release = AuditLog.find_by!(auditable: result.order, action: "order.cancelled")
      expect(capture.provenance_evidence).to include("source" => "signed_webhook", "webhook_event_id" => receipt.id,
        "event_type" => "payment_intent.succeeded", "provider_object_id" => "pi_nfc_released",
        "amount_cents" => result.payment.amount_cents, "currency" => "usd",
        "reconciliation_exception_id" => issue.id, "release_audit_id" => release.id)
      expect(AuditLog.where(auditable: capture, action: "never_fulfilled_capture.classified").count).to eq(1)

      # The same receipt again, and a second delivery of the same payment.
      expect do
        succeed!(result.payment, event_id: "evt_nfc_released")
        succeed!(result.payment, event_id: "evt_nfc_released_again")
      end.not_to have_enqueued_job(LateCaptureRefundJob)
      expect(UnfulfilledCapture.where(payment: result.payment).count).to eq(1)
      expect(ReconciliationException.where(payment: result.payment).pluck(:code))
        .to eq(["late_payment_success_after_inventory_release"])
      expect(result.order.reload).to be_cancelled
    end

    it "classifies a lapsed capture whose released inventory sold, and keeps the automatic refund" do
      refunds = []
      allow(StripeService).to receive(:refund_payment) do |intent_id, amount_cents:, idempotency_key:, **|
        refunds << [idempotency_key, amount_cents]
        OpenStruct.new(id: "re_nfc_#{refunds.length}", status: "succeeded", amount: amount_cents, currency: "usd",
          payment_intent: intent_id)
      end
      result = checkout("pi_nfc_resold", quantity: 2)
      lapse!(result)
      ticket_type.update_columns(quantity_available: 2, quantity_sold: 1)

      expect { succeed!(result.payment) }.to have_enqueued_job(LateCaptureRefundJob).once
      expect(result.order.reload).to be_expired
      expect_order_scope_row(result.order, result.payment, "late_payment_success_after_hold_expiry")
      expect(ticket_type.reload.quantity_sold).to eq(1)

      perform_enqueued_jobs
      expect(refunds).to eq([["late-capture:payment:#{result.payment.id}", result.payment.amount_cents]])
      expect(result.order.reload).to be_refunded
      expect(result.order.never_fulfilled_at).to be_present
      expect(UnfulfilledCapture.where(payment: result.payment).count).to eq(1)
    end

    it "classifies from the expiry job's authenticated PaymentIntent lookup" do
      result = checkout("pi_nfc_lookup")
      lapse!(result)
      ticket_type.update_columns(quantity_available: 1, quantity_sold: 1)
      allow(StripeService).to receive(:retrieve_payment_intent).and_return(OpenStruct.new(id: "pi_nfc_lookup",
        status: "succeeded", amount_received: result.payment.amount_cents, currency: "usd", livemode: false))

      ExpireInventoryHoldsJob.perform_now

      capture = expect_order_scope_row(result.order, result.payment, "late_payment_success_after_hold_expiry")
      expect(capture.provenance_evidence).to include("source" => "provider_lookup", "provider_object_id" => "pi_nfc_lookup",
        "livemode" => false, "amount_cents" => result.payment.amount_cents)
      # The webhook that follows is the same payment and changes nothing.
      expect { succeed!(result.payment) }.not_to have_enqueued_job(LateCaptureRefundJob)
      expect(UnfulfilledCapture.count).to eq(1)
    end

    it "still fulfils normally and records no classification when the inventory is free" do
      result = checkout("pi_nfc_free")
      lapse!(result)
      succeed!(result.payment)
      expect(result.order.reload).to be_completed
      expect(result.order.fulfilled_by_payment_id).to eq(result.payment.id)
      expect(result.order.tickets.issued.count).to eq(1)
      expect(UnfulfilledCapture.count).to eq(0)
      expect(ReconciliationException.count).to eq(0)
    end

    it "quarantines instead of guessing when the provider amount, identity or components cannot be verified" do
      no_amount = checkout("pi_nfc_no_amount")
      Commerce::OrderLifecycle.cancel!(no_amount.order)
      succeed!(no_amount.payment, amount: nil, currency: nil)

      lookup_mode = checkout("pi_nfc_wrong_mode")
      Commerce::OrderLifecycle.cancel!(lookup_mode.order)
      Commerce::OrderLifecycle.complete!(lookup_mode.order, payment: lookup_mode.payment,
        provider_amount_cents: lookup_mode.payment.amount_cents, provider_currency: "usd",
        provider_lookup: { provider_object_id: "pi_nfc_wrong_mode", livemode: true })

      mismatch = checkout("pi_nfc_components")
      Commerce::OrderLifecycle.cancel!(mismatch.order)
      mismatch.order.order_items.sole.update_columns(organizer_proceeds_cents: mismatch.order.order_items.sole.organizer_proceeds_cents - 1)
      succeed!(mismatch.payment)

      expect(UnfulfilledCapture.count).to eq(0)
      reasons = ReconciliationException.where(code: "never_fulfilled_classification_quarantined")
        .to_h { |issue| [issue.payment_id, issue.details["reason"]] }
      expect(reasons).to eq(no_amount.payment.id => "provider_amount_unverified",
        lookup_mode.payment.id => "provider_identity_unverified", mismatch.payment.id => "components_mismatch")
      # The existing late-capture record and automatic refund are unchanged.
      [no_amount, lookup_mode, mismatch].each do |result|
        expect(result.order.reload.never_fulfilled_at).to be_nil
        expect(ReconciliationException.where(payment: result.payment, code: Commerce::LateCaptureRefund::CODES).count).to eq(1)
      end
      expect(Commerce::RefundSafety::FINANCIAL_CODES).not_to include("never_fulfilled_classification_quarantined")

      # A repeat notice opens no second quarantine.
      succeed!(mismatch.payment)
      expect(ReconciliationException.where(payment: mismatch.payment, code: "never_fulfilled_classification_quarantined").count).to eq(1)
    end

    it "never classifies a capture recorded before A1 from the lifecycle" do
      order = create(:order, event: event, status: :cancelled, completed_at: nil, subtotal_cents: 1200, service_fee_cents: 0,
        total_cents: 1200)
      create(:order_item, order: order, ticket_type: ticket_type, unit_price_cents: 1200, fee_cents: 0)
      payment = create(:payment, order: order, provider_payment_id: "pi_nfc_pre_a1", status: :pending)
      # A pre-A1 capture: captured before the recording trigger existed.
      ActiveRecord::Base.connection.execute("ALTER TABLE payments DISABLE TRIGGER payments_capture_recorded_at")
      payment.update_columns(status: Payment.statuses[:succeeded], succeeded_at: 1.day.ago)
      ActiveRecord::Base.connection.execute("ALTER TABLE payments ENABLE TRIGGER payments_capture_recorded_at")
      expect(payment.reload.capture_recorded_at).to be_nil

      succeed!(payment)

      expect(UnfulfilledCapture.count).to eq(0)
      expect(ReconciliationException.find_by!(payment: payment, code: "never_fulfilled_classification_quarantined")
        .details["reason"]).to eq("capture_recorded_before_a1")
    end

    it "keeps simulated and non-Stripe captures on their existing late-capture record" do
      result = checkout("pi_nfc_simulated")
      Commerce::OrderLifecycle.cancel!(result.order)
      result.payment.update_columns(provider_payload: { simulated: true })
      succeed!(result.payment)
      expect(UnfulfilledCapture.count).to eq(0)
      expect(ReconciliationException.where(payment: result.payment).pluck(:code))
        .to eq(["late_payment_success_after_inventory_release"])
    end
  end

  describe "a distinct second capture" do
    def fulfilled_checkout(intent_id)
      result = checkout(intent_id)
      succeed!(result.payment)
      expect(result.order.reload).to be_completed
      expect(result.order.fulfilled_by_payment_id).to eq(result.payment.id)
      result
    end

    def second_payment(order, intent_id)
      order.payments.create!(provider: "stripe", provider_environment: "test", provider_platform_account_id: "acct_testplatform",
        provider_payment_id: intent_id, idempotency_key: "second:#{intent_id}", amount_cents: order.total_cents,
        currency: order.currency, status: :pending)
    end

    it "is classified in payment scope against the verified fulfilling payment, once, with no effect on the sale" do
      result = fulfilled_checkout("pi_nfc_sale_a")
      payment_b = second_payment(result.order, "pi_nfc_second_b")
      tickets_before = result.order.tickets.pluck(:id, :status, :qr_code)
      sold_before = ticket_type.reload.quantity_sold

      expect do
        succeed!(payment_b, event_id: "evt_nfc_second_b")
        succeed!(payment_b, event_id: "evt_nfc_second_b_again")
      end.not_to have_enqueued_job(LateCaptureRefundJob)

      capture = UnfulfilledCapture.find_by!(payment: payment_b)
      expect(capture).to have_attributes(capture_scope: "payment", code: "unfulfilled_second_capture",
        captured_cents: payment_b.amount_cents, proceeds_cents: payment_b.amount_cents, fee_cents: 0,
        organizer_fee_cents: 0, tax_cents: 0, provenance: "lifecycle")
      expect(capture.capture_recorded_at).to eq(payment_b.reload.capture_recorded_at)
      expect(capture.provenance_evidence).to include("fulfilling_payment_id" => result.payment.id,
        "provider_object_id" => "pi_nfc_second_b")
      expect(UnfulfilledCapture.count).to eq(1)
      expect(ReconciliationException.where(payment: payment_b).pluck(:code)).to eq(["unfulfilled_second_capture"])
      order = result.order.reload
      expect(order).to be_completed
      expect(order.never_fulfilled_at).to be_nil
      expect(order.fulfilled_by_payment_id).to eq(result.payment.id)
      expect(order.tickets.pluck(:id, :status, :qr_code)).to eq(tickets_before)
      expect(ticket_type.reload.quantity_sold).to eq(sold_before)
      expect(order.ticket_fulfilled?).to be(true)
      expect(AuditLog.where(auditable: order, action: "order.completed").count).to eq(1)
    end

    # A completed order from before tranche 1: no fulfilling payment column.
    def legacy_completed_order(intent_id, audit_payment: :first)
      order = create(:order, event: event, subtotal_cents: 1200, service_fee_cents: 0, total_cents: 1200)
      create(:order_item, order: order, ticket_type: ticket_type, unit_price_cents: 1200, fee_cents: 0)
      payment_a = create(:payment, :succeeded, order: order, provider_payment_id: intent_id)
      if audit_payment
        AuditLogger.record!(action: "order.completed", auditable: order, organization: event.organization, event: event,
          outcome: "succeeded", deduplication_key: "order:#{order.id}:completed", metadata: { payment_id: payment_a.id })
      end
      [order, payment_a]
    end

    it "recovers a legacy order's fulfilling payment only from its completion audit" do
      order, payment_a = legacy_completed_order("pi_nfc_legacy_a")
      payment_b = second_payment(order, "pi_nfc_legacy_b")

      succeed!(payment_b)

      expect(order.reload.fulfilled_by_payment_id).to eq(payment_a.id)
      expect(AuditLog.where(auditable: order, action: "order.fulfilling_payment_recovered").sole.metadata)
        .to include("payment_id" => payment_a.id)
      expect(UnfulfilledCapture.find_by!(payment: payment_b)).to have_attributes(capture_scope: "payment")
    end

    it "quarantines ambiguous legacy ownership without classifying or choosing the earliest capture" do
      # The fail-open completion audit was never written.
      order, payment_a = legacy_completed_order("pi_nfc_ambiguous_a", audit_payment: nil)
      payment_b = second_payment(order, "pi_nfc_ambiguous_b")

      2.times { succeed!(payment_b) }

      expect(UnfulfilledCapture.count).to eq(0)
      expect(order.reload.fulfilled_by_payment_id).to be_nil
      expect(ReconciliationException.where(payment: payment_b).pluck(:code)).to eq(["never_fulfilled_ownership_ambiguous"])
      expect(order).to be_completed

      # An audit naming a payment of another order is not evidence either.
      other_order, other_payment = legacy_completed_order("pi_nfc_ambiguous_other", audit_payment: nil)
      AuditLogger.record!(action: "order.completed", auditable: other_order, organization: event.organization, event: event,
        outcome: "succeeded", deduplication_key: "order:#{other_order.id}:completed", metadata: { payment_id: payment_a.id })
      other_b = second_payment(other_order, "pi_nfc_ambiguous_other_b")
      succeed!(other_b)
      expect(other_order.reload.fulfilled_by_payment_id).to be_nil
      expect(ReconciliationException.where(payment: other_b).pluck(:code)).to eq(["never_fulfilled_ownership_ambiguous"])
      expect(other_payment.reload).to be_succeeded
    end

    it "treats a repeated notice of a legacy order's only capture as no second capture" do
      order, payment_a = legacy_completed_order("pi_nfc_only_capture", audit_payment: nil)
      succeed!(payment_a)
      expect(ReconciliationException.where(order: order)).to be_empty
      expect(UnfulfilledCapture.count).to eq(0)
    end

    it "adds a second order-scope row on an already classified order and keeps the first marker" do
      result = checkout("pi_nfc_first_unfulfilled")
      Commerce::OrderLifecycle.cancel!(result.order)
      succeed!(result.payment)
      first = UnfulfilledCapture.find_by!(payment: result.payment)
      result.order.update_columns(status: Order.statuses[:refunded])
      payment_b = second_payment(result.order, "pi_nfc_second_unfulfilled")

      expect { 2.times { succeed!(payment_b) } }.not_to have_enqueued_job(LateCaptureRefundJob)

      second = UnfulfilledCapture.find_by!(payment: payment_b)
      expect(second).to have_attributes(capture_scope: "order", code: "late_payment_success_after_inventory_release")
      expect(result.order.reload.never_fulfilled_at).to eq(first.created_at)
      expect(ReconciliationException.where(payment: payment_b).pluck(:code)).to eq(["late_payment_success_after_inventory_release"])
    end
  end
end
