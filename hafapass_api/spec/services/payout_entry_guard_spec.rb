# frozen_string_literal: true

require "rails_helper"

# A2 payout entry and overlap fences (docs/design/never-fulfilled-captures.md
# §8.10.11, F-16, F-17, F-25, M-09). A payout is approved against one exact
# settlement version. On an event with a classified capture, release,
# submission and paid recording check that version against this release's
# statement (without payout lines), and the database refuses an older
# reader, a version that predates a classified capture, and paid without the
# payout's own frozen custody determination. Money already sent is still
# recorded with explicit, audited evidence; nothing is paid twice, and no
# earlier version or paid transfer changes.
RSpec.describe "A2 payout entry" do
  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 2000) }
  let(:gateway) { [] }

  before do
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
    allow(Sentry).to receive(:capture_message)
    allow(Sentry).to receive(:capture_exception)
    allow(PayoutGateway).to receive(:submit) do |payout|
      gateway << payout.id
      PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing)
    end
    approved_bank_account!(organization, actor: profile.user, admin: admin)
  end

  def isolated
    ActiveRecord::Base.connection.transaction(requires_new: true) do
      yield
      raise ActiveRecord::Rollback
    end
  end

  def finalize! = Settlements::Finalizer.call(event: event, actor: admin)

  # Reserved and submitted (manual: processing, the transfer is the admin's).
  def submitted!(key, amount_cents: 2000)
    PayoutCreator.call(settlement: finalize!, actor: admin, idempotency_key: key, amount_cents: amount_cents)
  end

  # Reserved only (no submission authorization).
  def reserved!(key, amount_cents: 2000)
    PayoutCreator.new(settlement: finalize!, actor: admin, idempotency_key: key, amount_cents: amount_cents).send(:reserve!).first
  end

  def held!(key, amount_cents: 2000)
    reserved!(key, amount_cents: amount_cents).tap do |payout|
      payout.update!(status: :held, held_from_status: "pending")
    end
  end

  def submit!(payout)
    PayoutCreator.new(settlement: payout.settlement, actor: admin, idempotency_key: payout.idempotency_key)
      .send(:submit_payout!, payout)
  end

  def record_paid!(payout, confirmed_at, **flags)
    PayoutReconciler.call(payout: payout.reload, actor: admin, status: "paid", provider_payout_id: "bank-#{payout.id}-#{flags.size}",
      evidence: { reference: "Bank transfer record", reason: "Transfer confirmed by the bank",
        confirmed_at: confirmed_at.iso8601(6), approved_tax_payee_confirmed: true }.merge(flags))
  end

  # The $13.60 order-scope capture (K = 1200, 160, 0, 0) with its verified
  # processing, no open exception (already repaid or never held).
  def classified_capture_on_event!
    classified_capture(items: [[1200, 160, 0, 0]], event: event).tap do |order, payment, _capture|
      component = create(:fee_component, order: order, order_item: order.order_items.first, kind: "processing",
        amount_cents: 69, estimated: false, provider_reference: "txn_entry_#{SecureRandom.hex(4)}")
      create(:stripe_fee_evidence, :verified, payment: payment, fee_component: component,
        provider_balance_transaction_id: component.provider_reference)
    end
  end

  def version_snapshot(*settlements)
    settlements.map { |settlement| [settlement.reload.attributes, settlement.settlement_items.order(:id).map(&:attributes)] }
  end

  it "stamps each finalized version with its reader, database time and payout-free digest, set once" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    settlement = finalize!
    expect(settlement.reload).to have_attributes(finalized_reader: "nfc-a2", reader_digest: be_present,
      finalized_recorded_at: be_within(5.seconds).of(Time.current))
    expect { isolated { Settlement.where(id: settlement.id).update_all(reader_digest: "x") } }
      .to raise_error(ActiveRecord::StatementInvalid, /set once/)
    expect { isolated { Settlement.where(id: settlement.id).update_all(finalized_recorded_at: 1.day.ago) } }
      .to raise_error(ActiveRecord::StatementInvalid, /set once/)

    # A payout of its own (or any payout's status) never makes it stale.
    payout = submitted!("stamp-1")
    expect(PayoutEntryGuard.reader_digest(Settlements::Calculator.call(event).items)).to eq(settlement.reader_digest)
    expect(Settlements::Calculator.call(event).attributes[:source_digest]).not_to eq(settlement.source_digest)
    expect(payout).to be_status_processing
  end

  describe "an event with no classified capture (unchanged rules)" do
    it "releases, submits and records paid on a drifted version, and lets an older writer act except paid" do
      order, item, capture = record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      held = held!("plain-held")
      pending = reserved!("plain-pending", amount_cents: 1000)
      record_card_refund!(order, item, capture, proceeds_cents: 500)
      expect(PayoutEntryGuard.affected?(event)).to be(false)

      expect(PayoutHoldRelease.call(payout: held, actor: admin)).to be(true)
      expect(submit!(pending)).to be_a(PayoutGateway::Result)
      expect(record_paid!(held, Time.current)).to be_status_paid
      expect(held.custody_determination).to have_attributes(basis: "recorded_at_paid", settlement_id: held.settlement_id)

      # An A1 process names no reader on release, submission or paid; on this
      # event that is allowed, except paid, which needs the custody row only
      # this release writes.
      other = held!("plain-held-2", amount_cents: 500)
      isolated { other.update_columns(status: Payout.statuses[:pending], held_from_status: nil) }
      expect { isolated { pending.update_columns(status: Payout.statuses[:paid], paid_at: Time.current) } }
        .to raise_error(ActiveRecord::StatementInvalid, /Payout custody fence/)
      expect { isolated { FinancialIntegrity.with_evidence(:settlement_reader, "nfc-a1r1") { finalize! } } }.not_to raise_error
    end
  end

  describe "a version that predates a classified capture (F-16, F-25)" do
    it "refuses release, submission and reissue, records only a proven pre-restatement transfer, and pays nothing twice" do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      sent = submitted!("pre-sent")
      pending = reserved!("pre-pending")
      held = held!("pre-held")
      versions = [sent, pending, held].map(&:settlement)
      before = version_snapshot(*versions)
      gateway.clear
      sleep 0.02
      pre = Time.current
      sleep 0.02
      _order, payment, = classified_capture_on_event!
      captured_at = payment.reload.capture_recorded_at
      sleep 0.02
      after = Time.current

      expect(PayoutEntryGuard.affected?(event)).to be(true)
      versions.each { |version| expect(PayoutEntryGuard.restated_at(version)).to be_within(0.001).of(captured_at) }
      expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(false)

      # Held release: application refusal; the automatic one returns false.
      expect { PayoutHoldRelease.call(payout: held, actor: admin) }
        .to raise_error(PayoutHoldRelease::ReleaseError, PayoutEntryGuard::STALE_MESSAGE)
      expect(PayoutHoldRelease.call(payout: held, actor: admin, automatic: true)).to be(false)
      # Submission and the database's own refusal of the authorization.
      expect { submit!(pending) }.to raise_error(PayoutCreator::PayoutError, PayoutEntryGuard::STALE_MESSAGE)
      expect do
        isolated do
          FinancialIntegrity.with_settlement_reader do
            AuditLogger.record!(action: "payout.submission_requested", auditable: pending, organization: organization,
              event: event, outcome: "requested", deduplication_key: "payout:#{pending.id}:raw")
          end
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /predates a never-fulfilled capture/)
      expect do
        isolated { FinancialIntegrity.with_settlement_reader { held.update_columns(status: Payout.statuses[:pending]) } }
      end.to raise_error(ActiveRecord::StatementInvalid, /predates a never-fulfilled capture/)
      # Reissue on an old version.
      expect { PayoutCreator.call(settlement: held.settlement, actor: admin, idempotency_key: "pre-reissue", amount_cents: 100) }
        .to raise_error(PayoutCreator::PayoutError, /finalize a new settlement/)

      # Paid: never for a payout never submitted, never without the
      # confirmation, never for a transfer after the restatement.
      expect { record_paid!(pending, pre, sent_before_restatement_confirmed: true) }
        .to raise_error(PayoutReconciler::ReconciliationError, PayoutEntryGuard::STALE_PAID_MESSAGE)
      expect { record_paid!(sent, pre) }.to raise_error(PayoutReconciler::ReconciliationError, PayoutEntryGuard::STALE_PAID_MESSAGE)
      expect { record_paid!(sent, after, sent_before_restatement_confirmed: true) }
        .to raise_error(PayoutReconciler::ReconciliationError, PayoutEntryGuard::STALE_PAID_MESSAGE)
      expect do
        isolated do
          FinancialIntegrity.with_settlement_reader do
            FinancialIntegrity.with_payout_transfer(sent.id) do
              PayoutCustody.record!(sent, basis: "recorded_at_paid")
              Payout.where(id: sent.id).update_all(status: Payout.statuses[:paid], paid_at: after)
            end
          end
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /before its statement was restated/)

      # The transfer submitted and sent before the capture is recorded once.
      paid = record_paid!(sent, pre, sent_before_restatement_confirmed: true)
      expect(paid).to have_attributes(status: "paid", paid_at: be_within(0.001).of(pre))
      expect(paid.custody_determination).to have_attributes(basis: "recorded_at_paid", settlement_id: sent.settlement_id)
      audit = AuditLog.where(auditable: sent, action: "payout.reconciled").sole
      expect(audit.metadata["stale_settlement"]).to include("restated_at" => captured_at.utc.iso8601(6),
        "settlement_id" => sent.settlement_id, "settlement_version" => sent.settlement.version, "settlement_reader" => "nfc-a2")
      expect(gateway).to be_empty
      expect(version_snapshot(*versions)).to eq(before)

      # A new version accounts for the capture; nothing new is available while
      # the old reservations stand (no new funds on the baseline case).
      current = finalize!
      expect(current.settlement_items.where(kind: "adjustment").pluck(:metadata))
        .to include(include("adjustment_kind" => "never_fulfilled_capture", "payment_ids" => [payment.id]))
      expect(PayoutEntryGuard.restated_at(current)).to be_nil
      payable = current.payable_cents
      remainder = PayoutCreator.call(settlement: current, actor: admin, idempotency_key: "pre-new-early")
      expect(remainder.amount_cents).to eq(payable - 6000)
      expect(gateway).to eq([remainder.id])
      expect { PayoutCreator.call(settlement: finalize!, actor: admin, idempotency_key: "pre-new-more", amount_cents: 1) }
        .to raise_error(PayoutCreator::PayoutError)

      # Finance fails the never-sent reservations (history kept), and reissues.
      [pending, held].each do |payout|
        PayoutReconciler.call(payout: payout.reload, actor: admin, status: "failed",
          evidence: { reference: "Not sent", reason: "Reissued on the current statement", confirmed_at: Time.current.iso8601(6) })
      end
      reissued = PayoutCreator.call(settlement: finalize!, actor: admin, idempotency_key: "pre-new")
      expect(reissued).to have_attributes(status: "processing", amount_cents: 4000)
      expect(gateway).to eq([remainder.id, reissued.id])
      expect(record_paid!(reissued, Time.current)).to be_status_paid
      # Everything sent or reserved equals the current payable exactly once.
      expect(Payout.where(event: event, status: %i[pending processing held paid]).sum(:amount_cents)).to eq(payable)
    end

    it "never restates before the A2 cutover: a transfer sent under the A1 reader is recorded" do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      sent = submitted!("cut-sent")
      _order, payment, = classified_capture_on_event!
      sleep 0.02
      between = Time.current
      sleep 0.02
      cutover = FinancialCutover.create!(key: FinancialIntegrity::PAYOUT_ENTRY_CUTOVER, recorded_at: Time.current)
      expect(payment.reload.capture_recorded_at).to be < between
      expect(PayoutEntryGuard.restated_at(sent.settlement)).to be_within(0.001).of(cutover.recorded_at)

      expect(record_paid!(sent, between, sent_before_restatement_confirmed: true)).to be_status_paid
    end
  end

  describe "a version that accounts for the classified capture" do
    it "releases, submits and records paid on the current statement" do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      classified_capture_on_event!
      held = held!("match-held")
      expect(PayoutEntryGuard.restated_at(held.settlement)).to be_nil
      expect(PayoutEntryGuard.stale?(held)).to be(false)

      expect(PayoutHoldRelease.call(payout: held, actor: admin)).to be(true)
      expect(submit!(held.reload)).to be_a(PayoutGateway::Result)
      expect(AuditLog.where(auditable: held, action: "payout.submission_requested").sole.metadata)
        .to include("settlement_reader" => "nfc-a2", "settlement_version" => held.settlement.version)
      expect(record_paid!(held, Time.current)).to be_status_paid
      expect(gateway).to eq([held.id])
    end

    it "treats a later ordinary change as stale for new authority, and records a submitted transfer with confirmation" do
      order, item, capture = record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      classified_capture_on_event!
      sent = submitted!("drift-sent")
      held = held!("drift-held")
      record_card_refund!(order, item, capture, proceeds_cents: 500)
      expect(PayoutEntryGuard.staleness(sent)).to include(restated_at: nil)

      expect { PayoutHoldRelease.call(payout: held, actor: admin) }
        .to raise_error(PayoutHoldRelease::ReleaseError, PayoutEntryGuard::STALE_MESSAGE)
      expect { record_paid!(sent, Time.current) }
        .to raise_error(PayoutReconciler::ReconciliationError, PayoutEntryGuard::STALE_PAID_MESSAGE)
      expect(record_paid!(sent, Time.current, sent_before_restatement_confirmed: true)).to be_status_paid
    end
  end

  describe "older writers during the A2 overlap or after a rollback (M-09)" do
    it "refuses an A1 finalization, creation, release, submission and paid on an affected event" do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      classified_capture_on_event!
      held = held!("m09-held")
      pending = reserved!("m09-pending", amount_cents: 1000)
      a1 = ->(&block) { FinancialIntegrity.with_evidence(:settlement_reader, FinancialIntegrity::A1_SETTLEMENT_READER, &block) }

      expect { isolated { a1.call { create(:settlement, organization: organization, event: event, version: 99) } } }
        .to raise_error(ActiveRecord::StatementInvalid, /settlement reader/)
      expect do
        isolated do
          a1.call { create(:payout, organization: organization, event: event, settlement: held.settlement, connected_account: held.connected_account) }
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /Payout entry fence/)
      # A1's PayoutHoldRelease (automatic after cancellation refunds) and
      # its submission and outcome name no reader.
      expect { isolated { held.update_columns(status: Payout.statuses[:pending], held_from_status: nil) } }
        .to raise_error(ActiveRecord::StatementInvalid, /Payout entry fence/)
      expect do
        isolated do
          AuditLogger.record!(action: "payout.submission_requested", auditable: pending, organization: organization,
            event: event, outcome: "requested", deduplication_key: "payout:#{pending.id}:a1")
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /Payout entry fence/)
      expect { isolated { pending.update_columns(status: Payout.statuses[:processing]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /Payout entry fence/)
      expect do
        isolated do
          FinancialIntegrity.with_payout_transfer(pending.id) do
            pending.update_columns(status: Payout.statuses[:paid], paid_at: Time.current)
          end
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /fence/)
      expect([held.reload.status, pending.reload.status]).to eq(%w[held pending])
      expect(gateway).to be_empty
    end
  end

  describe "frozen custody on the paid path (R2-2)" do
    let!(:payout) do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      reserved!("custody-1")
    end

    it "writes the determination with the paid recording, for the payout's own version only" do
      other_version = create(:settlement, organization: organization, event: event, version: 99)
      expect { isolated { PayoutCustodyDetermination.create!(payout: payout, settlement_id: other_version.id,
        determination: "non_custodial", basis: "recorded_at_paid", conservative_inclusion: false) } }
        .to raise_error(ActiveRecord::StatementInvalid, /own settlement version/)
      expect { isolated { PayoutCustodyDetermination.create!(payout: payout, settlement_id: payout.settlement_id,
        determination: "non_custodial", basis: "derived_history", conservative_inclusion: false) } }
        .to raise_error(ActiveRecord::StatementInvalid, /authorized derivation/)

      # A determination that does not commit with its payout paid.
      expect do
        isolated do
          PayoutCustody.record!(payout, basis: "recorded_at_paid")
          ActiveRecord::Base.connection.execute("SET CONSTRAINTS payout_custody_determinations_commit IMMEDIATE")
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /commits only with its payout recorded paid/)

      submit!(payout)
      record_paid!(payout, Time.current)
      determination = payout.reload.custody_determination
      expect(determination).to have_attributes(basis: "recorded_at_paid", settlement_id: payout.settlement_id)
      expect(determination.evidence).to include("settlement_reader" => "nfc-a2", "settlement_finalized_bound" => "finalized_recorded_at",
        "conservative_bound_at" => be_present)
      ActiveRecord::Base.connection.execute("SET CONSTRAINTS payout_custody_determinations_commit IMMEDIATE")

      # Never again for a payout already paid.
      expect { isolated { PayoutCustodyDetermination.insert_all([{ payout_id: payout.id, settlement_id: payout.settlement_id,
        determination: "non_custodial", basis: "recorded_at_paid", conservative_inclusion: false }]) } }
        .to raise_error(ActiveRecord::StatementInvalid)
    end

    it "derives history only with authority and only for payouts paid before the cutover" do
      connection = ActiveRecord::Base.connection
      submit!(payout)
      connection.execute("ALTER TABLE payouts DISABLE TRIGGER payouts_require_custody")
      payout.update_columns(status: Payout.statuses[:paid], paid_at: 2.hours.ago)
      connection.execute("ALTER TABLE payouts ENABLE TRIGGER payouts_require_custody")

      expect { PayoutCustody.derive_history!(dry_run: false) }.to raise_error(ArgumentError, /AUTHORIZED_BY/)
      FinancialCutover.create!(key: FinancialIntegrity::PAYOUT_ENTRY_CUTOVER, recorded_at: 3.hours.ago)
      expect(PayoutCustody.derive_history!(dry_run: false, authorized_by: "FIN-2"))
        .to contain_exactly(include(payout_id: payout.id, skipped: "paid_after_payout_entry_cutover"))
      expect(payout.reload.custody_determination).to be_nil
    end
  end
end
