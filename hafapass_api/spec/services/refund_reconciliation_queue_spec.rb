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

  describe "provider verification amounts" do
    def issue_for(order, code: "refund_aggregate_requires_reconciliation", actual: nil, details: {})
      create(:reconciliation_exception, order: order, payment: order.payments.first,
        code: code, actual_amount_cents: actual, details: details)
    end

    def exception_row(issue)
      described_class.new(event_id: event.id).entries.find { |entry| entry[:type] == "exception" && entry[:id] == issue.id }
    end

    def mark_organizer_paid
      event.update!(status: :cancelled)
      create(:payout, event: event, organization: organization, status: :paid, with_tax_snapshot: false)
    end

    it "distinguishes the unbooked aggregate from money owed without booking or reserving it" do
      order = paid_order(event: event)
      pending_refund(order, status: :succeeded, amount_cents: 1000)
      pending_refund(order, amount_cents: 500)
      issue = issue_for(order, actual: 3000)
      before = [order.refunds.count, order.refundable_cents, order.refund_amount_cents]

      expect(exception_row(issue)).to include(amount_cents: 0, buyer_amount_cents: nil, provider_amount_kind: "aggregate",
        provider_reported_amount_cents: 3000, provider_verification_amount_cents: 2000,
        buyer_amount_unverified: true)
      expect([order.refunds.count, order.refundable_cents, order.reload.refund_amount_cents]).to eq(before)
    end

    [nil, {}, { amount_cents: "1200" }, { amount_cents: -1 }].each do |details|
      it "keeps an unknown operation amount unknown for #{details.inspect}" do
        order = paid_order(event: event)
        issue = issue_for(order, code: "refund_operation_not_found", details: details || {})
        expect(exception_row(issue)).to include(amount_cents: 0, buyer_amount_cents: nil, provider_amount_kind: "operation",
          provider_reported_amount_cents: nil, provider_verification_amount_cents: nil)
      end
    end

    it "reports a failed operation's observed amount without making it a buyer debt" do
      mark_organizer_paid
      order = paid_order(event: event)
      issue = issue_for(order, code: "refund_operation_not_found", details: { amount_cents: 1200, status: "failed" })
      expect(exception_row(issue)).to include(amount_cents: 0, buyer_amount_cents: nil, provider_amount_kind: "operation",
        provider_reported_amount_cents: 1200, provider_verification_amount_cents: 1200)
      expect(described_class.recovery_amount_for_event(event)).to eq(0)
      expect(described_class.outstanding_for_event?(event)).to be(true)
      expect(OrganizationPayoutBalance.available_cents(organization)).to eq(0)
    end

    it "counts cancellation recovery once despite several aggregate and operation exceptions" do
      mark_organizer_paid
      order = paid_order(event: event)
      pending_refund(order, status: :succeeded, amount_cents: 1000)
      run = event.create_event_cancellation_refund_run!(started_by: create(:user, :admin))
      item = run.items.create!(order: order, status: :failed, amount_cents: 5250)
      issues = [issue_for(order, actual: 3000), issue_for(order, actual: 4000),
        issue_for(order, code: "refund_operation_not_found", details: { amount_cents: 2000 })]

      rows = described_class.new(event_id: event.id).entries
      expect(rows.count { |entry| entry[:type] == "exception" }).to eq(3)
      expect(rows.find { |entry| entry[:type] == "cancellation" && entry[:id] == item.id })
        .to include(amount_cents: 4250, buyer_amount_unverified: true)
      expect(described_class.recovery_amount_for_event(event)).to eq(4250)
      expect(issues.map(&:reload)).to all(be_open)
    end

    [0, 5250].each do |reported|
      it "keeps zero/full booked aggregate #{reported} visible and holds payout with no extra recovery" do
        mark_organizer_paid
        order = paid_order(event: event)
        pending_refund(order, status: :succeeded, amount_cents: 5250)
        issue = issue_for(order, actual: reported)
        expect(exception_row(issue)).to include(amount_cents: 0, buyer_amount_cents: nil, provider_verification_amount_cents: 0)
        expect(described_class.recovery_amount_for_event(event)).to eq(0)
        expect(described_class.outstanding_for_event?(event)).to be(true)
        held = create(:payout, event: event, organization: organization, status: :held,
          held_from_status: "pending", connected_account: organization.connected_accounts.first, with_tax_snapshot: false)
        admin = create(:user, :admin)
        expect { PayoutHoldRelease.call(payout: held, actor: admin) }
          .to raise_error(PayoutHoldRelease::ReleaseError, /outstanding buyer refund/)
        expect(PayoutHoldRelease.call(payout: held, actor: admin, automatic: true)).to be(false)
        expect(held.reload).to be_status_held
      end
    end

    it "scopes booked aggregate money to its payment rather than another payment on the order" do
      order = paid_order(event: event)
      other = create(:payment, :succeeded, order: order)
      create(:refund, order: order, payment: other, status: :succeeded, amount_cents: 1000)
      issue = issue_for(order, actual: 3000)
      expect(exception_row(issue)).to include(provider_verification_amount_cents: 3000)
    end

    it "keeps the non-live production exception and its uncertainty out of the live queue" do
      order = paid_order(event: event)
      failed = pending_refund(order, status: :failed)
      test_payment = create(:payment, :succeeded, order: order, provider_environment: "test")
      create(:reconciliation_exception, order: order, payment: test_payment,
        code: "refund_aggregate_requires_reconciliation", actual_amount_cents: 3000)
      allow(Rails.env).to receive(:production?).and_return(true)
      expect(described_class.new(event_id: event.id).entries).to contain_exactly(
        include(type: "refund", id: failed.id, buyer_amount_unverified: false))
    end
  end
end
