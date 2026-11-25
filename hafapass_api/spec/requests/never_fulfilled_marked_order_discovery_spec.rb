# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# A1-R1 boundary fix 1 (docs/design/never-fulfilled-captures.md §6.9): A's
# late capture marks the order never fulfilled, and a partial (or full)
# refund on A moves it to partially refunded (or refunded) with the marker
# kept. 7bcd97c2 then takes its completed-sale branch for a later capture B:
# it marks B captured and acknowledges the receipt with no exception. The
# database counts B as an overlap capture on the marked order, so the
# event's payouts and statements are held from B's capture, verify counts it,
# and redelivery, the scheduled job and an authorized reconcile classify it
# as another order-scope capture from its exact receipt, or quarantine it.
# B's own liability keeps the event held after A is repaid and closed, and
# the hold keeps B's capture as its start (fix 2).
RSpec.describe "Overlap capture on a marked never-fulfilled order", type: :request do
  include ActiveJob::TestHelper

  let(:organizer_profile) { create(:organizer_profile, :verified) }
  let(:event) { create(:event, :published, organizer_profile: organizer_profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 1200, quantity_available: 10, quantity_sold: 0) }
  let(:admin) { create(:user, :admin) }

  before do
    SiteSetting.instance.update!(payment_mode: "test")
    allow(StripeService).to receive_messages(card_only_intent?: true, payment_enabled?: true, verify_payment_context!: nil)
    allow(StripeService).to receive(:cancel_payment_intent)
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(Sentry).to receive(:capture_message)
    allow(StripeService).to receive(:refund_payment).and_raise("no outbound refund in these examples")
  end

  def post_stripe_event(type, object, event_id:)
    post "/webhooks/stripe", params: { id: event_id, type: type, data: { object: object } }.to_json,
      headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:ok)
  end

  def capture_payload(payment, event_id)
    { "id" => event_id, "type" => "payment_intent.succeeded", "livemode" => false,
      "data" => { "object" => { "id" => payment.provider_payment_id, "status" => "succeeded", "amount" => payment.amount_cents,
        "amount_received" => payment.amount_cents, "currency" => "usd" } } }
  end

  def deliver!(payload)
    StripeWebhookProcessor.call(event: Stripe::Event.construct_from(payload), payload: payload)
  end

  def refund_on!(payment, id, amount)
    post_stripe_event("refund.created", { id: id, object: "refund", payment_intent: payment.provider_payment_id,
      amount: amount, currency: "usd", status: "succeeded" }, event_id: "evt_#{id}")
  end

  # A's checkout fails, A's capture arrives after the release: this release
  # classifies it in order scope and marks the order.
  def marked_order
    allow(StripeService).to receive(:create_payment_intent).and_return(OpenStruct.new(id: "pi_mk_a",
      client_secret: "pi_mk_a_secret", allowed_payment_method_types: ["card"], payment_method_types: ["card"]))
    result = Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: "buyer@example.com", buyer_name: "Buyer")
    post_stripe_event("payment_intent.payment_failed", { id: "pi_mk_a", amount: result.payment.amount_cents, currency: "usd" },
      event_id: "evt_mk_a_failed")
    deliver!(capture_payload(result.payment, "evt_mk_a"))
    order = result.order.reload
    expect(order.never_fulfilled_at).to be_present
    expect(UnfulfilledCapture.find_by!(payment: result.payment).capture_scope).to eq("order")
    [order, result.payment.reload]
  end

  def second_payment(order, a, intent: "pi_mk_b", amount_cents: order.total_cents)
    order.payments.create!(provider: "stripe", provider_environment: "test",
      provider_platform_account_id: a.provider_platform_account_id, provider_payment_id: intent,
      idempotency_key: "second:#{order.id}:#{intent}", amount_cents: amount_cents, currency: "usd", status: :pending)
  end

  # What 7bcd97c2 writes for B's success on an order in a sale status
  # (completed, partially refunded or refunded): the signed receipt (without
  # the identity columns), its payment event, B captured and the receipt
  # processed. No exception and no classification.
  def legacy_acknowledge!(payment, event_id: "evt_mk_b_old", payload: capture_payload(payment, event_id))
    receipt = WebhookEvent.create!(provider: "stripe", provider_event_id: event_id, event_type: "payment_intent.succeeded",
      payload: payload, provider_created_at: 1.second.ago, status: :processing, attempts: 1)
    receipt.create_payment_event!(payment: payment, event_type: "payment_intent.succeeded", amount_cents: payment.amount_cents,
      currency: "usd", provider_created_at: receipt.provider_created_at, data: {})
    payment.update!(status: :succeeded, succeeded_at: Time.current)
    receipt.update!(status: :processed, processed_at: Time.current)
    receipt
  end

  def verify_counts
    pending = Commerce::NeverFulfilledReconcile.call(dry_run: true).assessments.reject { |item| %w[held reconciled].include?(item.disposition) }
    [pending.map { |item| [item.payment_id, item.disposition] }, Commerce::NeverFulfilledReconcile.overlap_capture_ids]
  end

  def block_start
    Commerce::NeverFulfilledPayoutHold.block_started_at(event)
  end

  it "holds from B's capture, classifies B in order scope on redelivery, and keeps B held after A closes" do
    order, a = marked_order
    refund_on!(a, "re_mk_a_part", 500)
    expect(order.reload).to have_attributes(status: "partially_refunded", never_fulfilled_at: be_present)
    a_issue = ReconciliationException.find_by!(payment: a, code: "late_payment_success_after_inventory_release")
    a_hold = block_start
    # A's own exception was written in A's capture transaction.
    expect(a_hold).to be_within(0.001).of(a_issue.created_at)

    # Once A's own hold is closed (below), only B can hold the event. Before
    # the fix nothing counted B at all.
    b = second_payment(order, a)
    receipt = legacy_acknowledge!(b)
    expect(b.reload.capture_recorded_at).to be_present
    expect(ReconciliationException.where(payment: b)).to be_empty
    expect(Commerce::NeverFulfilledReconcile.overlap_capture?(b)).to be(true)
    expect(verify_counts).to eq([[[b.id, "discover"]], [b.id]])
    expect(ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(["SELECT hafapass_overlap_hold_start(?)", b.id])
    )).to be_within(0.001).of(b.capture_recorded_at)

    # Stripe (or an operator replay) redelivers B's processed notice.
    expect(deliver!(receipt.payload)).to have_attributes(id: receipt.id, status: "processed")

    capture = UnfulfilledCapture.find_by!(payment: b)
    expect(capture).to have_attributes(capture_scope: "order", code: "late_payment_success_after_inventory_release",
      provenance: "lifecycle", captured_cents: order.total_cents, capture_recorded_at: b.capture_recorded_at)
    expect(capture.provenance_evidence).to include("source" => "signed_webhook", "webhook_event_id" => receipt.id,
      "provider_object_id" => "pi_mk_b", "discovered_by" => "reconcile", "receipt_facts" => "payload")
    b_issue = ReconciliationException.find_by!(payment: b, code: "late_payment_success_after_inventory_release")
    expect(b_issue).to be_open
    expect(b_issue.details).to include("second_capture" => true)
    # The hold B opened keeps B's capture as its start.
    expect(b_issue.reload.hold_started_at).to be_within(0.001).of(b.capture_recorded_at)
    expect(b_issue.created_at).to be > b.capture_recorded_at
    expect(verify_counts).to eq([[], []])
    expect(order.reload).to have_attributes(status: "partially_refunded", refund_amount_cents: 500)
    expect(order.tickets.where.not(status: :cancelled)).to be_empty
    expect(Commerce::BuyerRepayment.availability(capture).owed_cents).to eq(order.total_cents)

    # Repeated deliveries and the scheduled job change nothing.
    expect do
      deliver!(receipt.payload)
      RefundReconciliationJob.perform_now
    end.not_to(change { [UnfulfilledCapture.count, ReconciliationException.count] })

    # A is repaid in full and its own hold closes; B's liability still holds.
    refund_on!(a, "re_mk_a_rest", order.total_cents - 500)
    expect(a_issue.reload).to be_resolved
    expect(order.reload).to have_attributes(status: "refunded", never_fulfilled_at: be_present)
    expect(b_issue.reload).to be_open
    expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(true)
    expect(block_start).to be_within(0.001).of(b.capture_recorded_at)
    event.update_columns(status: Event.statuses.fetch("completed"))
    expect { ActiveRecord::Base.transaction(requires_new: true) { Settlements::Finalizer.call(event: event, actor: admin) } }
      .to raise_error(StandardError, /reconciliation exceptions|Repayment fence/)
    expect { ActiveRecord::Base.transaction(requires_new: true) { Legacy7bcd97c2.settlements_finalizer.call(event: event, actor: admin) } }
      .to raise_error(StandardError, /reconciliation exceptions|Repayment fence/)
  end

  it "discovers B on a fully refunded marked order by the scheduled job, with the same hold start" do
    order, a = marked_order
    refund_on!(a, "re_mk_full", order.total_cents)
    a_issue = ReconciliationException.find_by!(payment: a, code: "late_payment_success_after_inventory_release")
    expect(a_issue.reload).to be_resolved
    expect(order.reload).to have_attributes(status: "refunded", never_fulfilled_at: be_present)
    expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(false)

    b = second_payment(order, a)
    legacy_acknowledge!(b)
    b.reload
    before_discovery = block_start
    expect(before_discovery).to be_within(0.001).of(b.capture_recorded_at)
    expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(true)

    RefundReconciliationJob.perform_now

    expect(UnfulfilledCapture.find_by!(payment: b).capture_scope).to eq("order")
    expect(ReconciliationException.where(payment: b).pluck(:code, :status))
      .to eq([%w[late_payment_success_after_inventory_release open]])
    expect(block_start).to eq(before_discovery)
    expect(verify_counts).to eq([[], []])
  end

  it "quarantines B when its receipt cannot prove it, or when it cannot be an order-scope capture, keeping the start" do
    order, a = marked_order
    refund_on!(a, "re_mk_q", 300)
    unproven = second_payment(order, a, intent: "pi_mk_unproven")
    legacy_acknowledge!(unproven, event_id: "evt_mk_unproven", payload: {})
    # A different amount than the order: not an order-scope capture of it.
    odd = second_payment(order, a, intent: "pi_mk_odd", amount_cents: order.total_cents + 100)
    legacy_acknowledge!(odd, event_id: "evt_mk_odd")
    expect(verify_counts.last).to eq([unproven.id, odd.id])
    starts = [unproven, odd].map { |payment| payment.reload.capture_recorded_at }
    before_discovery = block_start

    Commerce::NeverFulfilledReconcile.call(dry_run: false, payment_ids: [unproven.id, odd.id])

    expect(ReconciliationException.find_by!(payment: unproven, code: Commerce::NeverFulfilledClassification::QUARANTINE_CODE)
      .details).to include("reason" => "receipt_identity_missing", "discovered_by" => "reconcile")
    expect(ReconciliationException.find_by!(payment: odd, code: Commerce::NeverFulfilledClassification::QUARANTINE_CODE)
      .details).to include("reason" => "order_amount_mismatch")
    expect(UnfulfilledCapture.where(payment: [unproven, odd])).to be_empty
    # Every item discovery wrote keeps the capture's start, so closing one
    # of them (B's repayment closes the late-capture exception) cannot move
    # the cutoff while the quarantine stays open.
    expect(ReconciliationException.where(payment: odd).order(:id).pluck(:code))
      .to eq(["late_payment_success_after_inventory_release", Commerce::NeverFulfilledClassification::QUARANTINE_CODE])
    [unproven, odd].zip(starts).each do |payment, start|
      ReconciliationException.where(payment: payment).find_each do |issue|
        expect(issue.hold_started_at).to be_within(0.001).of(start)
      end
      expect(Commerce::BuyerRepayment.fenced_payment?(payment)).to be(true)
    end
    expect(block_start).to eq(before_discovery)
    # No overlap capture is left. The odd-amount capture is what this
    # release's own lifecycle leaves for one it receives directly: a
    # late-capture exception with a quarantine, which the backfill reports
    # for finance review (it stays held either way).
    expect(verify_counts).to eq([[[odd.id, "ambiguous"]], []])
  end

  it "stamps the start only from the payment's own open hold, never from a writer, and never changes it" do
    order, a = marked_order
    issue = ReconciliationException.find_by!(payment: a, code: "late_payment_success_after_inventory_release")
    # Written in A's own capture transaction, before A overlapped anything.
    expect(issue.hold_started_at).to be_nil
    # Added while A's hold is open: keeps that hold's start.
    reopened = ReconciliationException.create!(order: order, payment: a, code: Commerce::NeverFulfilledResolution::REOPENED_CODE,
      hold_started_at: 1.year.ago)
    expect(reopened.reload.hold_started_at).to be_within(0.001).of(issue.created_at)
    expect { ActiveRecord::Base.transaction(requires_new: true) { ReconciliationException.where(id: reopened.id).update_all(hold_started_at: 1.year.ago) } }
      .to raise_error(ActiveRecord::StatementInvalid, /hold start is recorded once/)

    # After every item on A closed, a new episode starts at its own time,
    # whatever a writer supplies.
    [issue, reopened].each { |item| item.reload.resolve_with_evidence! }
    later = ReconciliationException.create!(order: order, payment: a, code: Commerce::NeverFulfilledResolution::REOPENED_CODE,
      hold_started_at: 1.year.ago)
    expect(later.reload.hold_started_at).to be_nil
    expect(Commerce::NeverFulfilledPayoutHold.block_started_at(event)).to be_within(0.001).of(later.created_at)
  end
end
