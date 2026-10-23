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
    component = create(:fee_component, order: order, order_item: item, kind: "processing", amount_cents: processing_fee_cents,
      estimated: false, provider_reference: "txn_fixture_#{SecureRandom.hex(8)}")
    capture = create(:payment, :succeeded, order: order)
    create(:stripe_fee_evidence, :verified, payment: capture, fee_component: component, provider_balance_transaction_id: component.provider_reference)
    [order, item]
  end

  def auditable_payout_settlement
    create(:connected_account, organization: organization)
    create(:balance_adjustment, organization: organization, event: event, amount_cents: 1000)
    described_class.call(event: event, actor: actor)
  end

  it "commits payout reservation and intent audits before the provider and deduplicates retries" do
    settlement = auditable_payout_settlement
    baseline_transactions = Payout.connection.open_transactions
    allow(PayoutGateway).to receive(:submit) do |payout|
      expect(Payout.connection.open_transactions).to eq(baseline_transactions)
      expect(AuditLog.where(auditable: payout).pluck(:action)).to include(
        "payout.created", "payout.submission_requested")
      expect(AuditLog.where(auditable: payout, action: %w[payout.created payout.submission_requested]))
        .to all(have_attributes(actor_user_id: actor.id, organization_id: organization.id,
          event_id: event.id, outcome: "requested"))
      PayoutGateway::Result.new(provider_payout_id: "bank_audited_payout", status: :paid)
    end

    payout = PayoutCreator.call(settlement: settlement, actor: actor, idempotency_key: "audited-payout")
    expect(PayoutCreator.call(settlement: settlement, actor: actor, idempotency_key: "audited-payout")).to eq(payout)
    expect(AuditLog.where(auditable: payout, action: "payout.created").count).to eq(1)
    expect(AuditLog.find_by!(auditable: payout, action: "payout.paid")).to have_attributes(
      source: "provider", outcome: "succeeded", organization_id: organization.id, event_id: event.id)
    expect(PayoutGateway).to have_received(:submit).once
  end

  it "reserves an ambiguous payout without a success row or a second submission" do
    settlement = auditable_payout_settlement
    allow(PayoutGateway).to receive(:submit).and_raise(Timeout::Error, "private-provider-timeout")
    expect do
      PayoutCreator.call(settlement: settlement, actor: actor, idempotency_key: "audited-unknown-payout")
    end.to raise_error(PayoutCreator::PayoutError, /unknown/)
    payout = settlement.payouts.sole
    audit = AuditLog.find_by!(auditable: payout, action: "payout.processing")
    expect(audit).to have_attributes(source: "provider", outcome: "unknown")
    expect(audit.attributes.to_json).not_to include("private-provider-timeout")
    expect(AuditLog.where(auditable: payout, action: "payout.paid")).not_to exist
    expect(PayoutCreator.call(settlement: settlement, actor: actor, idempotency_key: "audited-unknown-payout")).to eq(payout)
    expect(PayoutGateway).to have_received(:submit).once
    expect(AuditLog.where(auditable: payout, action: "payout.processing").count).to eq(1)
  end

  it "rolls back a payout reservation when its creation audit fails" do
    settlement = auditable_payout_settlement
    allow(AuditLogger).to receive(:record!).and_call_original
    allow(AuditLogger).to receive(:record!).with(hash_including(action: "payout.created"))
      .and_raise(ActiveRecord::RecordInvalid.new(AuditLog.new))
    allow(PayoutGateway).to receive(:submit)
    expect do
      PayoutCreator.call(settlement: settlement, actor: actor, idempotency_key: "payout-reservation-rollback")
    end.to raise_error(PayoutCreator::PayoutError)
    expect(settlement.payouts.reload).to be_empty
    expect(PayoutGateway).not_to have_received(:submit)
  end

  it "deduplicates repeated pending provider outcomes without claiming a paid transfer" do
    settlement = auditable_payout_settlement
    allow(PayoutGateway).to receive(:submit).and_return(
      PayoutGateway::Result.new(provider_payout_id: "bank_processing_audit", status: :processing))
    payout = PayoutCreator.call(settlement: settlement, actor: actor, idempotency_key: "processing-payout-audit")
    creator = PayoutCreator.new(settlement: settlement, actor: actor, idempotency_key: payout.idempotency_key)
    creator.send(:record_submission_outcome!, payout, status: :processing,
      provider_payout_id: "bank_processing_audit", initiated_at: Time.current)
    audit = AuditLog.where(auditable: payout, action: "payout.processing").sole
    expect(audit).to have_attributes(outcome: "requested", source: "provider")
    expect(AuditLog.where(auditable: payout, action: "payout.paid")).not_to exist
    expect(payout.reload).to be_status_processing
  end

  it "records definitive payout rejection as failure and retains the reservation intent" do
    settlement = auditable_payout_settlement
    allow(PayoutGateway).to receive(:submit).and_raise(PayoutGateway::PayoutError, "private-provider-rejection")
    expect do
      PayoutCreator.call(settlement: settlement, actor: actor, idempotency_key: "rejected-payout-audit")
    end.to raise_error(PayoutCreator::PayoutError)
    payout = settlement.payouts.sole
    expect(payout).to be_status_failed
    audit = AuditLog.find_by!(auditable: payout, action: "payout.failed")
    expect(audit).to have_attributes(outcome: "failed", source: "provider")
    expect(audit.attributes.to_json).not_to include("private-provider-rejection")
    expect(AuditLog.where(auditable: payout, action: "payout.submission_requested").count).to eq(1)
  end

  it "does not call the provider or classify an audit failure as provider uncertainty" do
    settlement = auditable_payout_settlement
    allow(AuditLogger).to receive(:record!).and_call_original
    allow(AuditLogger).to receive(:record!).with(hash_including(action: "payout.submission_requested"))
      .and_raise(ActiveRecord::RecordInvalid.new(AuditLog.new))
    allow(PayoutGateway).to receive(:submit)
    expect do
      PayoutCreator.call(settlement: settlement, actor: actor, idempotency_key: "payout-intent-rollback")
    end.to raise_error(PayoutCreator::PayoutError)
    expect(settlement.payouts.sole).to have_attributes(status: "pending", failure_code: nil)
    expect(PayoutGateway).not_to have_received(:submit)
    expect(AuditLog.where(auditable: settlement.payouts.sole).pluck(:action)).to eq(["payout.created"])
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
    payment = order.payments.first
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

  it "blocks a legacy cancelled event with a live paid order and no refund run" do
    cancelled_event = create(:event, :cancelled, organizer_profile: profile)
    order, = record_sale!(cancelled_event)
    order.payments.update_all(provider_environment: "live")
    create(:connected_account, organization: organization)
    expect(cancelled_event.event_cancellation_refund_run).to be_nil

    expect { described_class.call(event: cancelled_event, actor: actor) }
      .to raise_error(described_class::FinalizationError, /Finish cancellation refunds/)
    settlement = create(:settlement, event: cancelled_event, organization: organization)
    expect { PayoutCreator.call(settlement: settlement, actor: actor,
      idempotency_key: "cancelled-without-run") }
      .to raise_error(PayoutCreator::PayoutError, /Finish cancellation refunds/)
  end

  it "finalizes a cancelled event with no paid orders and no refund run" do
    cancelled_event = create(:event, :cancelled, organizer_profile: profile)
    create(:balance_adjustment, organization: organization, event: cancelled_event, created_by_user: actor,
      kind: "manual_credit", amount_cents: 1000, status: :posted, reason: "Organizer credit",
      effective_at: Time.current)
    create(:connected_account, organization: organization)
    expect(cancelled_event.event_cancellation_refund_run).to be_nil
    settlement = described_class.call(event: cancelled_event, actor: actor)
    expect(settlement).to be_status_finalized
    payout = PayoutCreator.call(settlement: settlement, actor: actor,
      idempotency_key: "cancelled-without-paid-orders")
    expect(payout).to be_status_paid
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

    payment = order.payments.first
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

  it "reserves the gross payout and records cent-exact withholding and net disbursement" do
    record_sale!(event)
    create(:connected_account, organization: organization)
    organization.organizer_tax_information.update!(backup_withholding_flag: true,
      backup_withholding_reason: "CPA requested backup withholding")
    settlement = described_class.call(event: event, actor: actor)

    expect { PayoutCreator.call(settlement: settlement, actor: actor, idempotency_key: "tax-block") }
      .to raise_error(PayoutCreator::PayoutError, /blocks this payout/)
    expect(organization.payouts).to be_empty

    SiteSetting.instance.update!(backup_withholding_mode: "withhold")
    payout = PayoutCreator.call(settlement: settlement, actor: actor, idempotency_key: "tax-withheld")

    expect(payout).to be_status_paid
    expect(payout).to have_attributes(amount_cents: 4817, withheld_cents: 1156, disbursement_cents: 3661)
    expect(settlement.available_to_payout_cents).to eq(0)
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

  it "cannot clear an existing liability with a simulated production payout after a mode change" do
    order, = record_sale!(event)
    # Production settles live Stripe money only.
    order.payments.update_all(provider_environment: "live")
    create(:connected_account, organization: organization)
    settlement = described_class.call(event: event, actor: actor)
    SiteSetting.instance.update!(payment_mode: "simulate")
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))

    expect do
      PayoutCreator.call(settlement: settlement, actor: actor, idempotency_key: "production-simulation")
    end.to raise_error(PayoutCreator::PayoutError, /Simulated payouts are disabled in production/)

    payout = Payout.find_by!(idempotency_key: "production-simulation")
    expect(payout).to have_attributes(status: "failed", provider_payout_id: nil, paid_at: nil)
    expect(settlement.available_to_payout_cents).to eq(4817)
    expect(OrganizationPayoutBalance.available_cents(organization)).to eq(4817)
    expect(event.payouts.status_paid).to be_empty
  end

  it "binds local simulation to the original money context rather than a changed global mode" do
    order, = record_sale!(event)
    order.payments.update_all(provider_environment: "live")
    create(:connected_account, organization: organization)
    settlement = described_class.call(event: event, actor: actor)
    SiteSetting.instance.update!(payment_mode: "simulate")

    expect do
      PayoutCreator.call(settlement: settlement, actor: actor, idempotency_key: "live-context-simulation")
    end.to raise_error(PayoutCreator::PayoutError, /Live payment proceeds cannot be paid through simulation/)
    expect(event.payouts.status_paid).to be_empty
    expect(OrganizationPayoutBalance.available_cents(organization)).to eq(4817)
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
    payment = order.payments.first
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
    create(:refund, order: order, payment: order.payments.first, status: :pending, amount_cents: 1000)
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
    refund = create(:refund, order: order, payment: order.payments.first, amount_cents: 1000)
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
