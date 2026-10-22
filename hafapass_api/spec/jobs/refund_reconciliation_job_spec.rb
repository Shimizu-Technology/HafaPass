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

  it "processes oldest refunds first and respects the refund and Stripe-call budgets" do
    oldest = unsettled_refund(status: :pending, created_at: 4.hours.ago)
    second = unsettled_refund(status: :pending, created_at: 3.hours.ago)
    unsettled_refund(status: :pending, created_at: 2.hours.ago)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REFUND_RECONCILIATION_MAX_REFUNDS", 200).and_return("2")
    allow(ENV).to receive(:fetch).with("REFUND_RECONCILIATION_MAX_STRIPE_CALLS", 500).and_return("2")
    processed = []
    allow(RefundReconciliationActions).to receive(:call) do |**options|
      options.fetch(:stripe_call_budget).charge!
      processed << options.fetch(:id)
    end
    allow(EmailService).to receive(:send_refund_reconciliation_digest_async)

    described_class.perform_now

    expect(processed).to eq([oldest.id, second.id])
  end

  it "stops after the Stripe call budget before attempting another provider call" do
    3.times { |index| unsettled_refund(status: :pending, created_at: (index + 2).hours.ago) }
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REFUND_RECONCILIATION_MAX_STRIPE_CALLS", 500).and_return("1")
    allow(RefundReconciliationActions).to receive(:call) do |**options|
      options.fetch(:stripe_call_budget).charge!
    end
    allow(EmailService).to receive(:send_refund_reconciliation_digest_async)

    described_class.perform_now

    expect(RefundReconciliationActions).to have_received(:call).twice
  end

  it "stops cleanly on a Stripe rate limit and logs the run summary" do
    2.times { |index| unsettled_refund(status: :pending, created_at: (index + 2).hours.ago) }
    allow(StripeService).to receive(:retrieve_refund).and_raise(Stripe::RateLimitError.new("Too many requests"))
    allow(EmailService).to receive(:send_refund_reconciliation_digest_async)
    allow(Rails.logger).to receive(:info)

    described_class.perform_now

    expect(StripeService).to have_received(:retrieve_refund).once
    expect(Rails.logger).to have_received(:info).with(/stop=stripe_rate_limit/)
  end

  it "stops after the configured number of consecutive provider errors" do
    3.times { |index| unsettled_refund(status: :pending, created_at: (index + 2).hours.ago) }
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REFUND_RECONCILIATION_MAX_CONSECUTIVE_ERRORS", 5).and_return("2")
    allow(StripeService).to receive(:retrieve_refund).and_raise(Stripe::APIConnectionError.new("Unreachable"))
    allow(EmailService).to receive(:send_refund_reconciliation_digest_async)
    allow(Rails.logger).to receive(:info)

    described_class.perform_now

    expect(StripeService).to have_received(:retrieve_refund).twice
    expect(Rails.logger).to have_received(:info).with(/stop=consecutive_errors/)
  end

  it "marks an ambiguous provider lookup for manual review without resolving the refund" do
    refund = unsettled_refund(status: :pending, created_at: 2.hours.ago)
    refund.update!(provider_refund_id: nil)
    allow(StripeService).to receive(:find_refund).and_raise(StripeService::AmbiguousRefund.new("Multiple matches; manual review"))
    allow(EmailService).to receive(:send_refund_reconciliation_digest_async)

    described_class.perform_now

    expect(refund.reload).to be_pending
    expect(RefundReconciliationQueue.call.fetch(:items)).to include(include(
      id: refund.id, unable_reason: "Multiple matches; manual review"))
  end
end
