require "rails_helper"

RSpec.describe CardPresentPayments::Processor do
  include ActiveSupport::Testing::TimeHelpers
  let(:user) { create(:user, :organizer) }
  let(:organizer_profile) { create(:organizer_profile, user: user) }
  let(:event) { create(:event, :published, organizer_profile: organizer_profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 2500) }
  let(:account) { create(:card_present_account, :verified, organization: event.organization) }
  let(:gateway) { instance_double(CardPresentGateway) }

  def pending_sale(marketing_opt_in: false)
    Commerce::OrderCreator.call(
      event: event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: "walkin@example.com",
      buyer_name: "Walk-in",
      marketing_opt_in: marketing_opt_in,
      user: user,
      payment_required: true,
      payment_provider: "boh_clover",
      service_fee: false,
      source: "box_office",
      payment_method: "door_card"
    )
  end

  it "restores an earlier unsubscribe when an opted-in card-present order completes" do
    MarketingUnsubscribe.create!(organization: event.organization, email: "walkin@example.com",
      unsubscribed_at: 2.minutes.ago)
    sale = pending_sale(marketing_opt_in: true)
    allow(gateway).to receive(:charge).and_return(CardPresentGateway::Result.new(
      provider_payment_id: "clover-opt-in", amount_cents: sale.order.total_cents, currency: "usd",
      state: "CLOSED", result: "SUCCESS", provider_response: { "id" => "clover-opt-in" }))

    attempt = described_class.call(order: sale.order, payment: sale.payment, account: account, user: user,
      idempotency_key: "terminal-opt-in", gateway: gateway)

    expect(attempt).to be_status_succeeded
    expect(sale.order).to be_completed
    expect(MarketingUnsubscribe.where(organization: event.organization, email: sale.order.buyer_email)).not_to exist
  end

  it "issues the ticket only after an exact confirmed terminal result" do
    sale = pending_sale
    result = CardPresentGateway::Result.new(
      provider_payment_id: "clover-1",
      amount_cents: sale.order.total_cents,
      currency: "usd",
      state: "CLOSED",
      result: "SUCCESS",
      provider_response: { "id" => "clover-1", "result" => "SUCCESS", "state" => "CLOSED" }
    )
    allow(gateway).to receive(:charge).and_return(result)

    attempt = described_class.call(order: sale.order, payment: sale.payment, account: account, user: user,
      idempotency_key: "terminal-sale-1", gateway: gateway)

    expect(attempt).to be_status_succeeded
    expect(sale.order.reload).to be_completed
    expect(sale.order.tickets.count).to eq(1)
    expect(sale.payment.reload).to have_attributes(status: "succeeded", provider_payment_id: "clover-1")
  end

  it "does not charge the card when a policy hold lands after the sale was started" do
    sale = pending_sale
    allow(gateway).to receive(:charge)
    EventPolicyHold.place!(event: event, actor: create(:user, :admin), scope: "sales", reason: "Policy review")

    expect do
      described_class.call(order: sale.order, payment: sale.payment, account: account, user: user,
        idempotency_key: "terminal-sale-held", gateway: gateway)
    end.to raise_error(described_class::ProcessingError, "This event is not currently on sale")

    expect(gateway).not_to have_received(:charge)
    expect(CardPresentPaymentAttempt.find_by!(idempotency_key: "terminal-sale-held")).to be_status_failed
    expect(sale.order.reload.tickets).to be_empty
  end

  it "keeps inventory reserved and opens reconciliation when the result is unknown" do
    sale = pending_sale
    original_expiry = sale.order.expires_at
    allow(gateway).to receive(:charge).and_raise(CardPresentGateway::ResultUnknown, "network timeout")

    expect do
      described_class.call(order: sale.order, payment: sale.payment, account: account, user: user,
        idempotency_key: "terminal-sale-unknown", gateway: gateway)
    end.to raise_error(described_class::ProcessingError, /network timeout/)

    attempt = CardPresentPaymentAttempt.find_by!(idempotency_key: "terminal-sale-unknown")
    expect(attempt).to be_status_result_unknown
    expect(sale.order.reload).to be_pending
    expect(sale.order.expires_at).to be > original_expiry
    expect(sale.order.inventory_holds).to all(be_active)
    expect(ReconciliationException.open).to exist(order: sale.order, payment: sale.payment, code: "card_present_result_unknown")
  end

  it "releases inventory after a known terminal failure" do
    sale = pending_sale
    allow(gateway).to receive(:charge).and_raise(CardPresentGateway::PaymentError, "cancelled")

    expect do
      described_class.call(order: sale.order, payment: sale.payment, account: account, user: user,
        idempotency_key: "terminal-sale-failed", gateway: gateway)
    end.to raise_error(described_class::ProcessingError, /cancelled/)

    expect(sale.order.reload).to be_cancelled
    expect(sale.payment.reload).to be_failed
    expect(sale.order.inventory_holds).to all(be_released)
  end

  [1.minute, 48.hours].each do |age|
    it "never resubmits a #{age}-second old unknown result, even using the original key" do
      sale = pending_sale
      allow(gateway).to receive(:charge).once.and_raise(CardPresentGateway::ResultUnknown, "network timeout")
      arguments = { order: sale.order, payment: sale.payment, account: account, user: user,
        idempotency_key: "unknown-replay", gateway: gateway }
      expect { described_class.call(**arguments) }.to raise_error(described_class::ProcessingError, /network timeout/)
      attempt = CardPresentPaymentAttempt.find_by!(idempotency_key: "unknown-replay")
      original_context = attempt.attributes.slice("failure_code", "failure_message", "provider_response", "updated_at")
      original_expiry = sale.order.reload.expires_at
      original_audits = AuditLog.where(auditable: attempt, action: "card_present.payment_result_unknown").count
      travel age do
        expect { described_class.call(**arguments) }.to raise_error(described_class::ProcessingError, /requires reconciliation/)
      end
      expect(attempt.reload).to be_status_result_unknown
      expect(attempt.attributes.slice(*original_context.keys)).to eq(original_context)
      expect(sale.order.reload.expires_at).to eq(original_expiry)
      expect(AuditLog.where(auditable: attempt, action: "card_present.payment_result_unknown").count).to eq(original_audits)
      expect(sale.payment.reload).to be_pending
      expect(sale.order.reload).to be_pending
      expect(sale.order.tickets).to be_empty
      expect(ReconciliationException.open.where(order: sale.order, code: "card_present_result_unknown").count).to eq(1)
    end
  end

  it "does not resubmit an initiated attempt left by an interrupted process" do
    sale = pending_sale
    CardPresentPaymentAttempt.create!(organization: event.organization, event: event, order: sale.order,
      payment: sale.payment, card_present_account: account, initiated_by_user: user, provider: account.provider,
      idempotency_key: "interrupted-sale", external_payment_id: "interrupted-sale", amount_cents: sale.payment.amount_cents,
      currency: "usd", initiated_at: 2.days.ago)
    expect(gateway).not_to receive(:charge)

    expect do
      described_class.call(order: sale.order, payment: sale.payment, account: account, user: user,
        idempotency_key: "interrupted-sale", gateway: gateway)
    end.to raise_error(described_class::ProcessingError, /requires reconciliation/)
    expect(ReconciliationException.open).to exist(order: sale.order, code: "card_present_result_unknown")
    expect(sale.order.reload.tickets).to be_empty
  end

  it "cannot bypass an unknown result by choosing a new key for the same payment" do
    sale = pending_sale
    allow(gateway).to receive(:charge).once.and_raise(CardPresentGateway::ResultUnknown, "network timeout")
    arguments = { order: sale.order, payment: sale.payment, account: account, user: user, gateway: gateway }
    expect { described_class.call(**arguments, idempotency_key: "original-key") }
      .to raise_error(described_class::ProcessingError, /network timeout/)
    expect { described_class.call(**arguments, idempotency_key: "replacement-key") }
      .to raise_error(described_class::ProcessingError, /original Idempotency-Key/)
    expect(sale.payment.card_present_payment_attempts.count).to eq(1)
    expect(sale.order.reload.tickets).to be_empty
  end

  it "also fails closed when the same processor instance is retried after an unknown result" do
    sale = pending_sale
    allow(gateway).to receive(:charge).once.and_raise(CardPresentGateway::ResultUnknown, "network timeout")
    processor = described_class.new(order: sale.order, payment: sale.payment, account: account, user: user,
      idempotency_key: "same-instance", gateway: gateway)
    expect { processor.call }.to raise_error(described_class::ProcessingError, /network timeout/)
    expect { processor.call }.to raise_error(described_class::ProcessingError, /requires reconciliation/)
    expect(sale.order.reload.tickets).to be_empty
  end

  it "blocks an overlapping retry and clears its uncertainty after the original exact success commits" do
    sale = pending_sale
    arguments = { order: sale.order, payment: sale.payment, account: account, user: user,
      idempotency_key: "overlapping-sale", gateway: gateway }
    result = CardPresentGateway::Result.new(provider_payment_id: "clover-overlap", amount_cents: sale.order.total_cents,
      currency: "usd", state: "CLOSED", result: "SUCCESS", provider_response: { "id" => "clover-overlap" })
    allow(gateway).to receive(:charge).once do
      expect { described_class.call(**arguments) }.to raise_error(described_class::ProcessingError, /requires reconciliation/)
      result
    end

    expect(described_class.call(**arguments)).to be_status_succeeded
    expect(sale.order.reload).to be_completed
    expect(sale.order.tickets.count).to eq(1)
    expect(ReconciliationException.open.where(order: sale.order, code: "card_present_result_unknown")).not_to exist
    expect(ReconciliationException.resolved.where(order: sale.order, code: "card_present_result_unknown")).to exist
  end

  it "retains new provider evidence after an overlapping retry and a ticket issuance rollback" do
    sale = pending_sale
    arguments = { order: sale.order, payment: sale.payment, account: account, user: user,
      idempotency_key: "overlapping-issuance-error", gateway: gateway }
    result = CardPresentGateway::Result.new(provider_payment_id: "clover-captured", amount_cents: sale.order.total_cents,
      currency: "usd", state: "CLOSED", result: "SUCCESS", provider_response: { "id" => "clover-captured" })
    allow(gateway).to receive(:charge).once do
      expect { described_class.call(**arguments) }.to raise_error(described_class::ProcessingError, /requires reconciliation/)
      result
    end
    allow(Commerce::OrderLifecycle).to receive(:complete!).and_raise(ActiveRecord::StatementInvalid, "Ticket storage interrupted")
    allow(Sentry).to receive(:capture_exception)

    expect { described_class.call(**arguments) }.to raise_error(described_class::ProcessingError, /terminal succeeded/)
    attempt = CardPresentPaymentAttempt.find_by!(idempotency_key: "overlapping-issuance-error")
    expect(attempt).to have_attributes(status: "result_unknown", provider_payment_id: "clover-captured",
      provider_response: { "id" => "clover-captured" }, failure_message: "Ticket storage interrupted")
    expect(sale.order.reload).to be_pending
    expect(sale.order.inventory_holds).to all(be_active)
    expect(sale.order.tickets).to be_empty
    expect(sale.payment.reload.provider_payment_id).not_to eq("clover-captured")
    expect(ReconciliationException.open).to exist(order: sale.order, code: "card_present_result_unknown")
  end

  it "replays a succeeded idempotency key without charging twice" do
    sale = pending_sale
    result = CardPresentGateway::Result.new(provider_payment_id: "clover-replay", amount_cents: sale.order.total_cents,
      currency: "usd", state: "CLOSED", result: "SUCCESS", provider_response: { "id" => "clover-replay" })
    allow(gateway).to receive(:charge).once.and_return(result)

    2.times do
      described_class.call(order: sale.order, payment: sale.payment, account: account, user: user,
        idempotency_key: "terminal-sale-replay", gateway: gateway)
    end

    expect(sale.order.reload.tickets.count).to eq(1)
  end
end
