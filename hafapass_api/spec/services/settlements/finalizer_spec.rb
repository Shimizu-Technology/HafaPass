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

    expect(Settlements::Calculator).not_to receive(:call)
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
end
