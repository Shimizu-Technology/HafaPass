require "rails_helper"

RSpec.describe "Stripe webhooks", type: :request do
  let(:organizer_profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: organizer_profile) }
  let(:ticket_type) { create(:ticket_type, event: event, quantity_sold: 1) }
  let(:pricing_tier) do
    create(:pricing_tier, ticket_type: ticket_type, tier_type: :quantity_based, quantity_limit: 10, quantity_sold: 1)
  end

  before do
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(EmailService).to receive(:send_ticket_email_async)
    allow(EmailService).to receive(:send_refund_notification_async)
  end

  def post_stripe_event(type, object, event_id: "evt_test_#{SecureRandom.hex(4)}")
    post "/webhooks/stripe", params: {
      id: event_id,
      type: type,
      data: { object: object }
    }.to_json, headers: { "Content-Type" => "application/json" }
  end

  def create_pending_checkout(intent_id: "pi_checkout", quantity: 1)
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:create_payment_intent).and_return(
      OpenStruct.new(id: intent_id, client_secret: "#{intent_id}_secret")
    )
    Commerce::OrderCreator.call(
      event: event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: quantity }],
      buyer_email: "buyer@example.com",
      buyer_name: "Buyer"
    )
  end

  it "rejects unsigned webhooks outside development and test" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))

    expect do
      post_stripe_event("payment_intent.succeeded", { id: "pi_unsigned" }, event_id: "evt_unsigned")
    end.not_to change(WebhookEvent, :count)

    expect(response).to have_http_status(:bad_request)
  end

  it "identifies a missing Stripe signature when the production secret is configured" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("STRIPE_WEBHOOK_SECRET").and_return("whsec_test")

    post_stripe_event("payment_intent.succeeded", { id: "pi_unsigned" }, event_id: "evt_missing_signature")

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq("error" => "Stripe signature missing")
  end

  it "rejects an invalid Stripe signature before storing a receipt" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("STRIPE_WEBHOOK_SECRET").and_return("whsec_test")
    allow(Stripe::Webhook).to receive(:construct_event).and_raise(
      Stripe::SignatureVerificationError.new("bad signature", "sig")
    )

    expect do
      post "/webhooks/stripe", params: { id: "evt_bad_signature" }.to_json,
        headers: { "Content-Type" => "application/json", "Stripe-Signature" => "sig" }
    end.not_to change(WebhookEvent, :count)

    expect(response).to have_http_status(:bad_request)
  end

  it "releases ticket type and pricing tier inventory when payment fails" do
    order = create(:order, :pending, event: event, stripe_payment_intent_id: "pi_failed")
    ticket = create(:ticket, order: order, event: event, ticket_type: ticket_type, pricing_tier: pricing_tier)

    post_stripe_event("payment_intent.payment_failed", { id: "pi_failed" })

    expect(response).to have_http_status(:ok)
    expect(order.reload).to be_cancelled
    expect(ticket.reload).to be_cancelled
    expect(ticket_type.reload.quantity_sold).to eq(0)
    expect(pricing_tier.reload.quantity_sold).to eq(0)
  end

  it "records reconciliation instead of guessing allocations for a legacy order without item snapshots" do
    order = create(:order, event: event, total_cents: 5250, stripe_payment_intent_id: "pi_refunded")
    create(:ticket, order: order, event: event, ticket_type: ticket_type, pricing_tier: pricing_tier)

    post_stripe_event("charge.refunded", { payment_intent: "pi_refunded", amount_refunded: 5250,
      refunds: { data: [{ id: "re_legacy", status: "succeeded" }] } })

    expect(response).to have_http_status(:ok)
    expect(order.reload).to be_completed
    expect(order.reconciliation_exceptions).to exist(code: "refund_missing_order_item_ledger")
  end

  it "stores, normalizes, and idempotently processes a successful payment event" do
    checkout = create_pending_checkout
    payload = { id: "pi_checkout", amount: checkout.payment.amount_cents, amount_received: checkout.payment.amount_cents,
                currency: "usd", status: "succeeded" }

    expect do
      post_stripe_event("payment_intent.succeeded", payload, event_id: "evt_success_once")
    end.to change(WebhookEvent, :count).by(1)
      .and change(PaymentEvent, :count).by(1)
      .and change(Ticket, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(checkout.order.reload).to be_completed
    expect(WebhookEvent.last.payload.dig("data", "object", "id")).to eq("pi_checkout")

    expect do
      post_stripe_event("payment_intent.succeeded", payload, event_id: "evt_success_once")
    end.not_to change { [WebhookEvent.count, PaymentEvent.count, Ticket.count] }
    expect(response).to have_http_status(:ok)
  end

  it "ignores a late failure after success but retains both provider events" do
    checkout = create_pending_checkout(intent_id: "pi_out_of_order")
    post_stripe_event(
      "payment_intent.succeeded",
      { id: "pi_out_of_order", amount_received: checkout.payment.amount_cents, currency: "usd" },
      event_id: "evt_success_first"
    )
    post_stripe_event(
      "payment_intent.payment_failed",
      { id: "pi_out_of_order", amount: checkout.payment.amount_cents, currency: "usd" },
      event_id: "evt_failure_late"
    )

    expect(response).to have_http_status(:ok)
    expect(checkout.order.reload).to be_completed
    expect(checkout.payment.reload).to be_succeeded
    expect(checkout.payment.payment_events.count).to eq(2)
  end

  it "quarantines a late success after failure and released inventory" do
    checkout = create_pending_checkout(intent_id: "pi_late_success")
    post_stripe_event(
      "payment_intent.payment_failed",
      { id: "pi_late_success", amount: checkout.payment.amount_cents, currency: "usd" },
      event_id: "evt_failure_first"
    )
    expect(checkout.order.reload).to be_cancelled

    post_stripe_event(
      "payment_intent.succeeded",
      { id: "pi_late_success", amount_received: checkout.payment.amount_cents, currency: "usd" },
      event_id: "evt_success_late"
    )

    expect(response).to have_http_status(:ok)
    expect(checkout.order.reload).to be_cancelled
    expect(checkout.payment.reload).to be_succeeded
    expect(checkout.order.reconciliation_exceptions).to exist(code: "late_payment_success_after_inventory_release")
    expect(checkout.order.tickets).to be_empty
  end

  it "keeps a mismatched provider amount pending and opens reconciliation" do
    checkout = create_pending_checkout(intent_id: "pi_mismatch")
    post_stripe_event(
      "payment_intent.succeeded",
      { id: "pi_mismatch", amount_received: checkout.payment.amount_cents + 500, currency: "usd" },
      event_id: "evt_mismatch"
    )

    expect(response).to have_http_status(:ok)
    expect(checkout.order.reload).to be_pending
    expect(checkout.order.reconciliation_exceptions).to exist(code: "payment_amount_mismatch")
  end

  it "reconciles a provider-side full refund into additive ledger records" do
    checkout = create_pending_checkout(intent_id: "pi_provider_refund")
    post_stripe_event(
      "payment_intent.succeeded",
      { id: "pi_provider_refund", amount_received: checkout.payment.amount_cents, currency: "usd" },
      event_id: "evt_paid_for_refund"
    )

    post_stripe_event(
      "charge.refunded",
      { id: "ch_refunded", payment_intent: "pi_provider_refund", amount_refunded: checkout.payment.amount_cents,
        currency: "usd", refunds: { data: [{ id: "re_actual_provider_refund", status: "succeeded" }] } },
      event_id: "evt_provider_refund"
    )

    expect(response).to have_http_status(:ok)
    expect(checkout.order.reload).to be_refunded
    expect(checkout.order.refunds.succeeded.sum(:amount_cents)).to eq(checkout.order.total_cents)
    expect(checkout.order.refunds.succeeded.last.provider_refund_id).to eq("re_actual_provider_refund")
    expect(checkout.order.tickets.reload).to all(be_cancelled)
  end

  it "suspends ticket access during a dispute and restores it when the dispute is won" do
    checkout = create_pending_checkout(intent_id: "pi_disputed_won")
    post_stripe_event(
      "payment_intent.succeeded",
      { id: "pi_disputed_won", amount_received: checkout.payment.amount_cents, currency: "usd" },
      event_id: "evt_disputed_payment"
    )

    dispute = { id: "dp_won", payment_intent: "pi_disputed_won", amount: checkout.payment.amount_cents,
                currency: "usd", reason: "fraudulent", status: "needs_response" }
    post_stripe_event("charge.dispute.created", dispute, event_id: "evt_dispute_open")

    expect(checkout.order.reload.ticket_access_blocked?).to be(true)
    expect(checkout.order.tickets.first).to be_issued

    post_stripe_event("charge.dispute.closed", dispute.merge(status: "won"), event_id: "evt_dispute_won")

    expect(Dispute.find_by(provider_dispute_id: "dp_won")).to be_won
    expect(checkout.order.reload.ticket_access_blocked?).to be(false)

    post_stripe_event(
      "charge.dispute.updated",
      dispute.merge(status: "needs_response"),
      event_id: "evt_dispute_stale_update"
    )

    expect(Dispute.find_by(provider_dispute_id: "dp_won")).to be_won
    expect(checkout.order.reload.ticket_access_blocked?).to be(false)
  end

  it "revokes tickets and releases inventory when a dispute is lost, idempotently" do
    checkout = create_pending_checkout(intent_id: "pi_disputed_lost")
    post_stripe_event(
      "payment_intent.succeeded",
      { id: "pi_disputed_lost", amount_received: checkout.payment.amount_cents, currency: "usd" },
      event_id: "evt_lost_payment"
    )
    ticket = checkout.order.reload.tickets.first
    old_scan = ticket.scan_credential
    sold_before = ticket_type.reload.quantity_sold
    dispute = { id: "dp_lost", payment_intent: "pi_disputed_lost", amount: checkout.payment.amount_cents,
                currency: "usd", reason: "fraudulent", status: "lost" }

    post_stripe_event("charge.dispute.closed", dispute, event_id: "evt_dispute_lost")

    expect(response).to have_http_status(:ok)
    expect(ticket.reload).to be_cancelled
    expect(ticket_type.reload.quantity_sold).to eq(sold_before - 1)
    expect(TicketCredential.find_scan(old_scan)).to be_nil

    expect do
      post_stripe_event("charge.dispute.closed", dispute, event_id: "evt_dispute_lost")
    end.not_to change { ticket_type.reload.quantity_sold }
  end

  it "does not treat a closed warning inquiry as a lost chargeback" do
    checkout = create_pending_checkout(intent_id: "pi_warning_closed")
    post_stripe_event(
      "payment_intent.succeeded",
      { id: "pi_warning_closed", amount_received: checkout.payment.amount_cents, currency: "usd" },
      event_id: "evt_warning_payment"
    )
    ticket = checkout.order.reload.tickets.first

    post_stripe_event(
      "charge.dispute.closed",
      { id: "dp_warning", payment_intent: "pi_warning_closed", amount: checkout.payment.amount_cents,
        currency: "usd", reason: "fraudulent", status: "warning_closed" },
      event_id: "evt_warning_closed"
    )

    expect(Dispute.find_by(provider_dispute_id: "dp_warning")).to be_won
    expect(ticket.reload).to be_issued
    expect(checkout.order.reload.ticket_access_blocked?).to be(false)
  end
  it "reconciles a pending refund by operation ID and ignores later pending callbacks" do
    checkout = create_pending_checkout(intent_id: "pi_async_refund")
    post_stripe_event("payment_intent.succeeded", { id: "pi_async_refund", amount_received: checkout.payment.amount_cents, currency: "usd" })
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_async", status: "pending"))
    refund = Commerce::RefundCreator.call(order: checkout.order, amount_cents: checkout.payment.amount_cents)
    payload = { id: "re_async", payment_intent: "pi_async_refund", amount: refund.amount_cents, currency: "usd", status: "succeeded" }
    post_stripe_event("refund.updated", payload)
    expect(response).to have_http_status(:ok)
    expect(refund.reload).to be_succeeded
    expect(checkout.order.reload).to be_refunded
    expect(checkout.order.tickets.reload).to all(be_cancelled)
    post_stripe_event("refund.updated", payload.merge(status: "pending"))
    expect(refund.reload).to be_succeeded
    expect(refund.refund_items.sum(:amount_cents)).to eq(refund.amount_cents)
    expect(StripeService).to have_received(:refund_payment).once
  end

  it "does not treat a charge refund aggregate containing a pending operation as succeeded" do
    checkout = create_pending_checkout(intent_id: "pi_charge_pending")
    post_stripe_event("payment_intent.succeeded", { id: "pi_charge_pending", amount_received: checkout.payment.amount_cents, currency: "usd" })
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_charge_pending", status: "pending"))
    refund = Commerce::RefundCreator.call(order: checkout.order, amount_cents: checkout.payment.amount_cents)
    post_stripe_event("charge.refunded", { id: "ch_pending", payment_intent: "pi_charge_pending", amount_refunded: refund.amount_cents,
      refunds: { data: [{ id: "re_charge_pending", payment_intent: "pi_charge_pending", amount: refund.amount_cents, currency: "usd", status: "pending" }] } })
    expect(refund.reload).to be_pending
    expect(checkout.order.reload).to be_completed
  end

  it "rolls back a lost dispute if ticket revocation fails and completes on replay" do
    checkout = create_pending_checkout(intent_id: "pi_lost_retry", quantity: 2)
    post_stripe_event("payment_intent.succeeded", { id: "pi_lost_retry", amount_received: checkout.payment.amount_cents, currency: "usd" })
    ticket = checkout.order.tickets.first
    sold = ticket_type.reload.quantity_sold
    payload = { id: "evt_lost_retry", type: "charge.dispute.closed", data: { object: { id: "dp_retry", payment_intent: "pi_lost_retry",
      amount: checkout.payment.amount_cents, currency: "usd", status: "lost" } } }
    provider_event = Stripe::Event.construct_from(payload)
    updates = 0
    allow_any_instance_of(Ticket).to receive(:update!).and_wrap_original do |original, *args|
      updates += 1
      raise StandardError, "injected ticket failure" if updates == 2
      original.call(*args)
    end
    expect { StripeWebhookProcessor.call(event: provider_event, payload: payload) }.to raise_error(StandardError, /injected/)
    expect(Dispute.find_by(provider_dispute_id: "dp_retry")).to be_nil
    expect(ticket.reload).to be_issued
    expect(ticket_type.reload.quantity_sold).to eq(sold)
    allow_any_instance_of(Ticket).to receive(:update!).and_call_original
    StripeWebhookProcessor.call(event: provider_event, payload: payload)
    expect(ticket.reload).to be_cancelled
    expect(Dispute.find_by!(provider_dispute_id: "dp_retry")).to be_lost
    expect(checkout.order.tickets.reload).to all(be_cancelled)
    expect(ticket_type.reload.quantity_sold).to eq(sold - 2)
  end
  it "binds a callback received after a lost response using provider operation metadata" do
    checkout = create_pending_checkout(intent_id: "pi_lost_response")
    post_stripe_event("payment_intent.succeeded", { id: "pi_lost_response", amount_received: checkout.payment.amount_cents, currency: "usd" })
    allow(StripeService).to receive(:refund_payment).and_raise(Stripe::APIConnectionError, "response lost")
    expect { Commerce::RefundCreator.call(order: checkout.order, amount_cents: 1000, idempotency_key: "lost-response-key") }
      .to raise_error(Commerce::RefundCreator::RefundError, /unknown/)
    refund = checkout.order.refunds.last
    post_stripe_event("refund.updated", { id: "re_lost_response", payment_intent: "pi_lost_response", amount: 1000,
      currency: "usd", status: "succeeded", metadata: { hafapass_refund_key: "lost-response-key" } })
    expect(refund.reload).to be_succeeded
    expect(refund.provider_refund_id).to eq("re_lost_response")
    expect(checkout.order.refunds.count).to eq(1)
  end

  it "applies matching pending operations independently when callbacks arrive in reverse order" do
    checkout = create_pending_checkout(intent_id: "pi_reverse_refunds")
    post_stripe_event("payment_intent.succeeded", { id: "pi_reverse_refunds", amount_received: checkout.payment.amount_cents, currency: "usd" })
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_first", status: "pending"), OpenStruct.new(id: "re_second", status: "pending"))
    first = Commerce::RefundCreator.call(order: checkout.order, amount_cents: 1000, idempotency_key: "first-operation")
    second = Commerce::RefundCreator.call(order: checkout.order, amount_cents: 1000, idempotency_key: "second-operation")
    payload = { payment_intent: "pi_reverse_refunds", amount: 1000, currency: "usd", status: "succeeded" }
    post_stripe_event("refund.updated", payload.merge(id: "re_second"))
    expect(first.reload).to be_pending
    expect(second.reload).to be_succeeded
    post_stripe_event("refund.updated", payload.merge(id: "re_first"))
    expect(first.reload).to be_succeeded
    expect(checkout.order.reload.refunded_cents).to eq(2000)
  end
  it "keeps a failed asynchronous refund unpaid and quarantines a contradictory success" do
    checkout = create_pending_checkout(intent_id: "pi_async_failed")
    post_stripe_event("payment_intent.succeeded", { id: "pi_async_failed", amount_received: checkout.payment.amount_cents, currency: "usd" })
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_async_failed", status: "pending"))
    refund = Commerce::RefundCreator.call(order: checkout.order, tickets: [checkout.order.tickets.first])
    payload = { id: "re_async_failed", payment_intent: "pi_async_failed", amount: refund.amount_cents, currency: "usd", status: "failed" }
    post_stripe_event("refund.failed", payload)
    expect(refund.reload).to be_failed
    expect(refund.refund_tickets.active).to be_empty
    expect(refund.refund_tickets.count).to eq(1)
    expect(checkout.order.reload).to be_completed
    expect(checkout.order.tickets.reload).to all(be_issued)
    post_stripe_event("refund.updated", payload.merge(status: "succeeded"))
    expect(refund.reload).to be_failed
    expect(checkout.order.reconciliation_exceptions).to exist(code: "refund_terminal_status_conflict")
  end

  [true, false].each do |includes_operation_amount|
    it "reconciles charge totals per captured payment when operation amounts are #{includes_operation_amount ? 'included' : 'absent'}" do
      checkout = create_pending_checkout(intent_id: "pi_multi_first")
      post_stripe_event("payment_intent.succeeded", { id: "pi_multi_first",
        amount_received: checkout.payment.amount_cents, currency: "usd" })
      second_payment = create(:payment, :succeeded, order: checkout.order,
        amount_cents: checkout.payment.amount_cents, provider_payment_id: "pi_multi_second")
      first_operation = { id: "re_multi_first", amount: 500, currency: "usd", status: "succeeded" }
      post_stripe_event("charge.refunded", { id: "ch_multi_first", payment_intent: "pi_multi_first",
        amount_refunded: 500, currency: "usd", refunds: { data: [first_operation] } })
      expect(response).to have_http_status(:ok)

      second_operation = { id: "re_multi_second", status: "succeeded" }
      second_operation.merge!(amount: 750, currency: "usd") if includes_operation_amount
      post_stripe_event("charge.refunded", { id: "ch_multi_second", payment_intent: "pi_multi_second",
        amount_refunded: 750, currency: "usd", refunds: { data: [second_operation] } })

      expect(response).to have_http_status(:ok)
      expect(checkout.payment.reload.refunds.succeeded.sum(:amount_cents)).to eq(500)
      expect(second_payment.reload.refunds.succeeded.sum(:amount_cents)).to eq(750)
      expect(checkout.order.reload.refunded_cents).to eq(1250)
      expect(checkout.order.refunds.succeeded.sum(:amount_cents)).to eq(1250)
      expect(checkout.order.refunds.joins(:refund_items).sum("refund_items.amount_cents")).to eq(1250)
      expect(checkout.order.reconciliation_exceptions.pluck(:code).uniq).to eq(["stripe_fee_adjustment_review_required"])
    end
  end

  it "ignores an older charge snapshot of exactly matching booked refunds after newer refunds succeeded" do
    checkout = create_pending_checkout(intent_id: "pi_delayed_charge_refunds")
    post_stripe_event("payment_intent.succeeded", { id: "pi_delayed_charge_refunds",
      amount_received: checkout.payment.amount_cents, currency: "usd" })
    allow(StripeService).to receive(:refund_payment).and_return(
      OpenStruct.new(id: "re_delayed_first", status: "succeeded"),
      OpenStruct.new(id: "re_delayed_second", status: "succeeded")
    )
    2.times { |i| Commerce::RefundCreator.call(order: checkout.order, amount_cents: 500, idempotency_key: "delayed-#{i}") }
    first_operation = { id: "re_delayed_first", amount: 500, currency: "usd", status: "succeeded" }
    second_operation = first_operation.merge(id: "re_delayed_second")
    post_stripe_event("charge.refunded", { id: "ch_delayed", payment_intent: "pi_delayed_charge_refunds",
      amount_refunded: 1000, currency: "usd", refunds: { data: [first_operation, second_operation] } })
    expect(response).to have_http_status(:ok)

    expect do
      post_stripe_event("charge.refunded", { id: "ch_delayed", payment_intent: "pi_delayed_charge_refunds",
        amount_refunded: 500, currency: "usd", refunds: { data: [first_operation] } })
    end.not_to change { [Refund.count, RefundItem.count] }

    expect(response).to have_http_status(:ok)
    expect(checkout.order.reload.refunded_cents).to eq(1000)
    expect(checkout.payment.reload.refunds.succeeded.sum(:amount_cents)).to eq(1000)
    expect(checkout.order.reconciliation_exceptions).to be_empty
  end

  it "defers an empty charge refund list to operation events without quarantining an old aggregate" do
    checkout = create_pending_checkout(intent_id: "pi_unexplained_lower_total")
    post_stripe_event("payment_intent.succeeded", { id: "pi_unexplained_lower_total",
      amount_received: checkout.payment.amount_cents, currency: "usd" })
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_booked", status: "succeeded"))
    Commerce::RefundCreator.call(order: checkout.order, amount_cents: 1000, idempotency_key: "booked")

    post_stripe_event("charge.refunded", { id: "ch_unexplained", payment_intent: "pi_unexplained_lower_total",
      amount_refunded: 500, currency: "usd", refunds: { data: [] } })

    expect(response).to have_http_status(:ok)
    expect(checkout.order.reload.refunded_cents).to eq(1000)
    expect(checkout.order.reconciliation_exceptions).to be_empty
  end

  it "defers a charge snapshot without embedded refunds and later books the operation event" do
    checkout = create_pending_checkout(intent_id: "pi_no_embedded_refunds")
    post_stripe_event("payment_intent.succeeded", { id: "pi_no_embedded_refunds",
      amount_received: checkout.payment.amount_cents, currency: "usd" })
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_unexpanded", status: "pending"))
    refund = Commerce::RefundCreator.call(order: checkout.order, amount_cents: 1000, idempotency_key: "unexpanded")

    post_stripe_event("charge.refunded", { id: "ch_unexpanded", payment_intent: "pi_no_embedded_refunds",
      amount_refunded: 1000, currency: "usd" })
    expect(response).to have_http_status(:ok)
    expect(refund.reload).to be_pending
    expect(checkout.order.reload.refunded_cents).to eq(0)
    expect(checkout.order.reconciliation_exceptions).to be_empty

    post_stripe_event("refund.updated", { id: "re_unexpanded", payment_intent: "pi_no_embedded_refunds",
      amount: 1000, currency: "usd", status: "succeeded" })
    expect(response).to have_http_status(:ok)
    expect(refund.reload).to be_succeeded
    expect(checkout.order.reload.refunded_cents).to eq(1000)
    expect(checkout.order.reconciliation_exceptions).to be_empty
  end

  it "quarantines a lower charge snapshot whose listed operation does not match its booked amount" do
    checkout = create_pending_checkout(intent_id: "pi_mismatched_lower_total")
    post_stripe_event("payment_intent.succeeded", { id: "pi_mismatched_lower_total",
      amount_received: checkout.payment.amount_cents, currency: "usd" })
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_mismatch_booked", status: "succeeded"))
    Commerce::RefundCreator.call(order: checkout.order, amount_cents: 1000, idempotency_key: "mismatch-booked")

    post_stripe_event("charge.refunded", { id: "ch_mismatch", payment_intent: "pi_mismatched_lower_total",
      amount_refunded: 500, currency: "usd", refunds: { data: [
        { id: "re_mismatch_booked", amount: 500, currency: "usd", status: "succeeded" }
      ] } })

    expect(response).to have_http_status(:ok)
    expect(checkout.order.reload.refunded_cents).to eq(1000)
    expect(checkout.order.reconciliation_exceptions).to exist(code: "refund_operation_mismatch")
    expect(checkout.order.reconciliation_exceptions).to exist(code: "provider_refund_total_decreased")
  end
  it "keeps a declined intent and its holds retryable and fulfills its later success exactly once" do
    checkout = create_pending_checkout(intent_id: "pi_retry_decline")
    holds = checkout.order.inventory_holds.pluck(:id)
    post_stripe_event("payment_intent.payment_failed", { id: "pi_retry_decline", status: "requires_payment_method",
      last_payment_error: { code: "card_declined" } })
    expect(checkout.order.reload).to be_pending
    expect(checkout.payment.reload).to be_pending
    expect(checkout.order.inventory_holds.active.pluck(:id)).to eq(holds)
    post_stripe_event("payment_intent.succeeded", { id: "pi_retry_decline", amount_received: checkout.payment.amount_cents,
      currency: "usd", status: "succeeded" })
    expect(checkout.order.reload).to be_completed
    expect(checkout.order.tickets.count).to eq(1)
    post_stripe_event("payment_intent.payment_failed", { id: "pi_retry_decline", status: "requires_payment_method" })
    expect(checkout.order.reload).to be_completed
    expect(checkout.payment.reload).to be_succeeded
  end

  it "quarantines mismatched signed environment or connected account before fulfillment" do
    SiteSetting.instance.update!(payment_mode: "test")
    checkout = create_pending_checkout(intent_id: "pi_context")
    post "/webhooks/stripe", params: { id: "evt_wrong_context", type: "payment_intent.succeeded", livemode: true,
      account: "acct_wrong", data: { object: { id: "pi_context", amount_received: checkout.payment.amount_cents,
        currency: "usd" } } }.to_json, headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:ok)
    expect(checkout.order.reload).to be_pending
    expect(checkout.order.tickets).to be_empty
    expect(checkout.order.reconciliation_exceptions).to exist(code: "payment_context_mismatch")
  end
  it "labels provider processing and ignores an older decline snapshot" do
    checkout = create_pending_checkout(intent_id: "pi_processing")
    { "evt_processing" => ["payment_intent.processing", "processing", 200],
      "evt_stale_decline" => ["payment_intent.payment_failed", "requires_payment_method", 100] }.each do |id, (type, state, created)|
      post "/webhooks/stripe", params: { id: id, type: type, created: created,
        data: { object: { id: "pi_processing", status: state } } }.to_json,
        headers: { "Content-Type" => "application/json" }
    end
    expect(checkout.payment.reload.provider_payload["status"]).to eq("processing")
    expect(checkout.order.reload).to be_pending
    expect(OrderPresenter.call(checkout.order)).to include(payment_resumable: false)
  end
end
