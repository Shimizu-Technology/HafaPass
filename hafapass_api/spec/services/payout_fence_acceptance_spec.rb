# frozen_string_literal: true

require "rails_helper"

# A2 payout fences (CodeRabbit 4703321670 and 4703321688):
#   - a transfer the provider accepted while the paid write was refused by a
#     fence is kept (in flight, with its reference, as a conflict finance must
#     review), is never sent again, and is recorded by an audited no-send
#     outcome that does not depend on the transfer time and never makes it an
#     ordinary paid payout;
#   - a payout inserted already paid (or reversed, or paid and reversed
#     before commit) commits only with its custody row.
RSpec.describe "A2 payout fence acceptance and paid inserts" do
  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 2000) }

  before do
    allow(StripeService).to receive(:verify_payment_context!)
    allow(Sentry).to receive(:capture_message)
    allow(Sentry).to receive(:capture_exception)
    approved_bank_account!(organization, actor: profile.user, admin: admin)
  end

  describe "provider acceptance refused by the paid fence" do
    it "keeps the accepted transfer, never resends it and records it only through the audited no-send outcome" do
      sale_order, _item, sale_payment = record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      settlement = Settlements::Finalizer.call(event: event, actor: admin)
      calls = 0
      # The gateway call runs outside the payout locks; a repayment hold opens
      # on the event while it is in flight, and the provider then reports the
      # transfer paid.
      allow(PayoutGateway).to receive(:submit) do |_payout|
        calls += 1
        ReconciliationException.create!(order: sale_order, payment: sale_payment, code: "never_fulfilled_repayment_reopened")
        PayoutGateway::Result.new(provider_payout_id: "bank-accepted-1", status: :paid)
      end

      payout = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "fence-accept", amount_cents: 1000)
      expect(payout.reload).to have_attributes(status: "processing", provider_payout_id: "bank-accepted-1",
        failure_code: "provider_result_conflict", paid_at: nil)
      expect(PayoutCustodyDetermination.where(payout: payout)).to be_empty
      conflict = AuditLog.where(auditable: payout, action: "payout.provider_result_conflict").sole
      expect(conflict.metadata).to include("conflict_reason" => PayoutCreator::PAID_REFUSED_REASON)
      expect(conflict.metadata["refusal"]).to start_with("Repayment fence")

      # Never sent again.
      expect(PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "fence-accept", amount_cents: 1000))
        .to eq(payout)
      expect(calls).to eq(1)

      evidence = { reference: "Bank transfer record", reason: "Bank confirms the transfer left",
        confirmed_at: Time.current.utc.iso8601(6), sent_before_hold_confirmed: true, approved_tax_payee_confirmed: true,
        conflict_audit_id: conflict.id }
      # Never ordinary paid once the provider accepted it after the fence,
      # even confirmed (A2 recheck finding 2, e49e94d2).
      expect do
        PayoutReconciler.call(payout: payout, actor: admin, status: "paid", provider_payout_id: "bank-accepted-1",
          evidence: evidence)
      end.to raise_error(PayoutReconciler::ReconciliationError, PayoutReconciler::ACCEPTED_NOT_PAID_MESSAGE)
      expect do
        PayoutReconciler.call(payout: payout, actor: admin, status: "accepted_transfer", evidence: evidence.except(:conflict_audit_id))
      end.to raise_error(PayoutReconciler::ReconciliationError, /acknowledge the latest provider conflict/)

      recorded = PayoutReconciler.call(payout: payout, actor: admin, status: "accepted_transfer", evidence: evidence)
      expect(recorded.reload).to have_attributes(status: "processing", provider_payout_id: "bank-accepted-1",
        failure_code: "provider_result_conflict", failure_message: PayoutReconciler::ACCEPTED_TRANSFER_MESSAGE, paid_at: nil)
      audit = AuditLog.where(auditable: payout, action: "payout.accepted_transfer_recorded").sole
      expect(audit.metadata).to include("conflict_audit_id" => conflict.id)
      expect(audit.metadata["never_fulfilled_hold_started_at"]).to be_present
      # Same evidence again is a no-op; different evidence is refused.
      expect(PayoutReconciler.call(payout: payout, actor: admin, status: "accepted_transfer", evidence: evidence)).to eq(payout)
      expect do
        PayoutReconciler.call(payout: payout, actor: admin, status: "accepted_transfer",
          evidence: evidence.merge(reason: "A different bank confirmation"))
      end.to raise_error(PayoutReconciler::ReconciliationError, /different evidence/)
      expect(PayoutHoldRelease).not_to receive(:call)
    end

    it "is only for a payout whose paid write the fence refused" do
      record_card_sale!(event, ticket_type: ticket_type)
      settlement = Settlements::Finalizer.call(event: event, actor: admin)
      allow(PayoutGateway).to receive(:submit) { |payout| PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing) }
      payout = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "fence-ordinary", amount_cents: 500)
      expect do
        PayoutReconciler.call(payout: payout, actor: admin, status: "accepted_transfer",
          evidence: { reference: "Bank", reason: "Not refused", confirmed_at: Time.current.utc.iso8601(6) })
      end.to raise_error(PayoutReconciler::ReconciliationError, /Only a transfer the provider accepted/)
    end
  end

  describe "payouts inserted paid" do
    def immediate!
      ActiveRecord::Base.connection.execute("SET CONSTRAINTS payouts_require_custody_on_insert IMMEDIATE")
    end

    it "refuses a paid insert without its custody row when the transaction commits" do
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          create(:payout, amount_cents: 1000, status: :paid, paid_at: Time.current)
          immediate!
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /Payout custody fence: payout \d+ was inserted paid/)
    end

    it "accepts a paid insert with the authorized historical derivation, and a pending insert" do
      payout = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        payout = create(:payout, amount_cents: 1000, status: :paid, paid_at: Time.current)
        ActiveRecord::Base.connection.execute("SET LOCAL hafapass.custody_derivation = '#{payout.id}'")
        PayoutCustodyDetermination.create!(payout: payout, settlement_id: payout.settlement_id, determination: "non_custodial",
          basis: "derived_history", conservative_inclusion: false, evidence: { "rule" => "spec" })
        immediate!
      end
      ActiveRecord::Base.transaction(requires_new: true) do
        create(:payout, amount_cents: 1000, status: :pending)
        immediate!
      end
      expect(PayoutCustodyDetermination.where(payout: payout).count).to eq(1)
    end

    # CodeRabbit 4704013220: reversed is paid history, so a payout inserted
    # paid and reversed before commit (or inserted reversed) still needs its
    # custody row when the transaction commits.
    it "refuses a paid insert reversed before commit, and a reversed insert, without the custody row" do
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          payout = create(:payout, amount_cents: 1000, status: :paid, paid_at: Time.current)
          Payout.where(id: payout.id).update_all(status: Payout.statuses[:reversed])
          immediate!
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /Payout custody fence: payout \d+ was inserted paid/)
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          create(:payout, amount_cents: 1000, status: :reversed, paid_at: Time.current)
          immediate!
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /Payout custody fence: payout \d+ was inserted paid/)
    end

    it "accepts a paid insert reversed before commit with the authorized derivation in the same transaction" do
      payout = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        payout = create(:payout, amount_cents: 1000, status: :paid, paid_at: Time.current)
        ActiveRecord::Base.connection.execute("SET LOCAL hafapass.custody_derivation = '#{payout.id}'")
        PayoutCustodyDetermination.create!(payout: payout, settlement_id: payout.settlement_id, determination: "non_custodial",
          basis: "derived_history", conservative_inclusion: false, evidence: { "rule" => "spec" })
        Payout.where(id: payout.id).update_all(status: Payout.statuses[:reversed])
        immediate!
      end
      expect(payout.reload).to be_status_reversed
      expect(PayoutCustodyDetermination.where(payout: payout).count).to eq(1)
    end

    it "leaves a payout inserted paid before the A2 payout entry migration as it was" do
      payout = nil
      connection = ActiveRecord::Base.connection
      ActiveRecord::Base.transaction(requires_new: true) do
        connection.execute("ALTER TABLE payouts DISABLE TRIGGER payouts_require_custody_on_insert")
        payout = create(:payout, amount_cents: 1000, status: :paid, paid_at: Time.current)
        connection.execute("ALTER TABLE payouts ENABLE TRIGGER payouts_require_custody_on_insert")
        immediate!
      end
      # Pre-cutover history: reversing it later needs no row in that
      # transaction (the insert check never queued for it).
      ActiveRecord::Base.transaction(requires_new: true) do
        Payout.where(id: payout.id).update_all(status: Payout.statuses[:reversed])
        immediate!
      end
      expect(payout.reload).to be_status_reversed
      expect(PayoutCustodyDetermination.where(payout: payout)).to be_empty
    end
  end
end
