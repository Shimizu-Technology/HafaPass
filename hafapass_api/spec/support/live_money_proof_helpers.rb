module LiveMoneyProofHelpers
  def stub_live_money_provider_ready
    settings = SiteSetting.instance
    allow(SiteSetting).to receive(:instance).and_return(settings)
    allow(settings).to receive(:live_mode?).and_return(true)
    allow(settings).to receive(:payment_mode).and_return("live")
    allow(PlatformCapabilities).to receive(:enabled?).with("stripe_live").and_return(true)
  end

  def create_live_money_proof_chain
    stub_live_money_provider_ready
    profile = create(:organizer_profile, :payout_ready)
    event = create(:event, :published, organizer_profile: profile, organization: profile.organization,
      title: "[LIVE MONEY TEST] Gate H", max_capacity: 1, live_money_proof_candidate: true)
    ticket_type = create(:ticket_type, event: event, name: "One-time proof ticket", price_cents: 100,
      quantity_available: 1, max_per_order: 1, max_per_buyer: 1)
    rehearsal = create_event_day_rehearsal_approval(event: event)
    requester = create(:user, :admin)
    authorization = LiveMoneyProofAuthorizations::Manager.request!(
      event: event, buyer_email: "finance-proof@example.com", max_amount_cents: 200,
      expires_at: 90.minutes.from_now, actor: requester
    )
    authorization = LiveMoneyProofAuthorizations::Manager.approve!(
      authorization: authorization, actor: create(:user, :admin)
    )

    order = create(:order, event: event, status: :completed, subtotal_cents: 100, service_fee_cents: 0,
      discount_cents: 0, total_cents: 100, refund_amount_cents: 0,
      buyer_email: "finance-proof@example.com", buyer_name: "Finance proof operator")
    item = create(:order_item, order: order, ticket_type: ticket_type, unit_price_cents: 100,
      subtotal_cents: 100, fee_cents: 0, organizer_fee_cents: 0, organizer_proceeds_cents: 100)
    create(:fee_component, order: order, order_item: item, kind: "processing", amount_cents: 5,
      estimated: false)
    payment = create(:payment, order: order, provider: "stripe", provider_payment_id: "pi_live_gate_h",
      amount_cents: 100, status: :succeeded, succeeded_at: 6.minutes.ago)
    LiveMoneyProofAuthorizations::Manager.claim!(
      authorization: authorization, order: order, amount_cents: order.total_cents,
      user: requester, buyer_email: order.buyer_email
    )
    event.update_columns(status: Event.statuses[:completed])

    partial_refund = create(:refund, order: order, payment: payment, provider_refund_id: "re_live_partial",
      amount_cents: 20, status: :succeeded, succeeded_at: 5.minutes.ago)
    create(:refund_item, refund: partial_refund, order_item: item, amount_cents: 20,
      organizer_proceeds_cents: 20, fee_cents: 0, organizer_fee_cents: 0)
    order.update!(status: :partially_refunded, refund_amount_cents: 20)
    payment.update!(status: :partially_refunded)

    initial_settlement = Settlements::Finalizer.call(event: event, actor: requester)
    initial_settlement.update_columns(calculated_at: 4.minutes.ago, finalized_at: 4.minutes.ago)
    payout = PayoutCreator.call(settlement: initial_settlement, actor: requester,
      idempotency_key: "gate-h-live-payout")
    payout.update!(provider_payout_id: "bank_live_gate_h")
    payout.update_columns(initiated_at: 3.minutes.ago, paid_at: 3.minutes.ago)

    final_refund = create(:refund, order: order, payment: payment, provider_refund_id: "re_live_final",
      amount_cents: 80, status: :succeeded, succeeded_at: 2.minutes.ago)
    create(:refund_item, refund: final_refund, order_item: item, amount_cents: 80,
      organizer_proceeds_cents: 80, fee_cents: 0, organizer_fee_cents: 0)
    order.update!(status: :refunded, refund_amount_cents: 100, refunded_at: 2.minutes.ago)
    payment.update!(status: :refunded)
    post_payout_settlement = Settlements::Finalizer.call(event: event, actor: requester)
    post_payout_settlement.update_columns(calculated_at: 1.minute.ago, finalized_at: 1.minute.ago)

    attributes = valid_live_money_proof_attributes(
      event: event, rehearsal: rehearsal, authorization: authorization, order: order, payment: payment,
      partial_refund: partial_refund, final_refund: final_refund, initial_settlement: initial_settlement,
      payout: payout, post_payout_settlement: post_payout_settlement
    )
    {
      profile: profile, organization: profile.organization, event: event, rehearsal: rehearsal,
      authorization: authorization, order: order, payment: payment, partial_refund: partial_refund,
      final_refund: final_refund, initial_settlement: initial_settlement, payout: payout,
      post_payout_settlement: post_payout_settlement, attributes: attributes
    }
  end

  def valid_live_money_proof_attributes(event:, rehearsal:, authorization:, order:, payment:, partial_refund:,
    final_refund:, initial_settlement:, payout:, post_payout_settlement:)
    processing_fee = FeeComponent.where(order: order, kind: "processing", estimated: false).sum(:amount_cents)
    {
      proof_event_id: event.id, event_day_rehearsal_review_id: rehearsal.id,
      authorization_id: authorization.id, order_id: order.id,
      payment_id: payment.id, partial_refund_id: partial_refund.id, final_refund_id: final_refund.id,
      initial_settlement_id: initial_settlement.id, payout_id: payout.id,
      post_payout_settlement_id: post_payout_settlement.id,
      evidence_reference: "restricted-finance/gate-h/#{event.id}", evidence_digest: "f" * 64,
      entity_results: {
        legal_entity_reference: "restricted-entity/hafapass", organizer_reference: "restricted-organizer/#{event.organization_id}",
        bank_account_reference: "restricted-bank/settlement", provider_approval_reference: "restricted-provider/live",
        charge_provider: "stripe", payout_provider: payout.provider, production_environment: true
      },
      provider_results: {
        charge_reference: payment.provider_payment_id, charge_amount_cents: payment.amount_cents, currency: "usd",
        partial_refund_reference: partial_refund.provider_refund_id,
        partial_refund_amount_cents: partial_refund.amount_cents,
        final_refund_reference: final_refund.provider_refund_id, final_refund_amount_cents: final_refund.amount_cents,
        initial_settlement_digest: initial_settlement.source_digest, payout_reference: payout.provider_payout_id,
        payout_amount_cents: payout.amount_cents, bank_receipt_reference: "restricted-bank/receipt/gate-h",
        bank_receipt_digest: "b" * 64, bank_receipt_amount_cents: payout.amount_cents,
        post_payout_settlement_digest: post_payout_settlement.source_digest,
        post_payout_negative_balance_cents: post_payout_settlement.negative_balance_cents
      },
      reconciliation_results: {
        provider_charge_cents: payment.amount_cents, local_charge_cents: payment.amount_cents,
        charge_variance_cents: 0, provider_refund_cents: 100, local_refund_cents: 100,
        refund_variance_cents: 0, provider_processing_fee_cents: processing_fee,
        local_processing_fee_cents: processing_fee, processing_fee_variance_cents: 0,
        provider_payout_cents: payout.amount_cents, local_payout_cents: payout.amount_cents,
        bank_receipt_cents: payout.amount_cents, payout_variance_cents: 0,
        local_negative_balance_cents: post_payout_settlement.negative_balance_cents,
        negative_balance_variance_cents: 0, open_reconciliation_exception_count: 0,
        open_dispute_count: 0, pending_refund_count: 0
      },
      communication_results: LiveMoneyProofReview::COMMUNICATION_KEYS.index_with do |key|
        { status: "confirmed", evidence_reference: "restricted-communications/#{key}" }
      end,
      controls: LiveMoneyProofReview::CONTROL_KEYS.index_with(true),
      effective_at: 1.minute.ago, expires_at: 30.days.from_now
    }
  end
end

RSpec.configure do |config|
  config.include LiveMoneyProofHelpers
end
