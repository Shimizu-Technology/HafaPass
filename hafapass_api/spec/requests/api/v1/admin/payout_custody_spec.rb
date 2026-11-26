# frozen_string_literal: true

require "rails_helper"
require "csv"

# R2-2: frozen per-payout Stripe custody for the BPT detail CSV
# (docs/design/never-fulfilled-captures.md §8.6, §8.10.5, F-19…F-24, E14).
# Saved CSV bodies are compared byte for byte across later activity.
RSpec.describe "Frozen payout custody (R2-2)", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:admin) { create(:user, :admin) }
  let(:guam) { ActiveSupport::TimeZone["Pacific/Guam"] }
  let(:org) { create(:organization) }
  let(:profile) { create(:organizer_profile, organization: org) }
  let(:event) { create(:event, :published, organization: org, organizer_profile: profile) }
  let(:account) { create(:connected_account, organization: org, provider: "manual", with_readiness_approval: false) }

  def at(*parts) = guam.local(*parts)

  # A payout recorded paid before the A2 payout entry migration (history):
  # no determination, which the database now refuses for a new recording.
  def paid_before_payout_entry!(payout, **columns)
    connection = ActiveRecord::Base.connection
    connection.execute("ALTER TABLE payouts DISABLE TRIGGER payouts_require_custody")
    payout.update_columns(status: Payout.statuses[:paid], **columns)
  ensure
    connection.execute("ALTER TABLE payouts ENABLE TRIGGER payouts_require_custody")
  end

  def bpt_body(month)
    get "/api/v1/admin/tax_reports/bpt_events_export", params: { year: 2027, month: month }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    response.body.dup
  end

  def payouts_cell(body, target = event)
    CSV.parse(body, headers: true).find { |row| row["event_id"] == target.id.to_s }&.fetch("organizer_payouts")
  end

  # A fulfilled sale. provider "stripe" is a live agent capture recorded at
  # `captured_at`; "boh_clover" is an organizer-direct sale.
  def sale!(at:, provider: "stripe", captured_at: at)
    order = create(:order, :pending, event: event, created_at: at - 1.hour, currency: "usd",
      subtotal_cents: 1200, service_fee_cents: 0, total_cents: 1200)
    item = create(:order_item, order: order, unit_price_cents: 1200, quantity: 1, subtotal_cents: 1200,
      organizer_proceeds_cents: 1200, fee_cents: 0)
    payment = create(:payment, order: order, provider: provider, provider_environment: provider == "stripe" ? "live" : nil,
      provider_payment_id: "#{provider == 'stripe' ? 'pi_live' : 'clover'}_#{SecureRandom.hex(4)}", amount_cents: 1200,
      currency: "usd", status: :succeeded, created_at: at, succeeded_at: at)
    order.update!(status: :completed, completed_at: at, fulfilled_by_payment_id: payment.id)
    stamp!(payment, :capture_recorded_at, captured_at, trigger: "payments_capture_recorded_at")
    [order, item, payment.reload]
  end

  # A finalized settlement version funding `items`, and a payout on it.
  def payout_on!(items, finalized_at:, amount: 1000, provider: "manual", connected_account: account)
    settlement = create(:settlement, event: event, organization: org, calculated_at: finalized_at, finalized_at: finalized_at)
    # The database stamps its own finalization time; travel_to fixtures stand in.
    stamp!(settlement, :finalized_recorded_at, finalized_at, trigger: "settlements_finalization_stamp")
    items.each do |item|
      settlement.settlement_items.create!(kind: "sale_proceeds", source_type: "OrderItem", source_id: item.id,
        amount_cents: item.organizer_proceeds_cents, currency: "usd", description: "Sale", occurred_at: finalized_at)
    end
    create(:payout, event: event, organization: org, settlement: settlement, connected_account: connected_account,
      provider: provider, amount_cents: amount, status: :processing)
  end

  # Records the payout paid the way PayoutReconciler and PayoutCreator do
  # (an update to paid inside the transaction), with transfer time `paid_at`,
  # recorded at `recorded_at` (the database clock bounds the conservative
  # rule; travel_to fixtures stand in for it).
  def record_paid!(payout, paid_at:, recorded_at: paid_at)
    allow(PayoutCustody).to receive(:database_now) { recorded_at.utc }
    payout.update!(status: :paid, paid_at: paid_at, provider_payout_id: "bank_#{payout.id}")
    payout.custody_determination
  end

  describe "a January payout on a Clover-only settlement, then a February Stripe capture (E14)" do
    it "keeps January's payout out of the BPT detail, byte-identical, with or without a frozen determination" do
      _clover_order, clover_item, = sale!(at: at(2027, 1, 5, 10), provider: "boh_clover")
      determined = payout_on!([clover_item], finalized_at: at(2027, 1, 10, 10))
      expect(record_paid!(determined, paid_at: at(2027, 1, 20, 10))).to have_attributes(determination: "non_custodial",
        basis: "recorded_at_paid", funded_order_item_ids: [clover_item.id], qualifying_payment_ids: [])
      # Paid by an older release (no determination): the conservative rule.
      undetermined = create(:payout, event: event, organization: org, settlement: determined.settlement,
        connected_account: account, amount_cents: 300, status: :paid, paid_at: at(2027, 1, 21, 10))
      expect(undetermined.custody_determination).to be_nil
      january = bpt_body(1)
      expect(payouts_cell(january)).to be_nil

      sale!(at: at(2027, 2, 3, 10))
      expect(bpt_body(1)).to eq(january)
      expect(payouts_cell(bpt_body(2))).to eq("0.00")
      expect(TaxReports.new(2027).payout_custody_alerts).to eq([{ code: "payout_custody_undetermined",
        payout_id: undetermined.id, event_id: event.id }])
    end

    it "ignores an unrelated Stripe sale recorded after finalization but before the payout was paid" do
      _clover_order, clover_item, = sale!(at: at(2027, 1, 5, 10), provider: "boh_clover")
      payout = payout_on!([clover_item], finalized_at: at(2027, 1, 10, 10))
      sale!(at: at(2027, 1, 15, 10))
      determination = record_paid!(payout, paid_at: at(2027, 1, 20, 10))

      expect(determination).to have_attributes(determination: "non_custodial", conservative_inclusion: true)
      expect(determination.evidence["lines"].sole).to include("custody" => "none", "reason" => "no_stripe_agent_capture")
      expect(payouts_cell(bpt_body(1))).to eq("0.00")
    end
  end

  describe "a Stripe-funded payout" do
    it "stays in January when a pre-payout capture is classified in March" do
      order, item, payment = sale!(at: at(2027, 1, 5, 10))
      payout = payout_on!([item], finalized_at: at(2027, 1, 10, 10))
      determination = record_paid!(payout, paid_at: at(2027, 1, 20, 10))
      expect(determination).to have_attributes(determination: "stripe_custody", qualifying_payment_ids: [payment.id])
      january = bpt_body(1)
      expect(payouts_cell(january)).to eq("10.00")
      # Snapshot before the classification (CodeRabbit 4703321709).
      frozen = determination.reload.attributes

      second = create(:payment, order: order, provider: "stripe", provider_environment: "live",
        provider_payment_id: "pi_live_second_#{SecureRandom.hex(4)}", amount_cents: 1200, currency: "usd",
        status: :succeeded, created_at: at(2027, 1, 6, 10), succeeded_at: at(2027, 1, 6, 10))
      stamp!(second, :capture_recorded_at, at(2027, 1, 6, 10), trigger: "payments_capture_recorded_at")
      UnfulfilledCapture.create!(order: order, payment: second, capture_scope: "payment", code: "unfulfilled_second_capture",
        captured_cents: 1200, currency: "usd", proceeds_cents: 1200, fee_cents: 0, organizer_fee_cents: 0, tax_cents: 0,
        processing_bearer: "platform", dispute_fee_bearer: "platform", allocation_policy: "item_record",
        policy_version: Commerce::NeverFulfilledClassification::POLICY_VERSION, provenance: "lifecycle")

      expect(bpt_body(1)).to eq(january)
      expect(PayoutCustodyDetermination.find_by!(payout_id: payout.id).attributes).to eq(frozen)
    end

    it "decides by the funded version's finalization, never by a backdated paid_at or the paid audit" do
      _order, item, = sale!(at: at(2027, 1, 22, 10))
      payout = payout_on!([item], finalized_at: at(2027, 1, 25, 10))
      determination = record_paid!(payout, paid_at: at(2027, 1, 21, 10))

      # A paid_at before the capture: the conservative rule alone would leave
      # it out.
      expect(determination).to have_attributes(determination: "stripe_custody", conservative_inclusion: false)

      # Recorded later with the same backdated transfer time: the frozen
      # conservative bound is the recording's database time, not paid_at.
      later = payout_on!([item], finalized_at: at(2027, 1, 25, 10), amount: 100)
      backdated = record_paid!(later, paid_at: at(2027, 1, 21, 10), recorded_at: at(2027, 1, 26, 10))
      expect(backdated).to have_attributes(determination: "stripe_custody", conservative_inclusion: true)
      expect(backdated.evidence["conservative_bound_at"]).to eq(at(2027, 1, 26, 10).utc.iso8601(6))
      expect(payouts_cell(bpt_body(1))).to eq("11.00")
    end

    it "keeps the frozen row through a reversal and counts a check adjustment only on a custody payout" do
      _order, item, = sale!(at: at(2027, 1, 5, 10))
      check_account = create(:connected_account, organization: org, provider: "check", with_readiness_approval: false,
        payout_details: { payee_name: "Fictional Payee", delivery_method: "pickup" })
      check = payout_on!([item], finalized_at: at(2027, 1, 10, 10), provider: "check", connected_account: check_account)
      record_paid!(check, paid_at: at(2027, 1, 20, 10))
      check.payout_check_adjustments.create!(amount_cents: -25, reason: "Matched cleared check", created_by_user: admin)
      bank = payout_on!([item], finalized_at: at(2027, 1, 10, 10), amount: 400)
      frozen = record_paid!(bank, paid_at: at(2027, 1, 20, 10)).attributes
      expect(payouts_cell(bpt_body(1))).to eq("13.75")

      bank.update!(status: :reversed)
      expect(bank.custody_determination.reload.attributes).to eq(frozen)
      expect(payouts_cell(bpt_body(1))).to eq("9.75")
    end
  end

  describe "history" do
    it "keeps an unproven pre-A1 capture undetermined until finance supplies the published row, then never rewrites" do
      _order, item, payment = sale!(at: at(2027, 1, 5, 10))
      stamp!(payment, :capture_recorded_at, nil, trigger: "payments_capture_recorded_at")
      payout = payout_on!([item], finalized_at: at(2027, 1, 10, 10))
      paid_before_payout_entry!(payout, paid_at: at(2027, 1, 20, 10))
      FinancialCutover.create!(key: "a1_capture_recording", recorded_at: at(2027, 1, 25, 10))

      # No baseline: reported, nothing frozen, the payout stays alerted on
      # the conservative read (its capture succeeded before the payout).
      expect(PayoutCustody.derive_history!(dry_run: false, authorized_by: "FIN-1")).to eq([
        { payout_id: payout.id, determination: "ambiguous", conservative_inclusion: nil, skipped: "needs_published_baseline" }
      ])
      expect(PayoutCustodyDetermination.count).to eq(0)
      january = bpt_body(1)
      expect(payouts_cell(january)).to eq("10.00")
      expect(TaxReports.new(2027).payout_custody_alerts).to eq([{ code: "payout_custody_undetermined",
        payout_id: payout.id, event_id: event.id }])

      published = PayoutCustody.published_baseline("payout_id,included,source\n#{payout.id},true,BPT 2027-01 as filed\n")
      PayoutCustody.derive_history!(dry_run: false, authorized_by: "FIN-1", published: published)
      row = PayoutCustodyDetermination.find_by!(payout_id: payout.id)
      expect(row).to have_attributes(determination: "ambiguous", basis: "derived_history", conservative_inclusion: true)
      expect(row.evidence["lines"].sole).to include("custody" => "unknown", "reason" => "pre_a1_capture_time_unproven")
      expect(row.evidence["published_baseline"]).to eq("included" => true, "source" => "BPT 2027-01 as filed")
      expect(bpt_body(1)).to eq(january)
      expect(TaxReports.new(2027).payout_custody_alerts).to eq([{ code: "payout_custody_ambiguous", payout_id: payout.id,
        event_id: event.id, conservative_inclusion: true }])
      expect(PayoutCustody.derive_history!(dry_run: false, authorized_by: "FIN-1", published: published)).to eq([])
      expect { row.update!(determination: "stripe_custody") }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { PayoutCustodyDetermination.where(id: row.id).update_all(determination: "stripe_custody") }
        .to raise_error(ActiveRecord::StatementInvalid)
    end

    # CodeRabbit 4703321661: the immutable row keeps a finance reference,
    # never a person's name.
    it "refuses a write authorized by anything but a structured finance reference" do
      _order, item, = sale!(at: at(2027, 1, 5, 10))
      payout = payout_on!([item], finalized_at: at(2027, 1, 10, 10))
      paid_before_payout_entry!(payout, paid_at: at(2027, 1, 20, 10))
      ["Pat Example", "finance ticket FIN-1", "fin-1", "FIN-"].each do |authority|
        expect { PayoutCustody.derive_history!(dry_run: false, authorized_by: authority) }
          .to raise_error(ArgumentError, /finance ticket reference/)
      end
      expect(PayoutCustodyDetermination.count).to eq(0)
      PayoutCustody.derive_history!(dry_run: false, authorized_by: "FIN-2026-11-001")
      expect(payout.reload.custody_determination.evidence["authorized_by"]).to eq("FIN-2026-11-001")
    end

    # CodeRabbit 4703321638: the write reports the row it saved, not its
    # earlier preview, when another derivation froze the row first.
    it "reports the saved determination when another derivation froze it between the preview and the write" do
      _order, item, = sale!(at: at(2027, 1, 5, 10))
      payout = payout_on!([item], finalized_at: at(2027, 1, 10, 10))
      paid_before_payout_entry!(payout, paid_at: at(2027, 1, 20, 10))
      calls = 0
      allow(PayoutCustody).to receive(:determine).and_wrap_original do |original, *args, **options|
        result = original.call(*args, **options)
        calls += 1
        if calls == 1
          FinancialIntegrity.with_evidence(:custody_derivation, payout.id) do
            PayoutCustodyDetermination.insert_all([{ payout_id: payout.id, settlement_id: payout.settlement_id,
              determination: "ambiguous", basis: "derived_history", conservative_inclusion: true,
              evidence: { authorized_by: "FIN-7", published_baseline: { included: true, source: "BPT 2027-01" } } }],
              unique_by: :payout_id, record_timestamps: false)
          end
        end
        result
      end

      rows = PayoutCustody.derive_history!(dry_run: false, authorized_by: "FIN-8")
      expect(rows).to eq([{ payout_id: payout.id, determination: "ambiguous", conservative_inclusion: true }])
      expect(payout.reload.custody_determination).to have_attributes(determination: "ambiguous", conservative_inclusion: true)
    end

    it "refuses an incomplete or duplicated baseline" do
      expect { PayoutCustody.published_baseline("payout_id,included,source\n12,yes,BPT\n") }.to raise_error(ArgumentError)
      expect { PayoutCustody.published_baseline("payout_id,included,source\n12,true,\n") }.to raise_error(ArgumentError)
      expect { PayoutCustody.published_baseline("payout_id,included,source\n12,true,A\n12,false,B\n") }
        .to raise_error(ArgumentError, /twice/)
    end

    # Review finding 3 (17324039): a payment opened before a Clover payout
    # and captured after it, before A1 stamped capture times.
    it "never treats a pre-A1 payment's creation as its capture" do
      _clover_order, clover_item, = sale!(at: at(2027, 1, 5, 10), provider: "boh_clover")
      payout = payout_on!([clover_item], finalized_at: at(2027, 1, 10, 10))
      paid_before_payout_entry!(payout, paid_at: at(2027, 1, 20, 10))
      _late_order, _late_item, late = sale!(at: at(2027, 1, 18, 10))
      Payment.where(id: late.id).update_all(succeeded_at: at(2027, 1, 22, 10))
      stamp!(late, :capture_recorded_at, nil, trigger: "payments_capture_recorded_at")
      FinancialCutover.create!(key: "a1_capture_recording", recorded_at: at(2027, 1, 25, 10))
      expect(late.reload.created_at).to be < payout.paid_at

      # The late sale's own row shows; the Clover payout is not in it.
      january = bpt_body(1)
      expect(payouts_cell(january)).to eq("0.00")
      PayoutCustody.derive_history!(dry_run: false, authorized_by: "FIN-3")
      expect(payout.reload.custody_determination).to have_attributes(determination: "non_custodial", qualifying_payment_ids: [])
      expect(bpt_body(1)).to eq(january)
    end

    it "never freezes a payout with no funded sale line as non-custodial" do
      _order, _item, = sale!(at: at(2027, 1, 5, 10))
      # An adjustment-only historical version: no sale line funded the payout.
      payout = payout_on!([], finalized_at: at(2027, 1, 10, 10), amount: 500)
      paid_before_payout_entry!(payout, paid_at: at(2027, 1, 20, 10))
      january = bpt_body(1)
      expect(payouts_cell(january)).to eq("5.00")

      expect(PayoutCustody.derive_history!(dry_run: false, authorized_by: "FIN-4"))
        .to eq([{ payout_id: payout.id, determination: "ambiguous", conservative_inclusion: nil, skipped: "needs_published_baseline" }])
      expect(bpt_body(1)).to eq(january)
      PayoutCustody.derive_history!(dry_run: false, authorized_by: "FIN-4",
        published: { payout.id => { included: true, source: "BPT 2027-01 as filed" } })
      expect(payout.reload.custody_determination).to have_attributes(determination: "ambiguous", conservative_inclusion: true,
        funded_order_item_ids: [])
      expect(payout.custody_determination.evidence).to include("unfunded_cents" => 500, "funding_source" => "reconstructed_from_version")
      expect(bpt_body(1)).to eq(january)
    end

    it "uses the payout's saved allocations over a reconstruction" do
      _clover_order, clover_item, = sale!(at: at(2027, 1, 5, 10), provider: "boh_clover")
      _stripe_order, stripe_item, = sale!(at: at(2027, 1, 6, 10))
      payout = payout_on!([clover_item, stripe_item], finalized_at: at(2027, 1, 10, 10), amount: 1000)
      expect(PayoutLineAllocator.amounts_for(payout).keys).to contain_exactly(clover_item.id, stripe_item.id)
      payout.payout_line_allocations.create!(order_item_id: clover_item.id, amount_cents: 1000)
      paid_before_payout_entry!(payout, paid_at: at(2027, 1, 20, 10))

      PayoutCustody.derive_history!(dry_run: false, authorized_by: "FIN-5")
      expect(payout.reload.custody_determination).to have_attributes(determination: "non_custodial",
        funded_order_item_ids: [clover_item.id], qualifying_payment_ids: [])
      expect(payout.custody_determination.evidence).to include("funding_source" => "saved_allocations")
    end

    # A2 recheck (e49e94d2): a qualifying Stripe line does not make the
    # payout Stripe custody when cents it paid are covered by no funded line.
    it "keeps a partly Stripe-funded payout with uncovered cents ambiguous, never definitive" do
      _stripe_order, stripe_item, = sale!(at: at(2027, 1, 6, 10))
      payout = payout_on!([stripe_item], finalized_at: at(2027, 1, 10, 10), amount: 1500)
      payout.payout_line_allocations.create!(order_item_id: stripe_item.id, amount_cents: 1200)
      paid_before_payout_entry!(payout, paid_at: at(2027, 1, 20, 10))

      expect(PayoutCustody.determine(payout)).to include(determination: "ambiguous")
      expect(PayoutCustody.derive_history!(dry_run: false, authorized_by: "FIN-6"))
        .to eq([{ payout_id: payout.id, determination: "ambiguous", conservative_inclusion: nil, skipped: "needs_published_baseline" }])
      expect(payout.reload.custody_determination).to be_nil
      PayoutCustody.derive_history!(dry_run: false, authorized_by: "FIN-6",
        published: { payout.id => { included: true, source: "BPT 2027-01 as filed" } })
      expect(payout.reload.custody_determination).to have_attributes(determination: "ambiguous", conservative_inclusion: true,
        funded_order_item_ids: [stripe_item.id])
      expect(payout.custody_determination.evidence).to include("unfunded_cents" => 300, "funding_source" => "saved_allocations")
      expect(payout.custody_determination.evidence["lines"].map { |line| line["custody"] }).to eq(["stripe"])

      # Recorded paid now: the conservative rule is frozen and alerted, never stripe_custody.
      later = payout_on!([stripe_item], finalized_at: at(2027, 1, 11, 10), amount: 1500)
      later.payout_line_allocations.create!(order_item_id: stripe_item.id, amount_cents: 1200)
      expect(record_paid!(later, paid_at: at(2027, 1, 21, 10))).to have_attributes(determination: "ambiguous", basis: "recorded_at_paid")
    end

    it "qualifies only the fulfilling payment: a Stripe second capture classified before derive never funds a Clover sale" do
      clover_order, clover_item, = sale!(at: at(2027, 1, 5, 10), provider: "boh_clover")
      # History: finalized and paid before the open overlap would hold it.
      payout = payout_on!([clover_item], finalized_at: at(2027, 1, 10, 10))
      paid_before_payout_entry!(payout, paid_at: at(2027, 1, 20, 10))
      second = create(:payment, order: clover_order, provider: "stripe", provider_environment: "live",
        provider_payment_id: "pi_live_second_#{SecureRandom.hex(4)}", amount_cents: 1200, currency: "usd",
        status: :succeeded, created_at: at(2027, 1, 6, 10), succeeded_at: at(2027, 1, 6, 10))
      stamp!(second, :capture_recorded_at, at(2027, 1, 6, 10), trigger: "payments_capture_recorded_at")
      expect(PayoutCustody.determine(payout)[:evidence][:lines].sole).to include(custody: "none",
        reason: "fulfilled_by_another_payment")

      # The relevant payment is classified before the derive runs.
      UnfulfilledCapture.create!(order: clover_order, payment: second, capture_scope: "payment",
        code: "unfulfilled_second_capture", captured_cents: 1200, currency: "usd", proceeds_cents: 1200, fee_cents: 0,
        organizer_fee_cents: 0, tax_cents: 0, processing_bearer: "platform", dispute_fee_bearer: "platform",
        allocation_policy: "item_record", policy_version: Commerce::NeverFulfilledClassification::POLICY_VERSION,
        provenance: "lifecycle")
      PayoutCustody.derive_history!(dry_run: false, authorized_by: "FIN-6")
      expect(payout.reload.custody_determination).to have_attributes(determination: "non_custodial", qualifying_payment_ids: [])
      expect(payouts_cell(bpt_body(1))).to be_nil
    end

    it "accepts the order's completion audit as positive pre-A1 timing" do
      order, item, payment = sale!(at: at(2027, 1, 5, 10))
      stamp!(payment, :capture_recorded_at, nil, trigger: "payments_capture_recorded_at")
      travel_to(at(2027, 1, 5, 10)) do
        AuditLogger.record!(action: "order.completed", auditable: order, organization: org, metadata: { payment_id: payment.id })
      end
      payout = payout_on!([item], finalized_at: at(2027, 1, 10, 10))
      paid_before_payout_entry!(payout, paid_at: at(2027, 1, 20, 10))

      PayoutCustody.derive_history!(dry_run: false, authorized_by: "FIN-1")
      expect(payout.reload.custody_determination).to have_attributes(determination: "stripe_custody",
        qualifying_payment_ids: [payment.id])
      expect(payout.custody_determination.evidence["lines"].sole).to include("reason" => "completion_audit")
    end

    it "bounds the conservative rule by the redaction-safe paid audit, else paid_at" do
      _order, item, = sale!(at: at(2027, 1, 15, 10))
      settlement = create(:settlement, event: event, organization: org, finalized_at: at(2027, 1, 16, 10))
      with_audit = create(:payout, event: event, organization: org, settlement: settlement, connected_account: account,
        amount_cents: 500, status: :paid, paid_at: at(2027, 1, 10, 10))
      # The paid audit after redaction: after_data cleared, time kept.
      travel_to(at(2027, 1, 20, 10)) do
        AuditLogger.record!(action: "payout.reconciled", auditable: with_audit, organization: org, after_data: {})
      end
      create(:payout, event: event, organization: org, settlement: settlement, connected_account: account,
        amount_cents: 300, status: :paid, paid_at: at(2027, 1, 10, 10))
      expect(item).to be_present

      expect(payouts_cell(bpt_body(1))).to eq("5.00")
    end

    it "refuses an application-written determination time" do
      payout = create(:payout, event: event, organization: org, connected_account: account, status: :paid,
        paid_at: at(2027, 1, 20, 10))
      expect do
        FinancialIntegrity.with_evidence(:custody_derivation, payout.id) do
          PayoutCustodyDetermination.create!(payout: payout, settlement_id: payout.settlement_id, determination: "non_custodial",
            basis: "derived_history", conservative_inclusion: false, determined_at: Time.current)
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /stamped by the database/)
    end
  end
end
