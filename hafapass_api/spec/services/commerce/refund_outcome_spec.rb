# frozen_string_literal: true

require "rails_helper"

RSpec.describe Commerce::RefundOutcome do
  let(:order) { create(:order) }

  it "allows a corrected request when the provider was never invoked" do
    expect(described_class.call(order: order, idempotency_key: "unused")).to eq(reconciliation_required: false, finance_review_required: false)
  end

  it "keeps an uncertain provider request reserved for reconciliation" do
    refund = create(:refund, order: order, status: :pending, idempotency_key: "uncertain")
    expect(described_class.call(order: order, idempotency_key: "uncertain")).to eq(
      reconciliation_required: true, finance_review_required: false, refund_id: refund.id, refund_status: "pending"
    )
  end

  it "does not disclose another order's refund" do
    create(:refund, status: :pending, idempotency_key: "other-order")
    expect(described_class.call(order: order, idempotency_key: "other-order")).to eq(reconciliation_required: false, finance_review_required: false)
  end

  it "reports a known terminal failure without asking the UI to retry an uncertain operation" do
    refund = create(:refund, order: order, status: :failed, idempotency_key: "failed")
    expect(described_class.call(order: order, idempotency_key: "failed")).to include(
      reconciliation_required: false, refund_id: refund.id, refund_status: "failed"
    )
  end

  it "marks a failed refund with a contradictory financial outcome for review and explicitly clears the hold after resolution" do
    refund = create(:refund, order: order, status: :failed, idempotency_key: "failed-with-conflict")
    exception = create(:reconciliation_exception, order: order, code: "refund_terminal_status_conflict")
    expect(described_class.call(order: order, idempotency_key: refund.idempotency_key)).to eq(
      reconciliation_required: true, finance_review_required: true, refund_id: refund.id, refund_status: "failed"
    )

    exception.resolve!

    expect(described_class.call(order: order, idempotency_key: refund.idempotency_key)).to eq(
      reconciliation_required: false, finance_review_required: false, refund_id: refund.id, refund_status: "failed"
    )
  end

  it "includes financial exceptions attached only to an order's payment" do
    payment = create(:payment, order: order)
    create(:reconciliation_exception, order: nil, payment: payment, code: "payment_amount_mismatch")
    expect(described_class.call(order: order, idempotency_key: "unsubmitted")).to eq(
      reconciliation_required: true, finance_review_required: true
    )
  end

  it "ignores unrelated orders and nonfinancial exceptions" do
    create(:reconciliation_exception, code: "refund_terminal_status_conflict")
    create(:reconciliation_exception, order: order, code: "ticket_email_delivery_failure")
    expect(described_class.call(order: order, idempotency_key: "unused")).to eq(
      reconciliation_required: false, finance_review_required: false
    )
  end

  it "identifies simulated captures so a completed test refund is not presented as real money returned" do
    payment = create(:payment, :succeeded, order: order, provider_payload: { "simulated" => true })
    refund = create(:refund, order: order, payment: payment, idempotency_key: "simulated")
    expect(described_class.call(order: order, idempotency_key: refund.idempotency_key)).to include(
      refund_status: "succeeded", refund_simulated: true
    )
  end
end
