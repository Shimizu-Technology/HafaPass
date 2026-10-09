# frozen_string_literal: true

require "rails_helper"

RSpec.describe Commerce::RefundOutcome do
  let(:order) { create(:order) }

  it "allows a corrected request when the provider was never invoked" do
    expect(described_class.call(order: order, idempotency_key: "unused")).to eq(reconciliation_required: false)
  end

  it "keeps an uncertain provider request reserved for reconciliation" do
    refund = create(:refund, order: order, status: :pending, idempotency_key: "uncertain")
    expect(described_class.call(order: order, idempotency_key: "uncertain")).to eq(
      reconciliation_required: true, refund_id: refund.id, refund_status: "pending"
    )
  end

  it "does not disclose another order's refund" do
    create(:refund, status: :pending, idempotency_key: "other-order")
    expect(described_class.call(order: order, idempotency_key: "other-order")).to eq(reconciliation_required: false)
  end

  it "reports a known terminal failure without asking the UI to retry an uncertain operation" do
    refund = create(:refund, order: order, status: :failed, idempotency_key: "failed")
    expect(described_class.call(order: order, idempotency_key: "failed")).to include(
      reconciliation_required: false, refund_id: refund.id, refund_status: "failed"
    )
  end
end
