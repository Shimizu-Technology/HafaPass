require "rails_helper"

RSpec.describe EventCancellationRefundJob do
  let(:actor) { create(:user, :organizer) }
  let(:profile) { create(:organizer_profile, :verified, user: actor) }
  let(:event) { create(:event, :published, organizer_profile: profile) }

  before { allow(EmailService).to receive(:send_event_change_notifications_async) }

  def paid_order(email:, method: nil, environment: "test")
    order = create(:order, event: event, buyer_email: email, payment_method: method)
    type = create(:ticket_type, event: event)
    create(:order_item, order: order, ticket_type: type, quantity: 2, subtotal_cents: 5000,
      fee_cents: 250, organizer_proceeds_cents: 5000)
    create(:payment, :succeeded, order: order, provider: method == "door_cash" ? "door_cash" : "stripe",
      provider_environment: environment,
      provider_payment_id: method == "door_cash" ? "cash_test_#{order.id}" : "sim_pi_#{order.id}")
    order
  end

  it "refunds the full amount once and blocks settlement while processing" do
    order = paid_order(email: "buyer@example.com")
    preview = EventCancellationRefunds.preview(event)
    expect(preview).to include(count: 1, total_cents: order.total_cents)
    EventLifecycle.call(event: event, action: :cancel, actor: actor, reason: "Storm",
      expected_refund_count: 1, expected_refund_total_cents: order.total_cents)
    run = event.reload.event_cancellation_refund_run
    expect(AuditLog.where(action: "event.cancellation_refunds_started", auditable: event)).to exist
    expect { Settlements::Finalizer.call(event: event, actor: actor) }.to raise_error(/Finish cancellation refunds/)
    described_class.perform_now(run.id)
    expect(order.reload).to be_refunded
    expect(order.refunded_cents).to eq(order.total_cents)
    expect(run.reload).to be_completed
    expect(AuditLog.where(action: "event.cancellation_refunds_completed", auditable: event)).to exist
    described_class.perform_now(run.id)
    expect(order.refunds.count).to eq(1)
  end

  it "keeps cash orders manual and disputed orders skipped" do
    cash = paid_order(email: "cash@example.com", method: "door_cash")
    disputed = paid_order(email: "disputed@example.com")
    Dispute.create!(order: disputed, payment: disputed.payments.first, status: :open,
      provider: "stripe", provider_dispute_id: "dp-cancel-test", amount_cents: 1000,
      currency: "usd", opened_at: Time.current)
    EventLifecycle.call(event: event, action: :cancel, actor: actor, reason: "Storm")
    run = event.reload.event_cancellation_refund_run
    described_class.perform_now(run.id)
    expect(run.items.find_by!(order: cash)).to be_needs_manual
    expect(run.items.find_by!(order: disputed)).to be_skipped
    expect(cash.refunds).to be_empty
    expect(disputed.refunds).to be_empty
  end

  it "does not count a provider-pending refund as completed" do
    order = paid_order(email: "pending@example.com")
    EventLifecycle.call(event: event, action: :cancel, actor: actor, reason: "Storm")
    run = event.reload.event_cancellation_refund_run
    item = run.items.find_by!(order: order)
    create(:refund, order: order, payment: order.payments.first, amount_cents: item.amount_cents,
      status: :pending, succeeded_at: nil, idempotency_key: item.refund_key, provider_refund_id: "re_still_pending")

    described_class.perform_now(run.id)

    expect(item.reload).to be_pending
    expect(run.reload).to be_needs_attention
    expect { Settlements::Finalizer.call(event: event, actor: actor) }.to raise_error(/Finish cancellation refunds/)
  end

  it "records partial failure, resumes with a new key after a definite rejection, and retains payment environment" do
    first = paid_order(email: "first@example.com")
    second = paid_order(email: "second@example.com", environment: "live")
    EventLifecycle.call(event: event, action: :cancel, actor: actor, reason: "Storm")
    run = event.reload.event_cancellation_refund_run
    allow(StripeService).to receive(:refund_payment) do |payment_id, amount_cents:, payment:, **|
      expect(payment.provider_environment).to eq(payment_id == "sim_pi_#{second.id}" ? "live" : "test")
      raise StripeService::PaymentError, "Synthetic rejection" if payment_id == "sim_pi_#{first.id}"

      OpenStruct.new(id: "re_#{payment.id}", status: "succeeded", amount: amount_cents, currency: "usd")
    end
    described_class.perform_now(run.id)
    expect(run.items.find_by!(order: first)).to be_failed
    expect(run.items.find_by!(order: second)).to be_refunded
    expect(run.reload).to be_needs_attention
    expect { PayoutCreator.call(settlement: create(:settlement, event: event, organization: event.organization),
      actor: actor, idempotency_key: "blocked-cancelled-payout") }.to raise_error(/Finish cancellation refunds/)

    failed_item = run.items.find_by!(order: first)
    failed_item.update!(status: :pending, retry_generation: 1, last_error: nil)
    allow(StripeService).to receive(:refund_payment).and_return(
      OpenStruct.new(id: "re_retried", status: "succeeded", amount: first.total_cents, currency: "usd"))
    described_class.perform_now(run.id)
    expect(run.reload).to be_completed
    expect(first.reload).to be_refunded
    expect(first.refunds.pluck(:idempotency_key)).to contain_exactly(
      "event-cancellation/#{event.id}/#{first.id}/0", "event-cancellation/#{event.id}/#{first.id}/1")
  end
end
