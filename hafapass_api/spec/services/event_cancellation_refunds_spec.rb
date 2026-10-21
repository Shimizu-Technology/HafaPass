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

  it "counts only live captures and their refunds in a mixed live and test order" do
    test_capture = create(:payment, :succeeded, order: order, amount_cents: 2000,
      provider_environment: "test")
    create(:refund, order: order, payment: test_capture, amount_cents: 500)

    expect(described_class.balances(event, exclude_nonlive: true).first[:amount_cents]).to eq(5250)
    expect(described_class.outstanding_balance_cents(event)).to eq(5250)
    expect(described_class.preview(event)[:total_cents]).to eq(6750) unless Rails.env.production?
  end

  it "computes a fifty-order preview with a bounded number of grouped queries" do
    49.times do
      paid_order = create(:order, event: event)
      create(:payment, :succeeded, order: paid_order, provider_environment: "live")
    end
    selects = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      selects << payload[:sql] if payload[:sql]&.match?(/\ASELECT/i) && payload[:name] != "SCHEMA"
    end
    preview = described_class.preview(event)
    expect(preview).to include(count: 50, total_cents: 50 * 5250)
    expect(selects.length).to be <= 5
    %w[payments refunds disputes].each do |table|
      expect(selects).to include(a_string_matching(/GROUP BY \"#{table}\"\.\"order_id\"/))
    end
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
