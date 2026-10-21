require "rails_helper"

RSpec.describe EventCancellationRefunds do
  let(:event) { create(:event, :cancelled) }
  let(:order) { create(:order, event: event) }
  let!(:payment) { create(:payment, :succeeded, order: order, provider_environment: "live") }

  def dispute(status, amount_cents)
    Dispute.create!(order: order, payment: payment, provider: "stripe",
      provider_dispute_id: "dp_#{SecureRandom.hex(8)}", status: status,
      amount_cents: amount_cents, currency: "usd", opened_at: 1.day.ago,
      closed_at: status == :open ? nil : Time.current)
  end

  it "counts a full lost dispute as a complete buyer return" do
    dispute(:lost, 5250)
    expect(described_class.balance_cents(order)).to eq(0)
    expect(described_class.unresolved?(event)).to be(false)
  end

  it "counts only the amount actually lost in a partial dispute" do
    dispute(:lost, 1000)
    expect(described_class.balance_cents(order)).to eq(4250)
    expect(described_class.outstanding_balance_cents(event)).to eq(4250)
    expect(described_class.unresolved?(event)).to be(true)
  end

  it "does not count a won dispute as money returned" do
    dispute(:won, 1000)
    expect(described_class.balance_cents(order)).to eq(5250)
    expect(described_class.unresolved?(event)).to be(true)
  end

  it "holds an open dispute even when a refund reserves the full balance" do
    dispute(:open, 1000)
    create(:refund, order: order, payment: payment, amount_cents: 5250, status: :pending, succeeded_at: nil)
    expect(described_class.balance_cents(order)).to eq(0)
    expect(described_class.unresolved?(event)).to be(true)
  end

  it "counts succeeded and pending refunds once and excludes test captures" do
    create(:refund, order: order, payment: payment, amount_cents: 1000)
    create(:refund, order: order, payment: payment, amount_cents: 500, status: :pending, succeeded_at: nil)
    expect(described_class.balance_cents(order)).to eq(3750)
    test_event = create(:event, :cancelled)
    test_order = create(:order, event: test_event)
    create(:payment, :succeeded, order: test_order, provider_environment: "test")
    run = test_event.create_event_cancellation_refund_run!(started_by: create(:user))
    expect(run).to be_processing
    expect(described_class.outstanding_balance_cents(test_event)).to eq(0)
    expect(described_class.unresolved?(test_event)).to be(false)
    simulated_event = create(:event, :cancelled)
    simulated_order = create(:order, event: simulated_event)
    create(:payment, :succeeded, order: simulated_order, provider_environment: "simulate")
    expect(described_class.outstanding_balance_cents(simulated_event)).to eq(0)
    expect(described_class.unresolved?(simulated_event)).to be(false)
  end
end
