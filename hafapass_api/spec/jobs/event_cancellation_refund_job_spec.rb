require "rails_helper"

RSpec.describe EventCancellationRefundJob do
  it "limits concurrent executions by refund run" do
    expect(described_class.concurrency_limit).to eq(1)
    expect(described_class.new(42).concurrency_key).to eq("EventCancellationRefundJob/42")
  end

  let(:actor) { create(:user, :organizer) }
  let(:profile) { create(:organizer_profile, :verified, user: actor) }
  let(:event) { create(:event, :published, organizer_profile: profile) }

  before { allow(EmailService).to receive(:send_event_change_notifications_async) }

  def paid_order(email:, method: nil, environment: "live", amount_cents: 5250)
    order = create(:order, event: event, buyer_email: email, payment_method: method,
      subtotal_cents: amount_cents - 250, total_cents: amount_cents)
    type = create(:ticket_type, event: event)
    create(:order_item, order: order, ticket_type: type, quantity: 2,
      unit_price_cents: (amount_cents - 250) / 2, subtotal_cents: amount_cents - 250,
      fee_cents: 250, organizer_proceeds_cents: amount_cents - 250)
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

  it "keeps the succeeded refund amount when provider confirmation resumes the job" do
    order = paid_order(email: "confirmed@example.com", amount_cents: 9650)
    EventLifecycle.call(event: event, action: :cancel, actor: actor, reason: "Storm")
    run = event.reload.event_cancellation_refund_run
    item = run.items.find_by!(order: order)
    refund = create(:refund, order: order, payment: order.payments.first, amount_cents: 9650,
      status: :pending, succeeded_at: nil, idempotency_key: item.refund_key,
      provider_refund_id: "re_confirmed_#{order.id}")

    described_class.perform_now(run.id)
    expect(item.reload).to be_waiting_on_pending_refund
    expect { refund.update!(status: :succeeded, succeeded_at: Time.current) }
      .to have_enqueued_job(described_class).with(run.id)
    described_class.perform_now(run.id)

    expect(item.reload).to be_refunded
    expect(item.amount_cents).to eq(9650)
    expect(run.reload.summary).to include(total_cents: 9650,
      items: [hash_including(status: "refunded", amount_cents: 9650)])
    expect(AuditLog.where(action: "event.cancellation_refund_amount_changed", auditable: event)).not_to exist
  end

  it "distinguishes an unpaid order from an already refunded order" do
    unpaid = create(:order, event: event, total_cents: 0, subtotal_cents: 0, service_fee_cents: 0)
    paid = paid_order(email: "already-refunded@example.com")
    create(:refund, order: paid, payment: paid.payments.first, amount_cents: paid.total_cents)

    EventLifecycle.call(event: event, action: :cancel, actor: actor, reason: "Storm")
    run = event.reload.event_cancellation_refund_run

    expect(run.items.find_by!(order: unpaid)).to have_attributes(status: "skipped", last_error: "No payment to refund")
    expect(run.items.find_by!(order: paid)).to have_attributes(status: "skipped", last_error: "Order already fully refunded")
  end

  it "refunds the full live capture despite a test refund on the same order" do
    allow(Rails.env).to receive(:production?).and_return(true)
    order = paid_order(email: "mixed@example.com")
    live_payment = order.payments.first
    live_payment.update_columns(provider_payment_id: "pi_live_mixed_#{order.id}")
    test_payment = create(:payment, :succeeded, order: order, amount_cents: 2000,
      provider_environment: "test")
    create(:refund, order: order, payment: test_payment, amount_cents: 500)
    EventLifecycle.call(event: event, action: :cancel, actor: actor, reason: "Storm")
    run = event.reload.event_cancellation_refund_run
    allow(StripeService).to receive(:refund_payment).and_return(
      OpenStruct.new(id: "re_live_mixed", status: "succeeded", amount: 5250, currency: "usd"))

    described_class.perform_now(run.id)
    first_item = run.items.find_by!(order: order)
    expect([first_item.status, first_item.last_error]).to eq(["refunded", nil])
    described_class.perform_now(run.id)

    item = run.items.find_by!(order: order)
    expect([item.status, item.last_error]).to eq(["refunded", nil])
    expect(order.refunds.where(payment: live_payment).succeeded.sum(:amount_cents)).to eq(5250)
    expect(run.reload).to be_completed
    expect(OrderPresenter.call(order.reload)[:cancellation_refund][:amount_cents]).to eq(5250)
    expect(StripeService).to have_received(:refund_payment).once
  end

  [:pending_refund, :dispute].each do |obstacle|
    it "ignores a test-only #{obstacle} when refunding a live capture" do
      allow(Rails.env).to receive(:production?).and_return(true)
      order = paid_order(email: "test-#{obstacle}@example.com")
      order.payments.first.update_columns(provider_payment_id: "pi_live_#{obstacle}_#{order.id}")
      test_payment = create(:payment, :succeeded, order: order, amount_cents: 2000,
        provider_environment: "test")
      if obstacle == :pending_refund
        create(:refund, order: order, payment: test_payment, amount_cents: 500,
          status: :pending, succeeded_at: nil)
      else
        Dispute.create!(order: order, payment: test_payment, status: :open,
          provider: "stripe", provider_dispute_id: "dp_test_#{order.id}", amount_cents: 500,
          currency: "usd", opened_at: Time.current)
      end
      EventLifecycle.call(event: event, action: :cancel, actor: actor, reason: "Storm")
      run = event.reload.event_cancellation_refund_run
      expect(run.items.find_by!(order: order)).to be_pending
      allow(StripeService).to receive(:refund_payment).and_return(
        OpenStruct.new(id: "re_live_#{obstacle}", status: "succeeded", amount: 5250, currency: "usd"))

      described_class.perform_now(run.id)

      expect(run.items.find_by!(order: order)).to be_refunded
      expect(order.refunds.where(payment: order.payments.first).succeeded.sum(:amount_cents)).to eq(5250)
    end
  end

  it "marks a deterministic balance rejection for attention without re-enqueuing" do
    order = paid_order(email: "changed-balance@example.com")
    EventLifecycle.call(event: event, action: :cancel, actor: actor, reason: "Storm")
    run = event.reload.event_cancellation_refund_run
    allow(Commerce::RefundCreator).to receive(:call).and_raise(
      Commerce::RefundCreator::RefundError, "Refund amount exceeds refundable balance")

    expect { described_class.perform_now(run.id) }.not_to have_enqueued_job(described_class)

    item = run.items.find_by!(order: order)
    expect(item).to be_failed
    expect(item.last_error).to include("finance review")
    expect(run.reload).to be_needs_attention
  end

  it "keeps cash orders manual and disputed orders unresolved" do
    cash = paid_order(email: "cash@example.com", method: "door_cash")
    disputed = paid_order(email: "disputed@example.com")
    Dispute.create!(order: disputed, payment: disputed.payments.first, status: :open,
      provider: "stripe", provider_dispute_id: "dp-cancel-test", amount_cents: 1000,
      currency: "usd", opened_at: Time.current)
    EventLifecycle.call(event: event, action: :cancel, actor: actor, reason: "Storm")
    run = event.reload.event_cancellation_refund_run
    described_class.perform_now(run.id)
    expect(run.items.find_by!(order: cash)).to be_needs_manual
    expect(run.items.find_by!(order: disputed)).to be_waiting_on_dispute
    expect(run.reload).to be_needs_attention
    expect(cash.refunds).to be_empty
    expect(disputed.refunds).to be_empty
  end

  it "waits for an individual refund, then refunds its balance when it fails" do
    order = paid_order(email: "individual@example.com")
    individual = create(:refund, order: order, payment: order.payments.first, amount_cents: order.total_cents,
      status: :pending, succeeded_at: nil, provider_refund_id: "re_individual_pending")
    EventLifecycle.call(event: event, action: :cancel, actor: actor, reason: "Storm")
    run = event.reload.event_cancellation_refund_run
    item = run.items.find_by!(order: order)
    described_class.perform_now(run.id)
    expect(item.reload).to be_waiting_on_pending_refund
    expect(run.reload).not_to be_completed
    expect { PayoutCreator.call(settlement: create(:settlement, event: event, organization: event.organization),
      actor: actor, idempotency_key: "blocked-pending-individual") }.to raise_error(/Finish cancellation refunds/)

    individual.update!(status: :failed, failed_at: Time.current, failure_message: "Card closed")
    allow(StripeService).to receive(:refund_payment).and_return(
      OpenStruct.new(id: "re_bulk_after_failure", status: "succeeded", amount: order.total_cents, currency: "usd"))
    described_class.perform_now(run.id)
    expect(item.reload).to be_refunded
    expect(run.reload).to be_completed
    expect(order.reload.refunded_cents).to eq(order.total_cents)
  end

  it "refunds a won dispute but resolves a lost dispute as a chargeback" do
    won_order = paid_order(email: "won@example.com")
    lost_order = paid_order(email: "lost@example.com")
    disputes = [won_order, lost_order].each_with_index.map do |order, index|
      Dispute.create!(order: order, payment: order.payments.first, status: :open,
        provider: "stripe", provider_dispute_id: "dp-cancel-#{index}", amount_cents: order.total_cents,
        currency: "usd", opened_at: Time.current)
    end
    EventLifecycle.call(event: event, action: :cancel, actor: actor, reason: "Storm")
    run = event.reload.event_cancellation_refund_run
    described_class.perform_now(run.id)
    expect(run.reload).not_to be_completed
    expect { PayoutCreator.call(settlement: create(:settlement, event: event, organization: event.organization),
      actor: actor, idempotency_key: "blocked-open-dispute") }.to raise_error(/Finish cancellation refunds/)
    expect { disputes.first.update!(status: :won, closed_at: Time.current) }
      .to have_enqueued_job(described_class).with(run.id)
    expect { disputes.last.update!(status: :lost, closed_at: Time.current) }
      .to have_enqueued_job(described_class).with(run.id)
    allow(StripeService).to receive(:refund_payment).and_return(
      OpenStruct.new(id: "re_won_dispute", status: "succeeded", amount: won_order.total_cents, currency: "usd"))
    described_class.perform_now(run.id)
    expect(run.items.find_by!(order: won_order)).to be_refunded
    lost_item = run.items.find_by!(order: lost_order)
    expect(lost_item).to be_skipped
    expect(lost_item.last_error).to include("chargeback")
    expect(lost_order.refunds).to be_empty
    expect(run.reload).to be_completed
  end

  it "refunds only the remainder after a partial lost dispute" do
    order = paid_order(email: "partial-loss@example.com")
    Dispute.create!(order: order, payment: order.payments.first, status: :lost,
      provider: "stripe", provider_dispute_id: "dp-partial-loss", amount_cents: 1000,
      currency: "usd", opened_at: 1.day.ago, closed_at: Time.current)
    EventLifecycle.call(event: event, action: :cancel, actor: actor, reason: "Storm")
    run = event.reload.event_cancellation_refund_run
    item = run.items.find_by!(order: order)
    expect(item.amount_cents).to eq(4250)
    expect(item).to be_pending
    expect(EventCancellationRefunds.unresolved?(event)).to be(true)
    allow(StripeService).to receive(:refund_payment).and_return(
      OpenStruct.new(id: "re_partial_loss", status: "succeeded", amount: 4250, currency: "usd"))

    described_class.perform_now(run.id)

    expect(item.reload).to be_refunded
    expect(order.refunds.succeeded.sum(:amount_cents)).to eq(4250)
    expect(run.reload).to be_completed
    expect(EventCancellationRefunds.unresolved?(event)).to be(false)
  end

  it "recalculates the remaining balance after another partial refund" do
    order = paid_order(email: "partial@example.com")
    EventLifecycle.call(event: event, action: :cancel, actor: actor, reason: "Storm")
    run = event.reload.event_cancellation_refund_run
    create(:refund, order: order, payment: order.payments.first, amount_cents: 1000)
    allow(StripeService).to receive(:refund_payment).and_return(
      OpenStruct.new(id: "re_remaining", status: "succeeded", amount: order.total_cents - 1000, currency: "usd"))
    described_class.perform_now(run.id)
    item = run.items.find_by!(order: order)
    expect(item.amount_cents).to eq(order.total_cents - 1000)
    expect(order.refunds.find_by(idempotency_key: item.refund_key).amount_cents).to eq(order.total_cents - 1000)
    expect(AuditLog.where(action: "event.cancellation_refund_amount_changed", auditable: event)).to exist
  end

  it "uses a new key for a succeeded partial cancellation refund and never refunds the balance twice" do
    order = paid_order(email: "reconciled@example.com")
    EventLifecycle.call(event: event, action: :cancel, actor: actor, reason: "Storm")
    run = event.reload.event_cancellation_refund_run
    item = run.items.find_by!(order: order)
    create(:refund, order: order, payment: order.payments.first, amount_cents: 1000,
      idempotency_key: item.refund_key)
    item.update!(status: :waiting_on_pending_refund)
    allow(StripeService).to receive(:refund_payment).and_return(
      OpenStruct.new(id: "re_reconciled_remainder", status: "succeeded",
        amount: order.total_cents - 1000, currency: "usd"))

    described_class.perform_now(run.id)
    described_class.perform_now(run.id)

    expect(item.reload).to be_refunded
    expect(item.retry_generation).to eq(1)
    expect(order.refunds.count).to eq(2)
    expect(order.refunds.succeeded.sum(:amount_cents)).to eq(order.total_cents)
    expect(StripeService).to have_received(:refund_payment).once
  end

  it "does not count a provider-pending refund as completed" do
    order = paid_order(email: "pending@example.com")
    EventLifecycle.call(event: event, action: :cancel, actor: actor, reason: "Storm")
    run = event.reload.event_cancellation_refund_run
    item = run.items.find_by!(order: order)
    create(:refund, order: order, payment: order.payments.first, amount_cents: item.amount_cents,
      status: :pending, succeeded_at: nil, idempotency_key: item.refund_key, provider_refund_id: "re_still_pending")

    described_class.perform_now(run.id)

    expect(item.reload).to be_waiting_on_pending_refund
    expect(run.reload).to be_needs_attention
    expect { Settlements::Finalizer.call(event: event, actor: actor) }.to raise_error(/Finish cancellation refunds/)
  end

  it "records partial failure, resumes with a new key after a definite rejection, and retains payment environment" do
    first = paid_order(email: "first@example.com", environment: "test")
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
    expect(EventCancellationRefunds.unresolved?(event)).to be(false)

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
