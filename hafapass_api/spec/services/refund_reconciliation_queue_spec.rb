require "rails_helper"

RSpec.describe RefundReconciliationQueue do
  let(:organization) { create(:organization) }
  let(:profile) { create(:organizer_profile, organization: organization) }
  let(:event) { create(:event, :published, organization: organization, organizer_profile: profile) }

  def paid_order(event:, method: nil, environment: "live")
    order = create(:order, event: event, **(method ? { payment_method: method } : {}))
    provider = method == "door_cash" ? "door_cash" : "stripe"
    create(:payment, :succeeded, order: order, provider: provider, provider_environment: environment)
    order
  end

  def pending_refund(order, status: :pending, created_at: 2.hours.ago, amount_cents: 1000)
    create(:refund, order: order, payment: order.payments.first, status: status,
      amount_cents: amount_cents, succeeded_at: nil, failed_at: status == :failed ? created_at : nil, created_at: created_at)
  end

  it "combines unresolved Stripe, cancellation, buyer request, and dispute obligations with buyer context" do
    pending_order = paid_order(event: event)
    pending = pending_refund(pending_order)
    manual_order = paid_order(event: event, method: "door_cash")
    run = event.create_event_cancellation_refund_run!(started_by: create(:user, :admin))
    manual = run.items.create!(order: manual_order, status: :needs_manual, amount_cents: 5250)
    request_order = paid_order(event: event)
    change = event.event_changes.create!(change_type: "rescheduled", occurred_at: 4.days.ago)
    request = change.event_change_responses.create!(order: request_order, decision: "refund_requested",
      responded_at: 4.days.ago)
    disputed_order = paid_order(event: event)
    dispute = Dispute.create!(order: disputed_order, payment: disputed_order.payments.first,
      provider: "stripe", provider_dispute_id: "dp_reconciliation_spec", status: :open,
      amount_cents: 5250, currency: "usd", opened_at: 1.day.ago)

    items = described_class.call.fetch(:items)

    expect(items.map { |item| [item[:type], item[:id]] }).to include(
      ["refund", pending.id], ["cancellation", manual.id], ["request", request.id], ["dispute", dispute.id])
    items.each do |item|
      expect(item).to include(:order_id, :order_reference, :buyer_name, :buyer_email,
        :event_id, :event_title, :organization_id, :organization_name, :amount_cents,
        :reason, :status, :age_seconds, :next_action, :overdue)
    end
    expect(items.find { |item| item[:id] == request.id && item[:type] == "request" }[:overdue]).to be(true)
  end

  it "excludes resolved refunds and resolved cancellation items" do
    order = paid_order(event: event)
    create(:refund, order: order, payment: order.payments.first, status: :succeeded)
    run = event.create_event_cancellation_refund_run!(started_by: create(:user, :admin))
    run.items.create!(order: order, status: :refunded, amount_cents: 5250)

    expect(described_class.call.fetch(:items)).to be_empty
  end

  it "keeps a cancelled provider refund visible until a replacement succeeds" do
    order = paid_order(event: event)
    cancelled = pending_refund(order, status: :cancelled)

    expect(described_class.call.fetch(:items)).to include(include(type: "refund", id: cancelled.id, status: "cancelled"))
  end

  it "removes an old failed partial refund after its replacement succeeds" do
    order = paid_order(event: event)
    failed = pending_refund(order, status: :failed, amount_cents: 1200)
    create(:refund, order: order, payment: order.payments.first, amount_cents: 1200,
      status: :succeeded, idempotency_key: "refund-reconciliation/#{failed.id}")

    expect(described_class.call.fetch(:items)).not_to include(include(type: "refund", id: failed.id))
  end

  it "does not count two failed attempts as twice the buyer balance" do
    order = paid_order(event: event)
    pending_refund(order, status: :failed, amount_cents: order.total_cents)
    pending_refund(order, status: :failed, amount_cents: order.total_cents)

    rows = described_class.call.fetch(:items).select { |item| item[:order_id] == order.id }
    expect(rows.sum { |item| item[:amount_cents] }).to eq(order.refundable_cents)
  end

  it "excludes nonlive production payments from liabilities and payout holds" do
    test_order = paid_order(event: event, environment: "test")
    pending_refund(test_order, status: :failed)
    live_order = paid_order(event: event)
    live_refund = pending_refund(live_order, status: :failed)
    allow(Rails.env).to receive(:production?).and_return(true)

    expect(described_class.call.fetch(:items)).to contain_exactly(include(type: "refund", id: live_refund.id))
  end

  it "scopes organizer data and filters status, age, and event" do
    old = pending_refund(paid_order(event: event), status: :failed, created_at: 5.days.ago)
    pending_refund(paid_order(event: event), created_at: 1.hour.ago)
    other_event = create(:event, :published)
    pending_refund(paid_order(event: other_event), status: :failed, created_at: 5.days.ago)

    result = described_class.call(organization_id: organization.id, event_id: event.id,
      status: "failed", age_days: 3)

    expect(result.fetch(:items).map { |item| item[:id] }).to eq([old.id])
    expect(result.fetch(:meta)).to include(total: 1)
  end

  it "keeps SELECT count bounded for a page containing 200 refund obligations" do
    200.times do |index|
      order = paid_order(event: event)
      order.update!(buyer_email: "buyer#{index}@example.com")
      create(:refund, order: order, payment: order.payments.first, status: :failed, succeeded_at: nil,
        failed_at: 4.days.ago)
    end

    selects = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      selects << payload[:sql] if payload[:sql]&.match?(/\ASELECT\b/i) && !payload[:cached] && payload[:name] != "SCHEMA"
    end
    result = described_class.call(organization_id: organization.id, page: 1, per_page: 100)
    expect(result.fetch(:items).length).to eq(100)
    expect(result.fetch(:meta).fetch(:total)).to eq(200)
    expect(selects.length).to be <= 20
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
