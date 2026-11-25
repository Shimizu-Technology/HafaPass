# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# One repayment workflow through the real entry points (docs/design/
# never-fulfilled-captures.md §6, §7; R-01…R-17, E-01…E-15). Examples marked
# `repayment_submitter: :active` run as A1-R2; the rest as A1-R1. Every
# provider POST is counted with its amount and key.
RSpec.describe Commerce::BuyerRepayment do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:posts) { [] }
  let(:lookups) { [] }
  let(:admin) { create(:user, :admin) }

  before do
    allow(StripeService).to receive(:refund_payment) do |intent_id, amount_cents:, idempotency_key:, **|
      posts << [amount_cents, idempotency_key]
      OpenStruct.new(id: "re_rp_#{posts.length}", status: "succeeded", amount: amount_cents, currency: "usd",
        payment_intent: intent_id, metadata: { "hafapass_refund_key" => idempotency_key })
    end
    allow(StripeService).to receive(:find_refund) do |_intent, idempotency_key:, **|
      lookups << idempotency_key
      nil
    end
    allow(StripeService).to receive(:verify_payment_context!)
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
    allow(Sentry).to receive(:capture_message)
  end

  # E1 fixture: one $12.00 ticket + $1.60 fee, captured after release.
  def late_capture(items: [[1200, 160, 0, 0]])
    order, payment, capture = classified_capture(items: items)
    issue = ReconciliationException.create!(order: order, payment: payment, code: "late_payment_success_after_hold_expiry")
    [order, payment, capture, issue]
  end

  def repay!(payment, **options)
    Commerce::LateCaptureRefund.call(payment: payment, **options)
  end

  def operations(payment)
    RepaymentOperation.where(payment_id: payment.id).in_sequence.pluck(:sequence, :state, :amount_cents, :submission_count)
  end

  describe "A1-R1 (inactive submitter)" do
    it "reserves nothing, sends nothing and records the wait at every outbound entry point" do
      order, payment, capture, issue = late_capture
      attempts = [
        -> { repay!(payment) },
        -> { repay!(payment, requested_by: admin, source: "admin_late_capture") },
        -> { Commerce::RefundCreator.call(order: order, payment: payment, amount_cents: 100, requested_by: admin, admin_initiated: true) },
        -> { Commerce::RefundCreator.call(order: order, payment: payment, reason: "fraudulent", idempotency_key: "early-fraud-warning:1") }
      ]
      attempts.each { |attempt| expect { attempt.call }.to raise_error(described_class::Waiting, /next release/) }
      expect { LateCaptureRefundJob.perform_now(payment.id) }.not_to raise_error

      expect(posts).to be_empty
      expect(Refund.where(payment: payment)).to be_empty
      expect(RepaymentOperation.count).to eq(0)
      Commerce::NeverFulfilledResolution.evaluate!(capture, trigger: "spec")
      expect(issue.reload.details).to include("wait_reason" => "repayment_inactive", "owed_cents" => 1360)
    end
  end

  describe "A1-R2", repayment_submitter: :active do
    it "returns the exact capture once, with operation 1's legacy key (R-01)" do
      _order, payment, capture, issue = late_capture
      2.times { LateCaptureRefundJob.perform_now(payment.id) }

      expect(posts).to eq([[1360, "late-capture:payment:#{payment.id}:op:1"]])
      expect(operations(payment)).to eq([[1, "succeeded", 1360, 1]])
      expect(ledger(capture)).to have_attributes(owed_cents: 0, excess_cents: 0)
      expect(issue.reload).to be_resolved
    end

    it "repays only what an external refund left (E1) and tops up after a partial success as a new operation" do
      order, payment, capture, issue = late_capture
      ingest_provider_refund!(payment, 500, id: "re_dash_500")
      Commerce::AdminOrderRefund.call(order: order, actor: admin, note: "Partial goodwill", idempotency_key: "half",
        amount_cents: 300)
      expect(posts).to eq([[300, "late-capture:payment:#{payment.id}:op:1"]])

      # The v2 counterexample: a success then a legitimate top-up is a new
      # operation with its own key, never "attempt 1" again.
      repay!(payment)
      expect(posts).to eq([[300, "late-capture:payment:#{payment.id}:op:1"], [560, "late-capture:payment:#{payment.id}:op:2"]])
      expect(operations(payment)).to eq([[1, "succeeded", 300, 1], [2, "succeeded", 560, 1]])
      expect(ledger(capture).owed_cents).to eq(0)
      expect(issue.reload).to be_resolved
      expect { repay!(payment) }.to raise_error(Commerce::LateCaptureRefund::NotApplicable)
    end

    it "replays the same admin request as the same operation" do
      order, payment, = late_capture
      2.times do
        Commerce::AdminOrderRefund.call(order: order, actor: admin, note: "Goodwill", idempotency_key: "same", amount_cents: 300)
      end
      expect(posts).to eq([[300, "late-capture:payment:#{payment.id}:op:1"]])
      expect(operations(payment)).to eq([[1, "succeeded", 300, 1]])
    end

    it "caps admin and refuses organizer refunds on the payment" do
      order, payment, = late_capture
      ingest_provider_refund!(payment, 1000, id: "re_dash_1000")
      expect do
        Commerce::AdminOrderRefund.call(order: order, actor: admin, note: "Too much", idempotency_key: "big", amount_cents: 400)
      end.to raise_error(Commerce::AdminOrderRefund::Error, /exceeds what is still owed/)
      expect(Commerce::AdminOrderRefund.options(order)).to include(refundable_cents: 360)
      expect do
        Commerce::RefundCreator.call(order: order, payment: payment, amount_cents: 100, organizer_initiated: true,
          requested_by: create(:user))
      end.to raise_error(described_class::Waiting, /HåfaPass returns this payment/)
      expect(posts).to be_empty
    end

    it "keeps a verified failure terminal and makes the next attempt a new operation (R-13)" do
      _order, payment, = late_capture
      allow(StripeService).to receive(:refund_payment).and_raise(Stripe::InvalidRequestError.new("Declined", "amount"))
      expect { repay!(payment) }.to raise_error(Commerce::RefundCreator::RefundError)
      expect(operations(payment)).to eq([[1, "failed_terminal", 1360, 1]])

      allow(StripeService).to receive(:refund_payment) do |intent_id, amount_cents:, idempotency_key:, **|
        posts << [amount_cents, idempotency_key]
        OpenStruct.new(id: "re_rp_ok", status: "succeeded", amount: amount_cents, currency: "usd", payment_intent: intent_id)
      end
      repay!(payment)
      expect(posts).to eq([[1360, "late-capture:payment:#{payment.id}:op:2"]])
    end

    it "never resends an unknown result inside the in-flight bound, then retries the same key once after it (R-14, R-15)" do
      _order, payment, = late_capture
      allow(StripeService).to receive(:refund_payment).and_raise(Stripe::APIConnectionError.new("timeout"))
      expect { repay!(payment) }.to raise_error(Commerce::RefundCreator::RefundError, /unknown/)
      expect(operations(payment)).to eq([[1, "unknown", 1360, 1]])

      expect { repay!(payment) }.to raise_error(described_class::Waiting, /unknown/)
      expect(lookups).to eq(["late-capture:payment:#{payment.id}:op:1"])
      expect(StripeService).to have_received(:refund_payment).once

      calls = []
      allow(StripeService).to receive(:refund_payment) do |intent_id, amount_cents:, idempotency_key:, **|
        calls << [amount_cents, idempotency_key]
        OpenStruct.new(id: "re_rp_retry", status: "succeeded", amount: amount_cents, currency: "usd", payment_intent: intent_id)
      end
      travel(described_class.in_flight_bound + 1.second) { repay!(payment) }
      expect(calls).to eq([[1360, "late-capture:payment:#{payment.id}:op:1"]])
      expect(operations(payment)).to eq([[1, "succeeded", 1360, 2]])
    end

    it "records an earlier send found by its key without sending again" do
      _order, payment, = late_capture
      allow(StripeService).to receive(:refund_payment).and_raise(Stripe::APIConnectionError.new("timeout"))
      expect { repay!(payment) }.to raise_error(Commerce::RefundCreator::RefundError)
      allow(StripeService).to receive(:find_refund).and_return(OpenStruct.new(id: "re_found", status: "succeeded",
        amount: 1360, currency: "usd", payment_intent: payment.provider_payment_id,
        metadata: { "hafapass_refund_key" => "late-capture:payment:#{payment.id}:op:1" }))

      repay!(payment)

      expect(StripeService).to have_received(:refund_payment).once
      expect(operations(payment)).to eq([[1, "succeeded", 1360, 1]])
      expect(payment.refunds.sole).to have_attributes(provider_refund_id: "re_found", status: "succeeded")
    end

    it "sends to finance, never a second operation, once the provider replay window has passed" do
      _order, payment, = late_capture
      allow(StripeService).to receive(:refund_payment).and_raise(Stripe::APIConnectionError.new("timeout"))
      expect { repay!(payment) }.to raise_error(Commerce::RefundCreator::RefundError)

      travel(Commerce::RefundCreator::PROVIDER_REPLAY_WINDOW + 1.minute) do
        expect { repay!(payment) }.to raise_error(Commerce::RefundCreator::RefundError, /finance must reconcile/)
      end
      expect(StripeService).to have_received(:refund_payment).once
      expect(operations(payment)).to eq([[1, "unknown", 1360, 1]])
      expect(described_class.availability(UnfulfilledCapture.find_by!(payment: payment)).wait_reason).to eq("refund_unknown")
    end

    it "cancels a reservation at the gate when money arrived after it was reserved (R-16)" do
      order, payment, capture, = late_capture
      Order.transaction do
        order.event.organization.lock!("FOR NO KEY UPDATE")
        order.event.lock!
        order.lock!
        described_class.reserve!(order: order, payment: payment, source: "automatic")
      end
      ingest_provider_refund!(payment, 1360, id: "re_dash_full")

      result = repay!(payment)

      expect(posts).to be_empty
      expect(result).to be_cancelled
      expect(operations(payment)).to eq([[1, "failed_terminal", 1360, 0]])
      expect(RepaymentOperation.sole.terminal_reason).to eq("superseded_before_submission")
      expect(ledger(capture)).to have_attributes(owed_cents: 0, excess_cents: 0)
    end

    it "waits while a refund is pending, a dispute is open or provider evidence is unrecorded" do
      _order, payment, capture, = late_capture
      ingest_provider_refund!(payment, 100, id: "re_pending", status: "pending")
      expect { repay!(payment) }.to raise_error(described_class::Waiting, /still pending/)
      ingest_provider_refund!(payment, 100, id: "re_pending", status: "succeeded")

      stripe_webhook!("charge.dispute.created", dispute_object(payment, "dp_open"))
      expect { repay!(payment) }.to raise_error(described_class::Waiting, /dispute is open/)
      expect(described_class.availability(capture.reload)).to have_attributes(owed_cents: 1260, in_flight_cents: 1360,
        available_cents: 0, wait_reason: "dispute_open")
      stripe_webhook!("charge.dispute.closed", dispute_object(payment, "dp_open", status: "won"))

      stripe_webhook!("refund.created", { id: "re_orphan", object: "refund", payment_intent: payment.provider_payment_id,
        amount: 50, currency: "usd", status: "succeeded", metadata: { hafapass_refund_key: "unknown-key" } })
      expect { repay!(payment) }.to raise_error(described_class::Waiting, /not recorded yet/)
      expect(posts).to be_empty
    end

    it "waits after Stripe refuses for a dispute until that dispute is recorded, then follows its outcome (§6.4)" do
      _order, payment, capture, issue = late_capture
      error = Stripe::InvalidRequestError.new("This charge is disputed", "charge", code: "charge_disputed")
      allow(StripeService).to receive(:refund_payment).and_raise(error)
      expect { repay!(payment) }.to raise_error(Commerce::RefundCreator::RefundError)
      expect(payment.refunds.sole.provider_payload).to include("provider_error_code" => "charge_disputed")

      expect { repay!(payment) }.to raise_error(described_class::Waiting, /because of a dispute/)
      lose_dispute!(payment, "dp_refused")

      expect(ledger(capture)).to have_attributes(owed_cents: 0)
      expect(issue.reload).to be_resolved
      expect(StripeService).to have_received(:refund_payment).once
    end

    it "closes on the failure of a pending refund after a full loss, and reopens after a late win (§7.1)" do
      _order, payment, capture, issue = late_capture
      ingest_provider_refund!(payment, 1360, id: "re_slow", status: "pending")
      lose_dispute!(payment, "dp_full")
      expect(issue.reload).to be_open
      ingest_provider_refund!(payment, 1360, id: "re_slow", status: "failed")
      expect(issue.reload).to be_resolved
      expect(AuditLog.find_by!(action: "reconciliation_exception.resolved", auditable: issue).metadata)
        .to include("trigger" => "refund_failed", "note" => "Repaid: refunds $0.00, lost disputes $13.60")

      expect { win_late!(payment, "dp_full") }.to have_enqueued_job(LateCaptureRefundJob).with(payment.id)
      reopened = ReconciliationException.open.find_by!(payment: payment, code: Commerce::NeverFulfilledResolution::REOPENED_CODE)
      expect(reopened.details).to include("previous_exception_id" => issue.id, "owed_cents" => 1360)
      perform_enqueued_jobs(only: LateCaptureRefundJob)
      expect(posts).to eq([[1360, "late-capture:payment:#{payment.id}:op:1"]])
      expect(reopened.reload).to be_resolved
      expect(ledger(capture).owed_cents).to eq(0)
    end

    it "alerts once per over-returned posting without holding finalization or payouts (P4, E2)" do
      order, payment, capture, issue = late_capture(items: [[800, 107, 0, 0], [400, 53, 0, 0]])
      ingest_provider_refund!(payment, 470, id: "re_e2")
      lose_dispute!(payment, "dp_e2", amount: 891)
      2.times { Commerce::NeverFulfilledResolution.evaluate!(capture.reload, trigger: "spec") }

      overpaid = ReconciliationException.where(payment: payment, code: Commerce::NeverFulfilledResolution::OVERPAID_CODE)
      expect(overpaid.count).to eq(1)
      expect(overpaid.sole).to have_attributes(actual_amount_cents: 1)
      expect(overpaid.sole.details).to include("platform_only" => true, "kind" => "dispute_loss", "gross_cents" => 891)
      expect(issue.reload).to be_resolved
      expect(Commerce::NeverFulfilledPayoutHold.blocked?(order.event)).to be(false)
      expect(Settlements::Finalizer.open_money_blocker(order.event)).not_to eq("Resolve open reconciliation exceptions")
      expect(OrganizationPayoutBalance.available_cents(order.event.organization)).to be >= 0
    end

    it "returns payment-scope B by itself and never touches A's valid sale" do
      order = create(:order, total_cents: 2000, subtotal_cents: 2000, service_fee_cents: 0)
      payment_a = create(:payment, :succeeded, order: order, amount_cents: 2000)
      order.update_columns(fulfilled_by_payment_id: payment_a.id)
      payment_b = create(:payment, :succeeded, order: order, amount_cents: 1500, provider_payment_id: "pi_rp_b")
      UnfulfilledCapture.create!(order: order, payment: payment_b, capture_scope: "payment", code: "unfulfilled_second_capture",
        captured_cents: 1500, currency: "usd", proceeds_cents: 1500, fee_cents: 0, organizer_fee_cents: 0, tax_cents: 0,
        processing_bearer: "platform", dispute_fee_bearer: "platform", allocation_policy: "item_record",
        policy_version: Commerce::NeverFulfilledClassification::POLICY_VERSION, provenance: "lifecycle")
      ReconciliationException.create!(order: order, payment: payment_b, code: "unfulfilled_second_capture")

      expect(EventCancellationRefunds.balance_cents(order)).to eq(2000)
      repay!(payment_b)

      expect(posts).to eq([[1500, "late-capture:payment:#{payment_b.id}:op:1"]])
      expect(order.reload).to have_attributes(status: "completed", refund_amount_cents: 0)
      expect(payment_a.reload).to be_succeeded
      expect(EventCancellationRefunds.balance_cents(order)).to eq(2000)
    end
  end

  describe "event cancellation estimates and runs" do
    it "leave a fenced payment to the repayment workflow and keep the same total everywhere" do
      order, payment, = late_capture
      event = order.event
      sale = create(:order, event: event, total_cents: 2500, subtotal_cents: 2500, service_fee_cents: 0)
      create(:payment, :succeeded, order: sale, amount_cents: 2500)
      order.update_columns(status: Order.statuses[:partially_refunded])

      balances = EventCancellationRefunds.balances(event, exclude_nonlive: false).index_by { |entry| entry[:order_id] }
      expect(balances.fetch(order.id)).to include(amount_cents: 0, captured_cents: 0, repayment_workflow: true)
      expect(balances.fetch(sale.id)).to include(amount_cents: 2500, repayment_workflow: false)
      expect(EventCancellationRefunds.balance_cents(order)).to eq(0)
      expect(EventCancellationRefunds.preview(event)).to include(count: 1, total_cents: 2500)

      run = EventCancellationRefunds.prepare!(event: event, actor: admin)
      expect(run.items.find_by!(order: order)).to have_attributes(status: "skipped",
        last_error: EventCancellationRefunds::REPAYMENT_WORKFLOW_MESSAGE)
      expect(Refund.where(payment: payment)).to be_empty
    end
  end

  describe "legacy refunds past the gate (R1 adjudication, M-07)" do
    def legacy_refund!(payment, failure_code:)
      before_repayment_fence do
        payment.refunds.create!(order: payment.order, provider: "stripe", idempotency_key: "late-capture:payment:#{payment.id}",
          amount_cents: payment.amount_cents, currency: "usd", status: :pending, reason: "late_capture_refund",
          failure_code: failure_code)
      end
    end

    it "records a request Stripe has, adopted as operation 1, with no POST" do
      _order, payment, capture, = late_capture
      refund = legacy_refund!(payment, failure_code: "provider_result_unknown")
      allow(StripeService).to receive(:find_refund).and_return(OpenStruct.new(id: "re_legacy", status: "succeeded",
        amount: 1360, currency: "usd", payment_intent: payment.provider_payment_id,
        metadata: { "hafapass_refund_key" => refund.idempotency_key }))

      expect(Commerce::RepaymentAdjudication.call(refund).outcome).to eq("recorded")
      expect(refund.reload).to have_attributes(status: "succeeded", provider_refund_id: "re_legacy")
      expect(operations(payment)).to eq([[1, "succeeded", 1360, 1]])
      expect(RepaymentOperation.sole).to have_attributes(adopted: true, source: "adoption")
      expect(ledger(capture).owed_cents).to eq(0)
      expect(posts).to be_empty
    end

    it "never adjudicates a request as absent inside the in-flight bound, and cancels it after" do
      _order, payment, = late_capture
      refund = legacy_refund!(payment, failure_code: "provider_result_unknown")

      expect(Commerce::RepaymentAdjudication.call(refund).outcome).to eq("in_flight")
      expect(refund.reload).to be_pending
      result = travel(described_class.in_flight_bound + 1.second) { Commerce::RepaymentAdjudication.call(refund) }
      expect(result.outcome).to eq("provider_request_absent")
      expect(refund.reload).to have_attributes(status: "cancelled", failure_code: "provider_request_absent")
      expect(operations(payment)).to eq([[1, "failed_terminal", 1360, 1]])
      expect(posts).to be_empty
    end

    it "cancels a reservation that never passed the gate at once" do
      _order, payment, = late_capture
      refund = legacy_refund!(payment, failure_code: nil)
      expect(Commerce::RepaymentAdjudication.call(refund).outcome).to eq("fenced_reservation_unsent")
      expect(lookups).to be_empty
      expect(operations(payment)).to eq([[1, "failed_terminal", 1360, 0]])
    end

    it "is enqueued for its bound when a repayment waits on it, and R2 then uses operation 2", repayment_submitter: :active do
      _order, payment, = late_capture
      refund = legacy_refund!(payment, failure_code: "provider_result_unknown")
      expect { LateCaptureRefundJob.perform_now(payment.id) }.to have_enqueued_job(RepaymentAdjudicationJob).with(refund.id)
      expect(posts).to be_empty

      travel(described_class.in_flight_bound + 1.second) do
        perform_enqueued_jobs(only: RepaymentAdjudicationJob)
        repay!(payment)
      end
      expect(posts).to eq([[1360, "late-capture:payment:#{payment.id}:op:2"]])
    end
  end

  describe "evidence before binding or capture (§7.2)" do
    it "waits at the gate, replays the stored notice once the payment is bound, and is idempotent", repayment_submitter: :active do
      _order, payment, capture, = late_capture
      intent = payment.provider_payment_id
      payment.update_columns(provider_payment_id: nil)
      # A signed test-mode notice for this payment's intent, delivered before the binding.
      payload = { "id" => "evt_before_bind", "type" => "refund.created", "livemode" => false,
        "data" => { "object" => { "id" => "re_before_bind", "object" => "refund", "payment_intent" => intent, "amount" => 400,
          "currency" => "usd", "status" => "succeeded", "metadata" => {} } } }
      StripeWebhookProcessor.call(event: Stripe::Event.construct_from(payload), payload: payload)
      orphan = ReconciliationException.open.find_by!(code: "refund_operation_not_found", payment_id: nil)

      expect { payment.update!(provider_payment_id: intent) }.to have_enqueued_job(ProviderEvidenceReplayJob).with(payment.id)
      expect { repay!(payment) }.to raise_error(described_class::Waiting, /not recorded yet/)
      perform_enqueued_jobs(only: ProviderEvidenceReplayJob)

      expect(orphan.reload).to be_resolved
      expect(orphan.webhook_event.replayed_at).to be_present
      expect(posting_rows(capture.reload)).to eq([["refund", 400, 400, 0, [353, 47, 0, 0]]])
      expect(StripeWebhookProcessor.replay!(orphan.webhook_event, payment: payment)).to eq(:nothing)
      repay!(payment)
      expect(posts).to eq([[960, "late-capture:payment:#{payment.id}:op:1"]])
    end

    it "keeps the orphan open when the stored object belongs to another payment context" do
      _order, payment, = late_capture
      payload = { "id" => "evt_ctx", "type" => "refund.created", "livemode" => true,
        "data" => { "object" => { "id" => "re_ctx", "object" => "refund", "payment_intent" => payment.provider_payment_id,
          "amount" => 100, "currency" => "usd", "status" => "succeeded" } } }
      receipt = WebhookEvent.create!(provider: "stripe", provider_event_id: "evt_ctx", event_type: "refund.created",
        payload: payload, status: :processed, processed_at: Time.current)
      orphan = ReconciliationException.create!(webhook_event: receipt, code: "refund_operation_not_found")

      expect(StripeWebhookProcessor.replay!(receipt, payment: payment)).to eq(:payment_context_mismatch)
      expect(orphan.reload).to be_open
      expect(orphan.details).to include("replay_blocked" => "payment_context_mismatch")
      expect(Refund.where(provider_refund_id: "re_ctx")).to be_empty
    end
  end
end
