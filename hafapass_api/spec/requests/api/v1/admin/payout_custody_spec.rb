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
    items.each do |item|
      settlement.settlement_items.create!(kind: "sale_proceeds", source_type: "OrderItem", source_id: item.id,
        amount_cents: item.organizer_proceeds_cents, currency: "usd", description: "Sale", occurred_at: finalized_at)
    end
    create(:payout, event: event, organization: org, settlement: settlement, connected_account: connected_account,
      provider: provider, amount_cents: amount, status: :processing)
  end

  # Records the payout paid the way PayoutReconciler and PayoutCreator do
  # (an update to paid inside the transaction), at application time `paid_at`.
  def record_paid!(payout, paid_at:)
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

      second = create(:payment, order: order, provider: "stripe", provider_environment: "live",
        provider_payment_id: "pi_live_second_#{SecureRandom.hex(4)}", amount_cents: 1200, currency: "usd",
        status: :succeeded, created_at: at(2027, 1, 6, 10), succeeded_at: at(2027, 1, 6, 10))
      stamp!(second, :capture_recorded_at, at(2027, 1, 6, 10), trigger: "payments_capture_recorded_at")
      UnfulfilledCapture.create!(order: order, payment: second, capture_scope: "payment", code: "unfulfilled_second_capture",
        captured_cents: 1200, currency: "usd", proceeds_cents: 1200, fee_cents: 0, organizer_fee_cents: 0, tax_cents: 0,
        processing_bearer: "platform", dispute_fee_bearer: "platform", allocation_policy: "item_record",
        policy_version: Commerce::NeverFulfilledClassification::POLICY_VERSION, provenance: "lifecycle")

      expect(bpt_body(1)).to eq(january)
      expect(PayoutCustodyDetermination.find_by!(payout_id: payout.id).attributes).to eq(determination.reload.attributes)
    end

    it "decides by the funded version's finalization, never by a backdated paid_at or the paid audit" do
      _order, item, = sale!(at: at(2027, 1, 22, 10))
      payout = payout_on!([item], finalized_at: at(2027, 1, 25, 10))
      determination = record_paid!(payout, paid_at: at(2027, 1, 21, 10))

      # No paid audit and a paid_at before the capture: the conservative rule
      # alone would leave it out.
      expect(determination).to have_attributes(determination: "stripe_custody", conservative_inclusion: false)
      expect(payouts_cell(bpt_body(1))).to eq("10.00")
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
    it "derives once, keeps an unproven pre-A1 capture ambiguous on the conservative rule, and never rewrites" do
      _order, item, payment = sale!(at: at(2027, 1, 5, 10))
      stamp!(payment, :capture_recorded_at, nil, trigger: "payments_capture_recorded_at")
      payout = payout_on!([item], finalized_at: at(2027, 1, 10, 10))
      payout.update_columns(status: Payout.statuses[:paid], paid_at: at(2027, 1, 20, 10))
      FinancialCutover.create!(key: "a1_capture_recording", recorded_at: at(2027, 1, 25, 10))

      expect(PayoutCustody.derive_history!(dry_run: true)).to eq([{ payout_id: payout.id, determination: "ambiguous",
        conservative_inclusion: true }])
      expect(PayoutCustodyDetermination.count).to eq(0)
      january = bpt_body(1)
      expect(payouts_cell(january)).to eq("10.00")

      PayoutCustody.derive_history!(dry_run: false)
      row = PayoutCustodyDetermination.find_by!(payout_id: payout.id)
      expect(row).to have_attributes(determination: "ambiguous", basis: "derived_history", conservative_inclusion: true)
      expect(row.evidence["lines"].sole).to include("custody" => "unknown", "reason" => "pre_a1_capture_time_unproven")
      expect(bpt_body(1)).to eq(january)
      expect(TaxReports.new(2027).payout_custody_alerts).to eq([{ code: "payout_custody_ambiguous", payout_id: payout.id,
        event_id: event.id, conservative_inclusion: true }])
      expect(PayoutCustody.derive_history!(dry_run: false)).to eq([])
      expect { row.update!(determination: "stripe_custody") }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { PayoutCustodyDetermination.where(id: row.id).update_all(determination: "stripe_custody") }
        .to raise_error(ActiveRecord::StatementInvalid)
    end

    it "accepts the order's completion audit as positive pre-A1 timing" do
      order, item, payment = sale!(at: at(2027, 1, 5, 10))
      stamp!(payment, :capture_recorded_at, nil, trigger: "payments_capture_recorded_at")
      travel_to(at(2027, 1, 5, 10)) do
        AuditLogger.record!(action: "order.completed", auditable: order, organization: org, metadata: { payment_id: payment.id })
      end
      payout = payout_on!([item], finalized_at: at(2027, 1, 10, 10))
      payout.update_columns(status: Payout.statuses[:paid], paid_at: at(2027, 1, 20, 10))

      PayoutCustody.derive_history!(dry_run: false)
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
        PayoutCustodyDetermination.create!(payout: payout, settlement_id: payout.settlement_id, determination: "non_custodial",
          basis: "derived_history", conservative_inclusion: false, determined_at: Time.current)
      end.to raise_error(ActiveRecord::StatementInvalid, /stamped by the database/)
    end
  end
end
