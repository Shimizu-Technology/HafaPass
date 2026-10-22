require "rails_helper"

RSpec.describe RefundReconciliationJob, type: :job do
  let(:event) { create(:event, :published) }

  def unsettled_refund(status:, created_at:)
    order = create(:order, event: event)
    type = create(:ticket_type, event: event)
    create(:order_item, order: order, ticket_type: type, quantity: 2,
      subtotal_cents: 5000, fee_cents: 250, organizer_proceeds_cents: 5000)
    payment = create(:payment, :succeeded, order: order, provider_environment: "live")
    create(:refund, order: order, payment: payment, status: status, succeeded_at: nil,
      failed_at: status == :failed ? created_at : nil, created_at: created_at,
      provider_refund_id: status == :pending ? "re_job_#{order.id}" : nil)
  end

  it "re-syncs pending Stripe refunds older than an hour and sends one digest for remaining items" do
    stale = unsettled_refund(status: :pending, created_at: 2.hours.ago)
    recent = unsettled_refund(status: :pending, created_at: 30.minutes.ago)
    overdue = unsettled_refund(status: :failed, created_at: 4.days.ago)
    allow(StripeService).to receive(:retrieve_refund).and_return(OpenStruct.new(
      id: stale.provider_refund_id, status: "succeeded", amount: stale.amount_cents, currency: "usd"))
    allow(EmailService).to receive(:send_refund_reconciliation_digest_async)

    described_class.perform_now

    expect(stale.reload).to be_succeeded
    expect(recent.reload).to be_pending
    expect(StripeService).to have_received(:retrieve_refund).once
    expect(EmailService).to have_received(:send_refund_reconciliation_digest_async).once do |items, date:|
      expect(date).to eq(Date.current)
      expect(items.map { |item| item[:id] }).to include(overdue.id)
      expect(items.find { |item| item[:id] == overdue.id }[:overdue]).to be(true)
    end
    expect(AuditLog.where(action: "refund_reconciliation.overdue", auditable: overdue)).to exist
    expect do
      described_class.perform_now
    end.not_to change { AuditLog.where(action: "refund_reconciliation.overdue", auditable: overdue).count }
  end

  it "does not send a digest when the queue is empty" do
    allow(EmailService).to receive(:send_refund_reconciliation_digest_async)

    described_class.perform_now

    expect(EmailService).not_to have_received(:send_refund_reconciliation_digest_async)
  end

  it "leaves an uncertain provider result pending and visible for an operator" do
    stale = unsettled_refund(status: :pending, created_at: 2.hours.ago)
    allow(StripeService).to receive(:retrieve_refund).and_raise(Stripe::APIConnectionError.new("Unreachable"))
    allow(EmailService).to receive(:send_refund_reconciliation_digest_async)

    described_class.perform_now

    expect(stale.reload).to be_pending
    expect(RefundReconciliationQueue.call.fetch(:items).map { |item| item[:id] }).to include(stale.id)
    expect(EmailService).to have_received(:send_refund_reconciliation_digest_async).once
  end
end
