# frozen_string_literal: true

require "rails_helper"

# A2 review finding 2 (17324039): a never_fulfilled_buyer_overpaid exception
# stops being a P4 exception when its platform-only proof fails. Its hold
# starts at the earliest durable time of the fact that defeats the proof
# (hafapass_overpaid_proof_lost_at), never at the reading transaction's
# now(). Every statement here commits on its own (no wrapping transaction),
# as production reconciliations do, so a now()-based start would advance
# with each reconciliation and let a transfer sent after the proof failed
# through. Both the application reconciler and the database fence are
# checked before, at and after the cutoff.
RSpec.describe "P4 hold cutoff after the proof fails", :non_transactional do
  self.use_transactional_tests = false

  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 2000) }

  def clean_test_data
    unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database.end_with?("_test")
      raise "Isolated test database required"
    end

    ActiveRecord::Base.connection.execute(<<~SQL)
      TRUNCATE TABLE audit_logs, audit_write_failures, organizations, users, organizer_profiles, events, site_settings,
        webhook_events, checkout_attempts
      RESTART IDENTITY CASCADE
    SQL
  end

  before do
    clean_test_data
    allow(StripeService).to receive(:verify_payment_context!)
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
    allow(Sentry).to receive(:capture_message)
    allow(Sentry).to receive(:capture_exception)
    allow(PayoutGateway).to receive(:submit) do |payout|
      PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing)
    end
    approved_bank_account!(organization, actor: profile.user, admin: admin)
  end

  after { clean_test_data }

  # A $100.00 sale beside a classified $13.60 order returned twice (refund
  # and lost dispute): the over-return is proven platform-only, so nothing
  # holds the event. Three payouts are submitted on the current statement.
  def proven_overpaid_event!
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5, processing_fee_cents: 100)
    order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]], event: event)
    component = create(:fee_component, order: order, order_item: order.order_items.first, kind: "processing",
      amount_cents: 69, estimated: false, provider_reference: "txn_p4_#{SecureRandom.hex(4)}")
    create(:stripe_fee_evidence, :verified, payment: payment, fee_component: component,
      provider_balance_transaction_id: component.provider_reference)
    ingest_provider_refund!(payment, 1360, id: "re_p4_#{SecureRandom.hex(3)}")
    lose_dispute!(payment, "dp_p4_#{SecureRandom.hex(3)}", amount: 1360)
    Commerce::NeverFulfilledResolution.evaluate!(capture.reload, trigger: "spec")
    overpaid = ReconciliationException.open.find_by!(payment: payment, code: "never_fulfilled_buyer_overpaid")
    expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(false)
    payouts = %w[pre at post].map do |label|
      PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
        idempotency_key: "p4-#{label}", amount_cents: 1000)
    end
    [order, payment, overpaid, payouts]
  end

  def record_paid!(payout, confirmed_at)
    PayoutReconciler.call(payout: payout.reload, actor: admin, status: "paid", provider_payout_id: "bank-p4-#{payout.id}",
      evidence: { reference: "Bank transfer record", reason: "Transfer confirmed by the bank",
        confirmed_at: confirmed_at.utc.iso8601(6), approved_tax_payee_confirmed: true, sent_before_hold_confirmed: true })
  end

  # The database fence alone (as any writer, with the transfer named):
  # rolled back either way.
  def database_paid?(payout, paid_at)
    ActiveRecord::Base.transaction do
      FinancialIntegrity.with_settlement_reader do
        FinancialIntegrity.with_payout_transfer(payout.id) do
          PayoutCustody.record!(payout, basis: "recorded_at_paid")
          Payout.where(id: payout.id).update_all(status: Payout.statuses[:paid], paid_at: paid_at)
        end
      end
      raise ActiveRecord::Rollback
    end
    true
  rescue ActiveRecord::StatementInvalid => e
    raise unless e.message.include?("before the hold")

    false
  end

  it "starts the hold when a new dispute defeats the proof, and keeps it there through repeated reconciliation" do
    _order, payment, overpaid, (pre, at, post) = proven_overpaid_event!
    sleep 0.02
    before_loss = Time.current
    sleep 0.02
    dispute = Dispute.create!(order: payment.order, payment: payment, provider: "stripe", amount_cents: 1360, currency: "usd",
      provider_dispute_id: "dp_p4_open_#{SecureRandom.hex(3)}", status: :open, opened_at: Time.current, reason: "fraudulent")
    lost_at = dispute.reload.created_at
    expect(lost_at).to be > overpaid.created_at

    first = Commerce::NeverFulfilledPayoutHold.block_started_at(event)
    expect(first).to eq(lost_at)
    sleep 0.05
    # A later, separate reading transaction: the same start, not its own now().
    expect(Commerce::NeverFulfilledPayoutHold.block_started_at(event)).to eq(lost_at)
    expect(ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(["SELECT hafapass_overpaid_proof_lost_at(?)", payment.id])
    ).then { |value| ActiveRecord::Type::DateTime.new.cast(value) }).to eq(lost_at)

    # Database fence: before the loss passes, at or after it is refused.
    expect(database_paid?(pre, lost_at - 0.000001)).to be(true)
    expect(database_paid?(at, lost_at)).to be(false)
    expect(database_paid?(post, Time.current)).to be(false)

    # The open dispute also sits in the refund queue, which the reconciler
    # refuses on its own; the reconciler's boundary is the next example.
    expect(Commerce::NeverFulfilledPayoutHold.block_started_at(event)).to eq(lost_at)
  end

  # CodeRabbit 4703321681 and the lead's monotonic-cutoff brief: a fact that
  # defeated the proof and then resolved, while a later one still defeats
  # it, must not move the cutoff later.
  it "keeps the first loss as the cutoff when the first defeating fact resolves while a later one still holds" do
    order, payment, _overpaid, (pre, at, _post) = proven_overpaid_event!
    sleep 0.02
    dispute = Dispute.create!(order: payment.order, payment: payment, provider: "stripe", amount_cents: 1360, currency: "usd",
      provider_dispute_id: "dp_p4_mono_#{SecureRandom.hex(3)}", status: :open, opened_at: Time.current, reason: "fraudulent")
    first_loss = dispute.reload.created_at
    sleep 0.05
    between = Time.current
    sleep 0.05
    debit = organization.balance_adjustments.create!(event: event, order: order, kind: "manual_debit", amount_cents: -500,
      currency: "usd", status: :posted, reason: "Fictional linked debit", effective_at: Time.current, created_by_user: admin)
    expect(debit.reload.created_at).to be > between
    expect(Commerce::NeverFulfilledPayoutHold.block_started_at(event)).to eq(first_loss)

    # The dispute is won: no loss, so it no longer defeats the proof.
    Dispute.where(id: dispute.id).update_all(status: Dispute.statuses[:won], closed_at: Time.current)
    expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(true)
    expect(Commerce::NeverFulfilledPayoutHold.block_started_at(event)).to eq(first_loss)
    expect(database_paid?(at, between)).to be(false)
    expect(database_paid?(pre, first_loss - 0.000001)).to be(true)
  end

  it "starts the hold at a linked adjustment (the review's case) and refuses a transfer sent after it" do
    order, _payment, _overpaid, (pre, at, post) = proven_overpaid_event!
    sleep 0.02
    before_loss = Time.current
    sleep 0.02
    debit = organization.balance_adjustments.create!(event: event, order: order, kind: "manual_debit", amount_cents: -500,
      currency: "usd", status: :posted, reason: "Fictional linked debit", effective_at: Time.current, created_by_user: admin)
    lost_at = debit.reload.created_at
    expect(Commerce::NeverFulfilledPayoutHold.block_started_at(event)).to eq(lost_at)

    # Reconciler, each recording its own transaction, time passing between.
    sleep 0.05
    expect { record_paid!(post, Time.current) }
      .to raise_error(PayoutReconciler::ReconciliationError, Commerce::NeverFulfilledPayoutHold::PAID_MESSAGE)
    expect { record_paid!(at, lost_at) }
      .to raise_error(PayoutReconciler::ReconciliationError, Commerce::NeverFulfilledPayoutHold::PAID_MESSAGE)
    expect(database_paid?(post, lost_at + 0.01)).to be(false)
    expect(database_paid?(at, lost_at)).to be(false)
    sleep 0.05
    expect(record_paid!(pre, before_loss)).to be_status_paid
    audit = AuditLog.where(auditable: pre, action: "payout.reconciled").sole
    expect(audit.metadata["never_fulfilled_hold_started_at"]).to eq(lost_at.utc.iso8601(6))
    expect(Commerce::NeverFulfilledPayoutHold.block_started_at(event)).to eq(lost_at)
    expect([at.reload.status, post.reload.status]).to eq(%w[processing processing])
  end
end
