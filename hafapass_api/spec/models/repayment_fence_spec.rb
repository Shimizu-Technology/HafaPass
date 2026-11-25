# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# The A1-R1 compatibility fence and repayment-operation integrity
# (docs/design/never-fulfilled-captures.md §6.3, §10.1, §10.3 M-05…M-07).
# "Old worker" examples run the verbatim 7bcd97c2 RefundCreator and
# LateCaptureRefund (spec/support/legacy_7bcd97c2) against this schema and
# count the Stripe refund POSTs it would make.
RSpec.describe "Repayment fence" do
  let(:posts) { [] }
  let(:legacy_creator) { Legacy7bcd97c2.refund_creator }
  let(:legacy_late_capture) { Legacy7bcd97c2.late_capture_refund }
  let(:connection) { ActiveRecord::Base.connection }

  before do
    allow(StripeService).to receive(:refund_payment) do |intent_id, amount_cents:, idempotency_key:, **|
      posts << [intent_id, amount_cents, idempotency_key]
      OpenStruct.new(id: "re_fence_#{posts.length}", status: "succeeded", amount: amount_cents, currency: "usd",
        payment_intent: intent_id, metadata: { "hafapass_refund_key" => idempotency_key })
    end
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
  end

  def isolated
    connection.transaction(requires_new: true) do
      yield
      raise ActiveRecord::Rollback
    end
  end

  def late_capture(amount_items: [[1200, 160, 0, 0]])
    order, payment, capture = classified_capture(items: amount_items)
    issue = ReconciliationException.create!(order: order, payment: payment, code: "late_payment_success_after_hold_expiry")
    [order, payment, capture, issue]
  end

  it "keeps the fence codes equal to the application's" do
    expect(FinancialIntegrity::FENCED_PAYMENT_CODES).to match_array(Commerce::LateCaptureRefund::CODES + [
      Commerce::NeverFulfilledClassification::SECOND_CAPTURE_CODE, Commerce::NeverFulfilledClassification::OWNERSHIP_AMBIGUOUS_CODE,
      Commerce::NeverFulfilledClassification::QUARANTINE_CODE
    ])
    expect(FinancialIntegrity::PAYOUT_BLOCKING_CODES).to include(Commerce::BuyerReturnPostings::QUARANTINE_CODE,
      Commerce::NeverFulfilledReconcile::AMBIGUOUS_CODE, Commerce::NeverFulfilledReconcile::RESTATEMENT_CODE,
      Commerce::NeverFulfilledResolution::REOPENED_CODE)
    expect(FinancialIntegrity::PAYOUT_BLOCKING_CODES).not_to include(Commerce::NeverFulfilledResolution::OVERPAID_CODE)
    expect(RepaymentOperation::STATES).to eq(FinancialIntegrity::OPERATION_STATES)
  end

  describe "old workers (7bcd97c2) on a fenced payment" do
    it "rejects every old outbound reservation before any provider call (M-05)" do
      order, payment, _capture, issue = late_capture
      admin = create(:user, :admin)
      attempts = {
        automatic_job: -> { legacy_late_capture.call(payment: payment) },
        admin_refund_buyer: -> { legacy_late_capture.call(payment: payment, requested_by: admin) },
        admin_order_refund: -> {
          legacy_creator.call(order: order, payment: payment, amount_cents: 100, reason: "requested_by_customer",
            requested_by: admin, idempotency_key: "admin-refund:#{order.id}:old", admin_initiated: true)
        },
        fraud_refund: -> {
          legacy_creator.call(order: order, payment: payment, reason: "fraudulent", requested_by: admin,
            idempotency_key: "early-fraud-warning:#{issue.id}")
        }
      }
      attempts.each do |name, attempt|
        expect { isolated { attempt.call } }.to raise_error(ActiveRecord::StatementInvalid, /Repayment fence/), name.to_s
      end
      expect(posts).to be_empty
      expect(Refund.where(payment: payment)).to be_empty
    end

    it "rejects an old reservation's last gate when it was reserved before the fence (M-06)" do
      order, payment, = late_capture
      before_repayment_fence do
        payment.refunds.create!(order: order, provider: "stripe", idempotency_key: "late-capture:payment:#{payment.id}",
          amount_cents: payment.amount_cents, currency: "usd", status: :pending, reason: "late_capture_refund")
        payment.refunds.create!(order: order, provider: "stripe", idempotency_key: "admin-refund:#{order.id}:pre",
          amount_cents: 100, currency: "usd", status: :pending, reason: "requested_by_customer")
      end

      expect { isolated { legacy_late_capture.call(payment: payment) } }.to raise_error(ActiveRecord::StatementInvalid, /cannot be submitted/)
      expect do
        isolated do
          legacy_creator.call(order: order, payment: payment, amount_cents: 100, reason: "requested_by_customer",
            idempotency_key: "admin-refund:#{order.id}:pre", admin_initiated: true)
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /cannot be submitted/)
      expect(posts).to be_empty
      expect(payment.refunds.pluck(:failure_code).uniq).to eq([nil])
    end

    it "lets an old worker's retry of a request already past the gate reuse only that request's key" do
      order, payment, = late_capture
      before_repayment_fence do
        payment.refunds.create!(order: order, provider: "stripe", idempotency_key: "late-capture:payment:#{payment.id}",
          amount_cents: payment.amount_cents, currency: "usd", status: :pending, reason: "late_capture_refund",
          failure_code: "provider_result_unknown", failure_message: "Refund provider response is pending")
      end
      allow(StripeService).to receive(:find_refund).and_return(nil)

      legacy_late_capture.call(payment: payment)

      # No new identity crosses the gate: Stripe's idempotency key makes this
      # the same operation, and the old worker refuses it after 23 hours.
      expect(posts).to eq([[payment.provider_payment_id, payment.amount_cents, "late-capture:payment:#{payment.id}"]])
      expect(payment.refunds.count).to eq(1)
    end

    it "cannot find or co-send a new release's operation, even past its gate (M-08)", repayment_submitter: :active do
      order, payment, capture, = late_capture
      operation = nil
      Order.transaction do
        order.event.organization.lock!("FOR NO KEY UPDATE")
        order.event.lock!
        order.lock!
        refund = Commerce::BuyerRepayment.reserve!(order: order, payment: payment, source: "automatic")
        expect(Commerce::BuyerRepayment.gate!(refund.lock!, replayable: true)).to be(true)
        refund.update!(failure_code: "provider_result_unknown")
        operation = refund.repayment_operation
      end
      expect(operation).to have_attributes(state: "submitting", idempotency_key: "late-capture:payment:#{payment.id}:op:1")

      # The old worker looks for the legacy key, finds nothing, and is refused
      # before any insert (its own balance check here; the fence otherwise).
      expect { isolated { legacy_late_capture.call(payment: payment) } }
        .to raise_error(Legacy7bcd97c2::Commerce::RefundCreator::RefundError, /must be positive/)
      ingest_provider_refund!(payment, 1360, id: "re_cleared_by_new_release")
      expect { isolated { legacy_late_capture.call(payment: payment) } }.to raise_error(StandardError)
      expect(posts).to be_empty
      expect(payment.refunds.where(repayment_operation_id: nil).where.not("idempotency_key LIKE 'provider:%'")).to be_empty
      expect(capture.repayment_operations.count).to eq(1)
    end

    it "never refuses an old worker's inbound provider refund" do
      order, payment, capture = late_capture
      provider = OpenStruct.new(id: "re_old_inbound", status: "succeeded", amount: 500, currency: "usd",
        payment_intent: payment.provider_payment_id, metadata: {})

      refund = legacy_creator.call(order: order, payment: payment, amount_cents: 500, reason: "provider_webhook_reconciliation",
        idempotency_key: "provider:stripe:refund:re_old_inbound", provider_refund: provider)

      expect(refund.reload).to have_attributes(status: "succeeded", provider_refund_id: "re_old_inbound")
      expect(posts).to be_empty
      # The old worker never posts; R1's per-payment repair posts what it recorded.
      expect(ledger(capture).owed_cents).to eq(payment.amount_cents)
      Commerce::BuyerReturnPostings.record_recorded_movements!(capture)
      expect(ledger(capture).owed_cents).to eq(payment.amount_cents - 500)
    end
  end

  describe "provider evidence passes only when positively identified" do
    it "never lets an inbound record without the provider's refund ID through the last gate" do
      order, payment, = late_capture
      inbound = payment.refunds.create!(order: order, provider: "stripe", idempotency_key: "provider:stripe:refund:re_real",
        amount_cents: 100, currency: "usd", status: :pending)

      expect { isolated { inbound.update!(failure_code: "provider_result_unknown") } }
        .to raise_error(ActiveRecord::StatementInvalid, /cannot be submitted/)
      inbound.reload.update!(provider_refund_id: "re_real", failure_code: "provider_result_unknown")
      expect(inbound.reload).to have_attributes(provider_refund_id: "re_real", failure_code: "provider_result_unknown")
    end

    it "leaves unfenced payments and their ordinary refunds alone" do
      order = create(:order, :completed)
      payment = create(:payment, :succeeded, order: order)
      refund = payment.refunds.create!(order: order, provider: "stripe", idempotency_key: "refund:order:plain",
        amount_cents: 100, currency: "usd", status: :pending)
      refund.update!(failure_code: "provider_result_unknown")
      expect(refund.reload.failure_code).to eq("provider_result_unknown")
    end
  end

  describe "repayment operations" do
    def operation!(capture, sequence: 1, **attributes)
      capture.repayment_operations.create!({ payment_id: capture.payment_id, sequence: sequence, amount_cents: 100,
        currency: "usd", idempotency_key: RepaymentOperation.key_for(capture.payment_id, sequence), source: "automatic" }
        .merge(attributes))
    end

    it "numbers operations contiguously with the exact key, one open at a time" do
      _order, payment, capture, = late_capture
      expect { isolated { operation!(capture, sequence: 2) } }.to raise_error(ActiveRecord::StatementInvalid, /contiguously/)
      expect { isolated { operation!(capture, idempotency_key: "late-capture:payment:#{payment.id}") } }
        .to raise_error(ActiveRecord::StatementInvalid, /must use key/)
      expect { isolated { operation!(capture, state: "submitting") } }.to raise_error(ActiveRecord::StatementInvalid)

      first = operation!(capture)
      expect { isolated { operation!(capture, sequence: 2) } }.to raise_error(ActiveRecord::StatementInvalid, /waits until earlier/)
      first.update!(state: "failed_terminal")
      expect(operation!(capture, sequence: 2).idempotency_key).to eq("late-capture:payment:#{payment.id}:op:2")
    end

    it "moves state forward only, counts each send once and keeps identity immutable" do
      order, payment, capture, = late_capture
      operation = operation!(capture)
      refund = payment.refunds.create!(order: order, provider: "stripe", idempotency_key: operation.idempotency_key,
        amount_cents: 100, currency: "usd", status: :pending, repayment_operation: operation)
      operation.update!(refund: refund)

      # The gate's own fence: this refund passes only while its operation is submitting.
      expect { isolated { refund.update!(failure_code: "provider_result_unknown") } }
        .to raise_error(ActiveRecord::StatementInvalid, /only the operation gate/)
      expect { isolated { operation.update!(state: "submitting") } }.to raise_error(ActiveRecord::StatementInvalid, /counted once/)
      operation.update!(state: "submitting", submission_count: 1, last_submitted_at: Time.current)
      refund.update!(failure_code: "provider_result_unknown")
      expect { isolated { connection.execute("UPDATE repayment_operations SET amount_cents = 200 WHERE id = #{operation.id}") } }
        .to raise_error(ActiveRecord::StatementInvalid, /immutable/)
      expect { isolated { operation.update!(state: "reserved") } }.to raise_error(ActiveRecord::StatementInvalid, /cannot move/)
      operation.reload
      expect { isolated { operation.update!(submission_count: 3) } }.to raise_error(ActiveRecord::StatementInvalid, /one at a time/)
      operation.reload.update!(state: "succeeded")
      expect { isolated { operation.update!(state: "unknown") } }.to raise_error(ActiveRecord::StatementInvalid, /final/)
      operation.reload
      expect { isolated { connection.execute("DELETE FROM repayment_operations WHERE id = #{operation.id}") } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect { isolated { refund.update_columns(repayment_operation_id: nil) } }.to raise_error(ActiveRecord::StatementInvalid, /set once/)
      expect { isolated { connection.execute("TRUNCATE repayment_operations CASCADE") } }
        .to raise_error(ActiveRecord::StatementInvalid, /cannot be truncated/)
    end

    it "refuses a refund that does not match its operation exactly" do
      order, payment, capture, = late_capture
      operation = operation!(capture)
      expect do
        isolated do
          payment.refunds.create!(order: order, provider: "stripe", idempotency_key: operation.idempotency_key,
            amount_cents: 101, currency: "usd", status: :pending, repayment_operation: operation)
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /matches its repayment operation/)
    end
  end

  describe "payout fence (P10 strict for every payout writer)" do
    let(:organization) { create(:organization) }
    let(:event) { create(:event, organization: organization, organizer_profile: create(:organizer_profile, organization: organization)) }
    let(:account) { create(:connected_account, organization: organization) }

    def payout_on(target_event, **attributes)
      settlement = create(:settlement, organization: organization, event: target_event)
      create(:payout, organization: organization, event: target_event, settlement: settlement,
        connected_account: account, **attributes)
    end

    it "refuses creation, release and submission on the affected event only, and never for an overpaid alert alone" do
      order, payment, = late_capture
      order.update_columns(event_id: event.id)
      held = payout_on(event, status: :held, held_from_status: "pending")

      expect { isolated { payout_on(event) } }.to raise_error(ActiveRecord::StatementInvalid, /Repayment fence/)
      expect { isolated { held.update_columns(status: Payout.statuses[:pending]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /Repayment fence/)
      expect { isolated { held.update_columns(status: Payout.statuses[:processing]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /Repayment fence/)

      other_event = create(:event, organization: organization, organizer_profile: event.organizer_profile)
      expect { payout_on(other_event) }.not_to raise_error

      ReconciliationException.where(payment: payment).find_each(&:resolve!)
      ReconciliationException.create!(order: order, payment: payment, code: Commerce::NeverFulfilledResolution::OVERPAID_CODE)
      held.update_columns(status: Payout.statuses[:pending])
      expect(held.reload).to be_status_pending
    end
  end
end
