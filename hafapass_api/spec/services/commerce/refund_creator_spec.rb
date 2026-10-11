require "rails_helper"

RSpec.describe Commerce::RefundCreator do
  let(:event) { create(:event, :published, starts_at: 5.days.from_now) }
  let(:ticket_type) { create(:ticket_type, event: event, quantity_sold: 2) }
  let(:order) do
    create(:order, event: event, total_cents: 5250, subtotal_cents: 5000, service_fee_cents: 250)
  end
  let!(:item) do
    create(
      :order_item,
      order: order,
      ticket_type: ticket_type,
      unit_price_cents: 2500,
      quantity: 2,
      subtotal_cents: 5000,
      fee_cents: 250,
      organizer_proceeds_cents: 5000
    )
  end
  let!(:payment) do
    create(:payment, :succeeded, order: order, amount_cents: 5250, provider_payment_id: "sim_pi_refunds")
  end

  before do
    2.times { create(:ticket, order: order, order_item: item, event: event, ticket_type: ticket_type) }
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(event).to receive(:notify_waitlist_if_available)
  end

  it "records multiple partial refunds as additive item allocations" do
    first = described_class.call(order: order, amount_cents: 1000, reason: "first", idempotency_key: "refund-one")
    second = described_class.call(order: order, amount_cents: 500, reason: "second", idempotency_key: "refund-two")

    expect(first).to be_succeeded
    expect(second).to be_succeeded
    expect(order.reload).to be_partially_refunded
    expect(order.refunded_cents).to eq(1500)
    expect(order.refunds.count).to eq(2)
    expect(order.refunds.joins(:refund_items).sum("refund_items.amount_cents")).to eq(1500)
    expect(payment.reload).to be_partially_refunded
  end

  it "returns the original refund for a repeated idempotency key" do
    first = described_class.call(order: order, amount_cents: 1000, idempotency_key: "same-refund")

    expect do
      second = described_class.call(order: order, amount_cents: 1000, idempotency_key: "same-refund")
      expect(second.id).to eq(first.id)
    end.not_to change(Refund, :count)
  end

  it "finalizes an existing pending refund during provider reconciliation" do
    pending = create(
      :refund,
      order: order,
      payment: payment,
      amount_cents: 1000,
      currency: order.currency,
      status: :pending,
      provider_refund_id: nil,
      idempotency_key: "original-refund"
    )

    expect do
      result = described_class.reconcile_provider_total!(
        order: order,
        payment: payment,
        amount_cents: 1000,
        provider_refund_id: "re_webhook",
        idempotency_key: "webhook-refund"
      )
      expect(result.id).to eq(pending.id)
      expect(result).to be_succeeded
      expect(result.provider_refund_id).to eq("re_webhook")
    end.not_to change(Refund, :count)
  end

  it "preserves an unrelated refund validation failure" do
    allow_any_instance_of(Refund).to receive(:save!).and_raise(
      ActiveRecord::RecordInvalid.new(Refund.new)
    )

    expect do
      described_class.call(order: order, amount_cents: 1000, idempotency_key: "invalid-refund")
    end.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "passes the local refund idempotency key to Stripe" do
    payment.update!(provider_payment_id: "pi_real_refund")
    allow(StripeService).to receive(:refund_payment).and_return(
      OpenStruct.new(id: "re_provider", status: "succeeded")
    )

    described_class.call(order: order, amount_cents: 1000, idempotency_key: "provider-refund-key")

    expect(StripeService).to have_received(:refund_payment).with(
      "pi_real_refund",
      amount_cents: 1000,
      reason: nil,
      idempotency_key: "provider-refund-key",
      payment: payment
    )
  end

  it "prevents committed refunds from exceeding the order under serialized requests" do
    described_class.call(order: order, amount_cents: 5000, idempotency_key: "almost-all")

    expect do
      described_class.call(order: order, amount_cents: 251, idempotency_key: "too-much")
    end.to raise_error(described_class::RefundError, /exceeds refundable balance/)
  end

  it "fully refunds, cancels tickets, and releases sold inventory" do
    refund = described_class.call(order: order, amount_cents: 5250, reason: "cancelled event")

    expect(refund).to be_succeeded
    expect(order.reload).to be_refunded
    expect(order.tickets.reload).to all(be_cancelled)
    expect(ticket_type.reload.quantity_sold).to eq(0)
    expect(payment.reload).to be_refunded
  end

  it "refunds and revokes only the selected unused ticket" do
    selected, remaining = order.tickets.order(:id).to_a
    old_scan = selected.scan_credential

    refund = described_class.call(order: order, tickets: [selected], reason: "buyer choice", idempotency_key: "one-ticket")

    expect(refund).to be_succeeded
    expect(refund.amount_cents).to eq(2625)
    expect(refund.tickets).to contain_exactly(selected)
    expect(selected.reload).to be_cancelled
    expect(remaining.reload).to be_issued
    expect(order.reload).to be_partially_refunded
    expect(ticket_type.reload.quantity_sold).to eq(1)
    expect(TicketCredential.find_scan(old_scan)).to be_nil
  end

  it "rejects a selective refund for a used ticket before contacting the provider" do
    used = order.tickets.first
    used.update!(status: :checked_in, checked_in_at: Time.current)
    allow(StripeService).to receive(:refund_payment)

    expect do
      described_class.call(order: order, tickets: [used], idempotency_key: "used-ticket")
    end.to raise_error(described_class::RefundError, /unused active/)

    expect(StripeService).not_to have_received(:refund_payment)
  end
  it "submits every partial refund against the original captured payment" do
    payment.update!(provider_payment_id: "pi_original")
    allow(StripeService).to receive(:refund_payment) { OpenStruct.new(id: "re_#{SecureRandom.hex(8)}", status: "succeeded") }
    2.times { |i| described_class.call(order: order, amount_cents: 1000, idempotency_key: "partial-#{i}") }
    expect(StripeService).to have_received(:refund_payment).with("pi_original", anything).twice
    expect(order.refunds.pluck(:payment_id)).to eq([payment.id, payment.id])
  end

  %w[pending requires_action failed canceled].each do |provider_status|
    it "does not book #{provider_status} refunds as returned money or revoke tickets" do
      allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_non_success", status: provider_status))
      result = described_class.call(order: order, amount_cents: order.total_cents)
      expected = { "requires_action" => "pending", "canceled" => "cancelled" }.fetch(provider_status, provider_status)
      expect(result.status).to eq(expected)
      expect(order.reload).to be_completed
      expect(order.refunded_cents).to eq(0)
      expect(result.refund_items).to be_empty
      expect(order.tickets.reload).to all(be_issued)
      expect(EmailService).not_to have_received(:send_refund_notification_async)
    end
  end

  %w[door_cash boh_clover].each do |provider|
    it "refuses unsupported #{provider} before reserving a refund" do
      payment.destroy!
      create(:payment, :succeeded, order: order, provider: provider, provider_payment_id: "#{provider}_captured")
      allow(StripeService).to receive(:refund_payment)
      expect { described_class.call(order: order, amount_cents: 1000) }.to raise_error(described_class::RefundError, /not supported/)
      expect(order.refunds).to be_empty
      expect(StripeService).not_to have_received(:refund_payment)
    end
  end

  it "fails explicitly when the captured payment is missing" do
    payment.destroy!
    expect { described_class.call(order: order, amount_cents: 1000) }.to raise_error(described_class::RefundError, /captured payment/)
    expect(order.refunds).to be_empty
  end

  it "keeps selected-ticket entry paused for an unknown refund without releasing inventory" do
    selected = order.tickets.first
    allow(StripeService).to receive(:refund_payment).and_raise(Stripe::APIConnectionError, "synthetic response lost")
    expect { described_class.call(order: order, tickets: [selected], idempotency_key: "selected-unknown-entry") }
      .to raise_error(described_class::RefundError, /unknown/)
    refund = order.refunds.find_by!(idempotency_key: "selected-unknown-entry")
    expect(refund).to have_attributes(status: "pending", failure_code: "provider_result_unknown")
    expect(refund.refund_tickets.active.count).to eq(1)
    expect(selected.reload).to be_issued
    expect(selected).not_to be_admission_allowed
    expect(order.tickets.where.not(id: selected.id).first).to be_admission_allowed
    expect { selected.check_in! }.to raise_error(Ticket::AdmissionError, /selected refund is pending/)
    expect(ticket_type.reload.quantity_sold).to eq(2)
    expect(order.reload.refunded_cents).to eq(0)
    expect(EmailService).not_to have_received(:send_refund_notification_async)
  end

  it "keeps an uncertain submission reserved and retries the same operation identity" do
    allow(StripeService).to receive(:refund_payment).and_raise(Stripe::APIConnectionError, "response lost")
    expect { described_class.call(order: order, amount_cents: 1000, idempotency_key: "uncertain") }.to raise_error(described_class::RefundError, /unknown/)
    pending = order.refunds.find_by!(idempotency_key: "uncertain")
    expect(pending).to be_pending
    expect(order.refundable_cents).to eq(4250)
    allow(StripeService).to receive(:find_refund).and_return(nil)
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_retry", status: "succeeded"))
    expect { described_class.call(order: order, amount_cents: 1000, idempotency_key: "uncertain") }.not_to change(Refund, :count)
    expect(pending.reload).to be_succeeded
    expect(StripeService).to have_received(:find_refund).with(payment.provider_payment_id, idempotency_key: "uncertain", payment: payment)
  end

  it "recovers an old uncertain operation by metadata without creating another provider refund" do
    pending = create(:refund, order: order, payment: payment, amount_cents: 1000, status: :pending,
      provider_refund_id: nil, failure_code: "provider_result_unknown", idempotency_key: "old-uncertain", created_at: 3.days.ago)
    allow(StripeService).to receive(:find_refund).and_return(
      OpenStruct.new(id: "re_found", amount: 1000, currency: "usd", status: "succeeded"))
    allow(StripeService).to receive(:refund_payment)

    result = described_class.call(order: order, amount_cents: 1000, idempotency_key: pending.idempotency_key)

    expect(result).to be_succeeded
    expect(result.provider_refund_id).to eq("re_found")
    expect(order.refunds.count).to eq(1)
    expect(order.reload.refunded_cents).to eq(1000)
    expect(StripeService).not_to have_received(:refund_payment)
  end

  it "retains a missing old operation for finance instead of reusing an expired provider identity" do
    selected = order.tickets.first
    pending = create(:refund, order: order, payment: payment, amount_cents: selected.refundable_cents, status: :pending,
      provider_refund_id: nil, failure_code: "provider_result_unknown", idempotency_key: "expired-uncertain", created_at: 24.hours.ago)
    pending.refund_tickets.create!(ticket: selected, amount_cents: selected.refundable_cents)
    allow(StripeService).to receive(:find_refund).and_return(nil)
    allow(StripeService).to receive(:refund_payment)

    expect { described_class.call(order: order, tickets: [selected], idempotency_key: pending.idempotency_key) }
      .to raise_error(described_class::RefundError, /finance must reconcile/)

    expect(pending.reload).to be_pending
    expect(pending.refund_tickets.active).to exist
    expect(order.reload.refundable_cents).to eq(2625)
    expect(StripeService).not_to have_received(:refund_payment)
  end

  it "keeps uncertainty reserved when the provider lookup fails" do
    pending = create(:refund, order: order, payment: payment, amount_cents: 1000, status: :pending,
      provider_refund_id: nil, failure_code: "provider_result_unknown", idempotency_key: "lookup-outage")
    allow(StripeService).to receive(:find_refund).and_raise(Stripe::APIConnectionError, "lookup unavailable")
    allow(StripeService).to receive(:refund_payment)

    expect { described_class.call(order: order, amount_cents: 1000, idempotency_key: pending.idempotency_key) }
      .to raise_error(described_class::RefundError, /lookup failed/)
    expect(pending.reload).to be_pending
    expect(order.refundable_cents).to eq(4250)
    expect(StripeService).not_to have_received(:refund_payment)
  end

  it "records submission uncertainty before contacting the provider and clears it on acknowledgment" do
    allow(StripeService).to receive(:refund_payment) do
      expect(order.refunds.find_by!(idempotency_key: "crash-safe").failure_code).to eq("provider_result_unknown")
      OpenStruct.new(id: "re_ack", status: "pending")
    end
    result = described_class.call(order: order, amount_cents: 1000, idempotency_key: "crash-safe")
    expect(result).to be_pending
    expect(result.failure_code).to be_nil
    expect(result.provider_refund_id).to eq("re_ack")
  end

  it "treats a legacy pending reservation without a recorded response as uncertain after the replay window" do
    pending = create(:refund, order: order, payment: payment, amount_cents: 1000, status: :pending,
      provider_refund_id: nil, failure_code: nil, idempotency_key: "old-reservation", created_at: 2.days.ago)
    allow(StripeService).to receive(:find_refund).and_return(nil)
    allow(StripeService).to receive(:refund_payment)
    expect { described_class.call(order: order, amount_cents: 1000, idempotency_key: pending.idempotency_key) }
      .to raise_error(described_class::RefundError, /finance must reconcile/)
    expect(pending.reload).to be_pending
    expect(StripeService).not_to have_received(:refund_payment)
  end

  it "does not resubmit an acknowledged pending refund or accept a changed replay amount" do
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_pending", status: "pending"))
    first = described_class.call(order: order, amount_cents: 1000, idempotency_key: "acknowledged")
    expect(described_class.call(order: order, amount_cents: 1000, idempotency_key: "acknowledged")).to eq(first)
    expect(StripeService).to have_received(:refund_payment).once
    expect { described_class.call(order: order, amount_cents: 500, idempotency_key: "acknowledged") }.to raise_error(described_class::RefundError, /different refund/)
  end

  it "releases failed selective reservations so the ticket can be refunded again" do
    selected = order.tickets.first
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_failed", status: "failed"))
    failed = described_class.call(order: order, tickets: [selected], idempotency_key: "failed-selective")
    expect(failed).to be_failed
    expect(failed.refund_tickets.active).to be_empty
    expect(failed.refund_tickets.count).to eq(1)
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_success", status: "succeeded"))
    expect(described_class.call(order: order, tickets: [selected], idempotency_key: "retry-selective")).to be_succeeded
  end

  it "refuses to simulate a refund of a real captured payment" do
    payment.update!(provider_payment_id: "pi_real")
    expect { described_class.call(order: order, amount_cents: 1000) }.to raise_error(described_class::RefundError, /rejected/)
    expect(order.refunds.last).to be_failed
    expect(order.reload).to be_completed
  end
  it "reserves mismatched provider amounts for reconciliation without booking success" do
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_wrong_amount", status: "succeeded", amount: 500, currency: "usd"))
    expect { described_class.call(order: order, amount_cents: 1000) }.to raise_error(described_class::RefundError, /does not match/)
    expect(order.refunds.last).to be_pending
    expect(order.reload).to be_completed
    expect(order.reconciliation_exceptions).to exist(code: "refund_operation_mismatch")
  end
  it "retains the webhook payment identity when the order has a newer captured payment" do
    payment.update!(provider_payment_id: "pi_original_capture")
    create(:payment, :succeeded, order: order, provider_payment_id: "pi_newer_capture")
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_original_capture", status: "succeeded"))
    refund = described_class.call(order: order, payment: payment, amount_cents: 1000)
    expect(refund.payment_id).to eq(payment.id)
    expect(StripeService).to have_received(:refund_payment).with("pi_original_capture", anything)
  end

  %w[failed canceled].each do |terminal_status|
    it "preserves a #{terminal_status} webhook that arrives before a pending POST response" do
      selected = order.tickets.first
      allow(StripeService).to receive(:refund_payment) do
        webhook_refund = order.refunds.find_by!(idempotency_key: "in-flight-refund")
        described_class.reconcile_refund!(refund: webhook_refund,
          provider_refund: OpenStruct.new(id: "re_in_flight", status: terminal_status))
        OpenStruct.new(id: "re_in_flight", status: "pending")
      end

      result = described_class.call(order: order, tickets: [selected], idempotency_key: "in-flight-refund")

      expect(result.status).to eq(terminal_status == "canceled" ? "cancelled" : "failed")
      expect(result.refund_tickets.active).to be_empty
      expect(result.refund_tickets.count).to eq(1)
      expect(order.reload.refundable_cents).to eq(order.total_cents)
      expect(selected.reload).to be_issued
      expect(result.refund_items).to be_empty
      expect(EmailService).not_to have_received(:send_refund_notification_async)
    end
  end

  it "quarantines a stale successful response after a failed refund released its ticket reservation" do
    selected = order.tickets.first
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_late", status: "pending"))
    first = described_class.call(order: order, tickets: [selected], idempotency_key: "late-first")
    stale = Refund.find(first.id)
    described_class.reconcile_refund!(refund: first,
      provider_refund: OpenStruct.new(id: "re_late", status: "failed"))
    replacement = create(:refund, order: order, payment: payment, status: :pending,
      amount_cents: selected.refundable_cents, idempotency_key: "replacement")
    replacement.refund_tickets.create!(ticket: selected, amount_cents: selected.refundable_cents)

    result = described_class.reconcile_refund!(refund: stale,
      provider_refund: OpenStruct.new(id: "re_late", status: "succeeded"))

    expect(result).to be_failed
    expect(result.refund_tickets.active).to be_empty
    expect(replacement.refund_tickets.active).to exist
    expect(order.reload).to be_completed
    expect(order.refunded_cents).to eq(0)
    expect(selected.reload).to be_issued
    expect(ticket_type.reload.quantity_sold).to eq(2)
    expect(order.reconciliation_exceptions).to exist(code: "refund_terminal_status_conflict")
  end

  it "quarantines a stale failure after success without releasing successful ticket reservations" do
    selected = order.tickets.first
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_success_first", status: "pending"))
    pending = described_class.call(order: order, tickets: [selected], idempotency_key: "success-first")
    stale = Refund.find(pending.id)
    described_class.reconcile_refund!(refund: pending,
      provider_refund: OpenStruct.new(id: "re_success_first", status: "succeeded"))

    result = described_class.reconcile_refund!(refund: stale,
      provider_refund: OpenStruct.new(id: "re_success_first", status: "failed"))

    expect(result).to be_succeeded
    expect(result.refund_tickets.active).to exist
    expect(selected.reload).to be_cancelled
    expect(ticket_type.reload.quantity_sold).to eq(1)
    expect(order.reconciliation_exceptions).to exist(code: "refund_terminal_status_conflict")
  end

  it "blocks a new provider attempt after a failed selective refund receives contradictory success" do
    selected = order.tickets.first
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_conflict_retry", status: "failed"))
    failed = described_class.call(order: order, tickets: [selected], idempotency_key: "failed-conflict")
    described_class.reconcile_refund!(refund: failed,
      provider_refund: OpenStruct.new(id: "re_conflict_retry", status: "succeeded"))
    expect(failed.reload.refund_tickets.active).to be_empty
    allow(StripeService).to receive(:refund_payment)

    expect { described_class.call(order: order, tickets: [selected], idempotency_key: "duplicate-conflict") }
      .to raise_error(described_class::RefundError, /finance review/)

    expect(order.refunds.count).to eq(1)
    expect(selected.reload).to be_issued
    expect(described_class.call(order: order, tickets: [selected], idempotency_key: "failed-conflict")).to be_failed
    expect(StripeService).to have_received(:refund_payment).once
    expect(Commerce::RefundOutcome.call(order: order, idempotency_key: "failed-conflict")).to include(
      reconciliation_required: true, finance_review_required: true, refund_status: "failed"
    )
  end

  it "blocks resubmission of an unknown pending request when a financial mismatch is open" do
    pending = create(:refund, order: order, payment: payment, amount_cents: 1000,
      status: :pending, provider_refund_id: nil, idempotency_key: "unknown-review")
    create(:reconciliation_exception, order: nil, payment: payment, code: "refund_operation_mismatch")
    allow(StripeService).to receive(:refund_payment)

    expect { described_class.call(order: order, amount_cents: 1000, idempotency_key: pending.idempotency_key) }
      .to raise_error(described_class::RefundError, /finance review/)

    expect(pending.reload).to be_pending
    expect(StripeService).not_to have_received(:refund_payment)
  end

  it "permits trusted provider reconciliation to record a known operation while financial review remains open" do
    create(:reconciliation_exception, order: order, payment: payment, code: "refund_operation_not_found")
    allow(StripeService).to receive(:refund_payment)

    refund = described_class.call(order: order, payment: payment, amount_cents: 1000,
      idempotency_key: "provider:reviewed-operation", provider_refund: OpenStruct.new(
        id: "re_external_while_reviewing", amount: 1000, currency: "usd", status: "succeeded"
      ))

    expect(refund).to be_succeeded
    expect(order.reload.refunded_cents).to eq(1000)
    expect(StripeService).not_to have_received(:refund_payment)
    expect(Commerce::RefundOutcome.call(order: order, idempotency_key: refund.idempotency_key))
      .to include(finance_review_required: true, reconciliation_required: true)
  end

  it "applies a trusted final response to an acknowledged pending operation without resubmitting it" do
    pending = create(:refund, order: order, payment: payment, amount_cents: 1000,
      status: :pending, provider_refund_id: "re_acknowledged_review", idempotency_key: "acknowledged-review")
    create(:reconciliation_exception, order: order, payment: payment, code: "refund_operation_mismatch")
    allow(StripeService).to receive(:refund_payment)

    result = described_class.call(order: order, amount_cents: 1000, idempotency_key: pending.idempotency_key,
      provider_refund: OpenStruct.new(id: pending.provider_refund_id, amount: 1000, currency: "usd", status: "succeeded"))

    expect(result.id).to eq(pending.id)
    expect(result).to be_succeeded
    expect(order.reload.refunded_cents).to eq(1000)
    expect(StripeService).not_to have_received(:refund_payment)
  end

  it "allows a new refund after finance explicitly resolves the ambiguity" do
    exception = create(:reconciliation_exception, order: order, payment: payment, code: "refund_terminal_status_conflict")
    exception.resolve!
    expect(described_class.call(order: order, amount_cents: 1000, idempotency_key: "resolved-review")).to be_succeeded
  end

  it "does not block a refund for a nonfinancial exception" do
    create(:reconciliation_exception, order: order, code: "ticket_email_delivery_failure")
    expect(described_class.call(order: order, amount_cents: 1000, idempotency_key: "delivery-only")).to be_succeeded
  end
end
