# frozen_string_literal: true

require "rails_helper"

RSpec.describe Settlements::Finalizer do
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:actor) { profile.user }
  let(:event) { create(:event, :completed, organizer_profile: profile) }

  def record_sale!(sale_event, subtotal_cents: 5000, service_fee_cents: 250, processing_fee_cents: 183)
    order = create(:order, event: sale_event, subtotal_cents: subtotal_cents,
      service_fee_cents: service_fee_cents, discount_cents: 0, total_cents: subtotal_cents + service_fee_cents)
    item = create(:order_item, order: order, unit_price_cents: subtotal_cents, subtotal_cents: subtotal_cents,
      fee_cents: service_fee_cents, organizer_proceeds_cents: subtotal_cents)
    create(:fee_component, order: order, kind: "platform", amount_cents: service_fee_cents, estimated: true)
    create(:fee_component, order: order, order_item: item, kind: "processing", amount_cents: processing_fee_cents,
      estimated: false)
    [order, item]
  end

  it "creates an immutable, deterministic, cent-exact settlement without overwriting prior versions" do
    record_sale!(event)

    settlement = described_class.call(event: event, actor: actor)
    expect(settlement.attributes.symbolize_keys).to include(
      version: 1,
      gross_cents: 5000,
      discount_cents: 0,
      refund_cents: 0,
      net_cents: 5250,
      platform_fee_cents: 250,
      processing_fee_cents: 183,
      organizer_proceeds_cents: 5000,
      payable_cents: 4817,
      negative_balance_cents: 0
    )
    expect(settlement.settlement_items.pluck(:kind)).to contain_exactly(
      "sale_proceeds", "platform_fee", "processing_fee"
    )
    expect(described_class.call(event: event, actor: actor)).to eq(settlement)

    original_payable = settlement.payable_cents
    expect(settlement.update(payable_cents: 1)).to be(false)
    expect(settlement.reload.payable_cents).to eq(original_payable)

    create(:balance_adjustment, organization: organization, event: event, created_by_user: actor,
      kind: "manual_debit", amount_cents: -100, status: :posted, reason: "Venue damage",
      effective_at: Time.current)
    revised = described_class.call(event: event, actor: actor)
    expect(revised.version).to eq(2)
    expect(revised.payable_cents).to eq(4717)
    expect(settlement.reload.payable_cents).to eq(4817)
  end

  it "blocks finalization while refunds or disputes are unresolved" do
    order, = record_sale!(event)
    payment = create(:payment, :succeeded, order: order)
    refund = create(:refund, order: order, payment: payment, status: :pending, succeeded_at: nil)

    expect { described_class.call(event: event, actor: actor) }
      .to raise_error(described_class::FinalizationError, /pending refunds/)

    refund.update!(status: :failed)
    dispute = Dispute.create!(order: order, payment: payment, provider: "stripe",
      provider_dispute_id: "dp-open", amount_cents: 1000, currency: "usd", status: :open, opened_at: Time.current)
    expect { described_class.call(event: event, actor: actor) }
      .to raise_error(described_class::FinalizationError, /open disputes/)

    dispute.update!(status: :won, closed_at: Time.current)
    expect(described_class.call(event: event, actor: actor)).to be_status_finalized
  end

  it "prevents double payout and carries a post-payout refund against later organization proceeds" do
    order, item = record_sale!(event)
    create(:connected_account, organization: organization)
    settlement = described_class.call(event: event, actor: actor)
    payout = PayoutCreator.call(settlement: settlement, actor: actor, idempotency_key: "event-one-payout")
    expect(payout).to be_status_paid
    expect(payout.amount_cents).to eq(4817)
    expect(settlement.available_to_payout_cents).to eq(0)
    expect(PayoutCreator.call(settlement: settlement, actor: actor,
      idempotency_key: "event-one-payout")).to eq(payout)
    expect do
      PayoutCreator.call(settlement: settlement, actor: actor, idempotency_key: "event-one-payout", amount_cents: 1)
    end.to raise_error(PayoutCreator::PayoutError, /different payout request/)

    post_payout = described_class.call(event: event, actor: actor)
    expect(post_payout.version).to eq(2)
    expect(post_payout.available_to_payout_cents).to eq(0)
    expect do
      PayoutCreator.call(settlement: post_payout, actor: actor, idempotency_key: "double-payout")
    end.to raise_error(PayoutCreator::PayoutError, /positive/)

    payment = create(:payment, :succeeded, order: order)
    refund = create(:refund, order: order, payment: payment, amount_cents: 1000)
    create(:refund_item, refund: refund, order_item: item, amount_cents: 1000,
      organizer_proceeds_cents: 900, fee_cents: 100)
    order.update!(status: :partially_refunded, refund_amount_cents: 1000)
    refunded = described_class.call(event: event, actor: actor)
    expect(refunded.version).to eq(3)
    expect(refunded.payable_cents).to eq(3917)
    expect(refunded.negative_balance_cents).to eq(900)

    second_event = create(:event, :completed, organizer_profile: profile)
    record_sale!(second_event)
    second_settlement = described_class.call(event: second_event, actor: actor)
    expect(OrganizationPayoutBalance.available_cents(organization)).to eq(3917)
    expect do
      PayoutCreator.call(settlement: second_settlement, actor: actor, idempotency_key: "too-large",
        amount_cents: 4817)
    end.to raise_error(PayoutCreator::PayoutError, /available balance/)

    carried_payout = PayoutCreator.call(settlement: second_settlement, actor: actor,
      idempotency_key: "net-of-negative", amount_cents: 3917)
    expect(carried_payout).to be_status_paid
    expect(OrganizationPayoutBalance.available_cents(organization)).to eq(0)
  end

  it "calculates organization balance from only the latest finalized settlement per event" do
    record_sale!(event)
    described_class.call(event: event, actor: actor)
    create(:balance_adjustment, organization: organization, event: event, created_by_user: actor,
      kind: "manual_debit", amount_cents: -100, status: :posted, reason: "Final adjustment",
      effective_at: Time.current)
    described_class.call(event: event, actor: actor)

    second_event = create(:event, :completed, organizer_profile: profile)
    record_sale!(second_event)
    described_class.call(event: second_event, actor: actor)

    expect(OrganizationPayoutBalance.available_cents(organization)).to eq(9534)
  end

  it "keeps an unexpectedly ambiguous provider result committed for reconciliation" do
    record_sale!(event)
    create(:connected_account, organization: organization)
    settlement = described_class.call(event: event, actor: actor)
    allow(PayoutGateway).to receive(:submit).and_raise(StandardError, "socket closed")
    allow(Sentry).to receive(:capture_exception)

    expect do
      PayoutCreator.call(settlement: settlement, actor: actor, idempotency_key: "ambiguous-provider")
    end.to raise_error(PayoutCreator::PayoutError, /result is unknown/)

    payout = Payout.find_by!(idempotency_key: "ambiguous-provider")
    expect(payout).to be_status_processing
    expect(payout).to have_attributes(failure_code: "provider_result_unknown", failure_message: "socket closed")
    expect(OrganizationPayoutBalance.available_cents(organization)).to eq(0)
    expect(AuditLog.where(auditable: payout, action: "payout.processing")).to exist
    expect(PayoutCreator.call(settlement: settlement, actor: actor,
      idempotency_key: "ambiguous-provider")).to eq(payout)
  end
  it "deducts a late loss from another event payout without refinalizing the first event" do
    order, = record_sale!(event)
    create(:connected_account, organization: organization)
    first = described_class.call(event: event, actor: actor)
    PayoutCreator.call(settlement: first, actor: actor, idempotency_key: "first-paid")
    second_event = create(:event, :completed, organizer_profile: profile)
    record_sale!(second_event)
    second = described_class.call(event: second_event, actor: actor)
    Dispute.create!(order: order, provider: "stripe", provider_dispute_id: "dp-late", amount_cents: 1000,
      currency: "usd", status: :lost, opened_at: Time.current, closed_at: Time.current)
    expect(OrganizationPayoutBalance.available_cents(organization)).to eq(3817)
    expect(first.reload.payable_cents).to eq(4817)
    expect { PayoutCreator.call(settlement: second, actor: actor, amount_cents: 4817, idempotency_key: "overdraw") }.to raise_error(PayoutCreator::PayoutError, /available balance/)
  end

  it "blocks closeout and organization payouts for an uncatalogued reconciliation code" do
    order, = record_sale!(event)
    settlement = described_class.call(event: event, actor: actor)
    exception = ReconciliationException.create!(order: order, code: "late_capture")
    expect { described_class.call(event: event, actor: actor) }.to raise_error(described_class::FinalizationError, /reconciliation/)
    expect(OrganizationPayoutBalance.available_cents(organization)).to eq(0)
    exception.resolve!
    expect(OrganizationPayoutBalance.available_cents(organization)).to eq(settlement.payable_cents)
  end

  it "requires delivery reconciliation at closeout even though it does not prevent buyer refund attempts" do
    order, = record_sale!(event)
    payment = create(:payment, :succeeded, order: order)
    settlement = described_class.call(event: event, actor: actor)
    exception = ReconciliationException.create!(order: nil, payment: payment, code: "ticket_email_delivery_failure")

    expect(Commerce::RefundSafety.finance_review_required?(order)).to be(false)
    expect { described_class.call(event: event, actor: actor) }
      .to raise_error(described_class::FinalizationError, /reconciliation/)
    expect(OrganizationPayoutBalance.available_cents(organization)).to eq(0)

    exception.resolve!
    expect(described_class.call(event: event, actor: actor)).to eq(settlement)
    expect(OrganizationPayoutBalance.available_cents(organization)).to eq(settlement.payable_cents)
  end

  it "reserves pending refunds and open disputes from current organization funds" do
    order, = record_sale!(event)
    described_class.call(event: event, actor: actor)
    create(:refund, order: order, status: :pending, amount_cents: 1000)
    Dispute.create!(order: order, provider: "stripe", provider_dispute_id: "dp-reserve", amount_cents: 500,
      currency: "usd", status: :open, opened_at: Time.current)
    expect(OrganizationPayoutBalance.available_cents(organization)).to eq(3317)
  end
  it "protects later event proceeds immediately after a refund on an already paid event" do
    order, item = record_sale!(event)
    create(:connected_account, organization: organization)
    first = described_class.call(event: event, actor: actor)
    PayoutCreator.call(settlement: first, actor: actor, idempotency_key: "paid-before-refund")
    later_event = create(:event, :completed, organizer_profile: profile)
    record_sale!(later_event)
    described_class.call(event: later_event, actor: actor)
    refund = create(:refund, order: order, amount_cents: 1000)
    create(:refund_item, refund: refund, order_item: item, amount_cents: 1000, organizer_proceeds_cents: 900, fee_cents: 100)
    order.update!(status: :partially_refunded, refund_amount_cents: 1000)
    expect(event.settlements.count).to eq(1)
    expect(OrganizationPayoutBalance.available_cents(organization)).to eq(3917)
    expect(first.reload.payable_cents).to eq(4817)
  end
  it "deducts negative balances before event finalization and organization-level debits" do
    record_sale!(event)
    described_class.call(event: event, actor: actor)
    unfinalized = create(:event, :completed, organizer_profile: profile)
    create(:balance_adjustment, organization: organization, event: unfinalized, created_by_user: actor,
      kind: "manual_debit", amount_cents: -700, status: :posted, effective_at: Time.current)
    create(:balance_adjustment, organization: organization, event: nil, created_by_user: actor,
      kind: "reserve_hold", amount_cents: -300, status: :posted, effective_at: Time.current)
    expect(OrganizationPayoutBalance.available_cents(organization)).to eq(3817)
  end
end
