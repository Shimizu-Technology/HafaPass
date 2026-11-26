# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# A1-R1 review findings 4 and 5 and the R2 gate gaps (docs/design/
# never-fulfilled-captures.md §6.7):
#   - a fenced payment's pending refund is bound to a Stripe refund only by
#     exact identity, on every resync path and for every writer;
#   - unbound provider evidence stays matchable after its payload is cleared,
#     and keeps its hold;
#   - aggregate recovery re-evaluates the capture after resolving its hold;
#   - an unknown retry is never sent for more than is owed now, and a
#     dispute refusal waits for the dispute that caused it.
RSpec.describe "Repayment identity and evidence" do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:posts) { [] }
  let(:admin) { create(:user, :admin) }

  before do
    allow(StripeService).to receive(:refund_payment) do |intent_id, amount_cents:, idempotency_key:, **|
      posts << [amount_cents, idempotency_key]
      OpenStruct.new(id: "re_id_#{posts.length}", status: "succeeded", amount: amount_cents, currency: "usd",
        payment_intent: intent_id, metadata: { "hafapass_refund_key" => idempotency_key })
    end
    allow(StripeService).to receive(:find_refund).and_return(nil)
    allow(StripeService).to receive(:verify_payment_context!)
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
    allow(Sentry).to receive(:capture_message)
  end

  def late_capture(items: [[1200, 160, 0, 0]])
    order, payment, capture = classified_capture(items: items)
    issue = ReconciliationException.create!(order: order, payment: payment, code: "late_payment_success_after_hold_expiry")
    [order, payment, capture, issue]
  end

  def legacy_refund!(payment, failure_code: "provider_result_unknown")
    before_repayment_fence do
      payment.refunds.create!(order: payment.order, provider: "stripe", idempotency_key: "late-capture:payment:#{payment.id}",
        amount_cents: payment.amount_cents, currency: "usd", status: :pending, reason: "late_capture_refund",
        failure_code: failure_code)
    end
  end

  def dashboard_refund(payment, id: "re_dashboard", amount: payment.amount_cents)
    OpenStruct.new(id: id, status: "succeeded", amount: amount, currency: "usd", payment_intent: payment.provider_payment_id,
      created: Time.current.to_i, metadata: {})
  end

  describe "exact identity for a fenced pending refund (finding 4)" do
    it "never binds a keyless Dashboard refund by amount and date, on Check Stripe status or the scheduled resync" do
      _order, payment, = late_capture
      refund = legacy_refund!(payment)
      calls = []
      allow(StripeService).to receive(:find_refund) do |_intent, idempotency_key:, **options|
        calls << [idempotency_key, options.slice(:expected_amount_cents, :expected_created_at).compact.keys]
        nil # Stripe has only the keyless Dashboard refund, which a key-only lookup never returns
      end

      expect do
        RefundReconciliationActions.call(type: "refund", id: refund.id, action: "resync", actor: admin)
      end.to raise_error(RefundReconciliationActions::ActionError, /no matching refund/)
      RefundReconciliationJob.perform_now rescue nil
      expect(calls).to all(eq([refund.idempotency_key, []]))
      expect(calls).not_to be_empty
      expect(refund.reload).to have_attributes(status: "pending", provider_refund_id: nil)
    end

    it "refuses a binding without exact identity in the application and in the database" do
      _order, payment, = late_capture
      refund = legacy_refund!(payment)

      expect { Commerce::RefundCreator.reconcile_refund!(refund: refund, provider_refund: dashboard_refund(payment)) }
        .to raise_error(Commerce::RefundCreator::RefundError, /does not carry this request's identity/)
      expect(refund.reload.provider_refund_id).to be_nil
      expect(ReconciliationException.where(payment: payment, code: "refund_operation_mismatch").sole.details)
        .to include("reason" => "identity_unproven", "provider_refund_id" => "re_dashboard")

      # What an older release's amount-and-date resync would write.
      expect { ActiveRecord::Base.transaction(requires_new: true) { refund.update!(provider_refund_id: "re_dashboard") } }
        .to raise_error(ActiveRecord::StatementInvalid, /exact provider identity/)

      # The Dashboard refund is still recorded, as its own movement.
      ingest_provider_refund!(payment, 1360, id: "re_dashboard")
      expect(payment.refunds.where(provider_refund_id: "re_dashboard").sole.idempotency_key).to eq("provider:stripe:refund:re_dashboard")
      expect(refund.reload).to have_attributes(status: "pending", provider_refund_id: nil)
    end

    it "accepts the request's own Stripe refund found by its key" do
      _order, payment, = late_capture
      refund = legacy_refund!(payment)
      allow(StripeService).to receive(:find_refund).and_return(OpenStruct.new(id: "re_by_key", status: "succeeded",
        amount: 1360, currency: "usd", payment_intent: payment.provider_payment_id,
        metadata: { "hafapass_refund_key" => refund.idempotency_key }))

      RefundReconciliationActions.call(type: "refund", id: refund.id, action: "resync", actor: admin)
      expect(refund.reload).to have_attributes(status: "succeeded", provider_refund_id: "re_by_key")
    end
  end

  describe "unbound evidence after its payload is cleared (finding 5)" do
    it "still matches the payment, holds repayment and binds the orphan to the payment it names" do
      _order, payment, = late_capture
      intent = payment.provider_payment_id
      payment.update_columns(provider_payment_id: nil)
      payload = { "id" => "evt_cleared", "type" => "refund.created", "livemode" => false,
        "data" => { "object" => { "id" => "re_cleared", "object" => "refund", "payment_intent" => intent, "amount" => 400,
          "currency" => "usd", "status" => "succeeded", "metadata" => {} } } }
      StripeWebhookProcessor.call(event: Stripe::Event.construct_from(payload), payload: payload)
      orphan = ReconciliationException.open.find_by!(code: "refund_operation_not_found", payment_id: nil)
      receipt = orphan.webhook_event
      expect(receipt).to have_attributes(provider_payment_intent_id: intent, provider_object_id: "re_cleared",
        provider_livemode: false, provider_amount_cents: 400, provider_currency: "usd")

      # Retention or a privacy request clears the payload and the details.
      WebhookEvent.where(id: receipt.id).update_all(payload: {})
      receipt.reload
      orphan.update_columns(details: {})
      payment.update_columns(provider_payment_id: intent)

      expect(Commerce::BuyerRepayment.unreplayed_evidence?(payment)).to be(true)
      expect(StripeWebhookProcessor.replayable_receipts(payment)).to eq([receipt])
      expect(StripeWebhookProcessor.replay!(receipt, payment: payment)).to eq(:payment_context_mismatch)
      expect(orphan.reload).to have_attributes(status: "open", payment_id: payment.id, order_id: payment.order_id)
      expect(Commerce::BuyerRepayment.orphan_payment(orphan)).to eq(payment)
      controller = Api::V1::Admin::ReconciliationExceptionsController.new
      expect(controller.send(:resolution_rule, orphan)[:blocked]).to match(/a note cannot close it/)
    end
  end

  describe "aggregate recovery (finding 5)" do
    it "re-evaluates the capture under the order lock after resolving the aggregate hold" do
      _order, payment, capture, issue = late_capture
      ReconciliationException.create!(order: payment.order, payment: payment, code: "refund_aggregate_requires_reconciliation",
        actual_amount_cents: 1360)
      gap = ReconciliationException.open.find_by!(payment: payment, code: "refund_aggregate_requires_reconciliation")
      allow(StripeService).to receive(:list_refunds).and_return([dashboard_refund(payment, id: "re_aggregate")])

      Commerce::ExternalRefundRecovery.call(issue: gap)

      expect(gap.reload).to be_resolved
      expect(ledger(capture)).to have_attributes(owed_cents: 0)
      # Before, ingestion evaluated while the gap was still open, so the
      # capture's own exception stayed open after the gap resolved.
      expect(issue.reload).to be_resolved
      expect(AuditLog.find_by!(auditable: issue, action: "reconciliation_exception.resolved").metadata)
        .to include("trigger" => "aggregate_recovered")
    end
  end

  describe "R2 gate (dormant in A1-R1)", repayment_submitter: :active do
    it "never resends an unknown operation for more than is owed now" do
      _order, payment, capture, = late_capture
      allow(StripeService).to receive(:refund_payment).and_raise(Stripe::APIConnectionError.new("lost response"))
      expect { Commerce::LateCaptureRefund.call(payment: payment) }.to raise_error(Commerce::RefundCreator::RefundError)
      operation = RepaymentOperation.sole
      expect(operation.state).to eq("unknown")

      # Money came back another way meanwhile (a Dashboard refund of $5.00).
      ingest_provider_refund!(payment, 500, id: "re_meanwhile")
      expect(ledger(capture).owed_cents).to eq(860)
      allow(StripeService).to receive(:refund_payment).and_raise("must not resend")

      travel(Commerce::BuyerRepayment.in_flight_bound + 1.second) do
        expect { Commerce::LateCaptureRefund.call(payment: payment) }
          .to raise_error(Commerce::BuyerRepayment::Waiting, /exceeds what is still owed/)
      end
      expect(operation.reload).to have_attributes(state: "unknown", submission_count: 1)
    end

    it "waits after a dispute refusal for the dispute that was open when Stripe refused, never an older closed one" do
      _order, payment, = late_capture
      Dispute.create!(order: payment.order, payment: payment, provider: "stripe", provider_dispute_id: "dp_old",
        amount_cents: 100, currency: "usd", status: :won, opened_at: 3.hours.ago, closed_at: 2.hours.ago)
      error = Stripe::InvalidRequestError.new("This charge is disputed", "charge", code: "charge_disputed")
      allow(StripeService).to receive(:refund_payment).and_raise(error)
      expect { Commerce::LateCaptureRefund.call(payment: payment) }.to raise_error(Commerce::RefundCreator::RefundError)
      refused_at = payment.refunds.failed.sole.failed_at
      check = -> { Commerce::BuyerRepayment.send(:disputed_refund_unreconciled?, payment) }

      # The only recorded dispute closed before the refusal: the cause is not recorded yet.
      expect(check.call).to be(true)
      expect { Commerce::LateCaptureRefund.call(payment: payment) }.to raise_error(Commerce::BuyerRepayment::Waiting, /because of a dispute/)
      cause = Dispute.create!(order: payment.order, payment: payment, provider: "stripe", provider_dispute_id: "dp_cause",
        amount_cents: 1360, currency: "usd", status: :open, opened_at: refused_at - 1.minute)
      expect(check.call).to be(true)
      # Another dispute opened after the refusal closing changes nothing.
      Dispute.create!(order: payment.order, payment: payment, provider: "stripe", provider_dispute_id: "dp_later",
        amount_cents: 100, currency: "usd", status: :won, opened_at: refused_at + 1.minute, closed_at: refused_at + 2.minutes)
      expect(check.call).to be(true)
      cause.update!(status: :won, closed_at: Time.current)
      expect(check.call).to be(false)
    end

    it "lists the R1 backlog and enqueues it only when the submitter is active" do
      _order, payment, = late_capture
      report = nil
      expect { report = Commerce::RepaymentBacklog.call(enqueue: true) }.to have_enqueued_job(LateCaptureRefundJob).with(payment.id)
      expect(report.entries.map(&:payment_id)).to eq([payment.id])
      expect(report.enqueued).to eq(1)
    end
  end

  it "only counts the backlog in A1-R1", repayment_submitter: :inactive do
    late_capture
    expect { expect(Commerce::RepaymentBacklog.call(enqueue: true).enqueued).to eq(0) }.not_to have_enqueued_job(LateCaptureRefundJob)
  end
end
