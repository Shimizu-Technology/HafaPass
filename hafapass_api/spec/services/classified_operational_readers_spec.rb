# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# A2 operational readers (docs/design/never-fulfilled-captures.md §8.2, §8.3,
# §8.7, §8.10.9). Money acceptance examples on the real readers:
#   - E15: a fulfilled sale beside an order-scope classified capture. The
#     calculator, statement, organization summary, finance CSVs, sales
#     aggregates, payout balance and PlatformRevenue agree to the cent, and
#     the classified order never reaches organizer figures;
#   - E13: payment B on an order payment A fulfilled. A's figures are exactly
#     the sale-only figures; B's refund, loss and processing never touch them;
#   - the $0 line's live return status through owed, being returned, partly
#     returned, confirming, returned and returned twice, with a digest that
#     never moves;
#   - P4: a proven platform-only over-return holds nothing, and the same
#     over-return with a linked adjustment holds the event in the application
#     and the database fence; resolving it clears the hold;
#   - linked adjustments: cash ones are $0 and alerted, controls stay, the
#     fulfilled order's own adjustment stays;
#   - cancellation recovery and payout balance treat classified refunds and
#     disputes as controls, never organizer debits.
RSpec.describe "Classified operational readers" do
  include ActiveJob::TestHelper

  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 2000) }
  let(:info) { Commerce::ClassifiedOrganizerView::INFO_DESCRIPTION }

  before do
    allow(StripeService).to receive(:verify_payment_context!)
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
    allow(Sentry).to receive(:capture_message)
    allow(PayoutGateway).to receive(:submit) do |payout|
      PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing)
    end
  end

  # $100.00 sale: 5 x $20.00, buyer fees $5.00, organizer-borne processing $1.00.
  def ordinary_sale!
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5, processing_fee_cents: 100)
  end

  # The $13.60 order (K = 1200, 160, 0, 0) with verified processing $0.69.
  def classified_order!(bearer: "platform")
    order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]], event: event)
    if bearer == "organizer"
      UnfulfilledCapture.where(id: capture.id).then do |relation|
        ActiveRecord::Base.connection.execute("ALTER TABLE never_fulfilled_captures DISABLE TRIGGER never_fulfilled_captures_append_only")
        relation.update_all(processing_bearer: "organizer")
      ensure
        ActiveRecord::Base.connection.execute("ALTER TABLE never_fulfilled_captures ENABLE TRIGGER never_fulfilled_captures_append_only")
      end
      capture.reload
    end
    component = create(:fee_component, order: order, order_item: order.order_items.first, kind: "processing",
      amount_cents: 69, estimated: false, provider_reference: "txn_ops_#{SecureRandom.hex(4)}")
    create(:stripe_fee_evidence, :verified, payment: payment, fee_component: component,
      provider_balance_transaction_id: component.provider_reference)
    issue = ReconciliationException.create!(order: order, payment: payment, code: "late_payment_success_after_hold_expiry")
    [order, payment, capture, issue]
  end

  # Payment B captured on an order payment A fulfilled, with B's own verified
  # processing ($0.74) recorded on A's order.
  def second_capture!(order, payment_a)
    order.update!(fulfilled_by_payment_id: payment_a.id)
    payment_b = create(:payment, order: order, provider_payment_id: "pi_ops_b_#{SecureRandom.hex(3)}", amount_cents: 1500,
      status: :succeeded, succeeded_at: Time.current)
    capture_b = UnfulfilledCapture.create!(order: order, payment: payment_b, capture_scope: "payment",
      code: "unfulfilled_second_capture", captured_cents: 1500, currency: "usd", proceeds_cents: 1500, fee_cents: 0,
      organizer_fee_cents: 0, tax_cents: 0, processing_bearer: "platform", dispute_fee_bearer: "platform",
      allocation_policy: "item_record", policy_version: Commerce::NeverFulfilledClassification::POLICY_VERSION,
      provenance: "lifecycle")
    component = create(:fee_component, order: order, kind: "processing", amount_cents: 74, estimated: false,
      provider_reference: "txn_ops_b_#{SecureRandom.hex(4)}")
    create(:stripe_fee_evidence, :verified, payment: payment_b, fee_component: component,
      provider_balance_transaction_id: component.provider_reference)
    issue = ReconciliationException.create!(order: order, payment: payment_b, code: "unfulfilled_second_capture")
    [payment_b, capture_b, issue]
  end

  def figures(event)
    Settlements::Calculator.call(event).attributes.except(:calculated_at, :source_digest, :organization, :event)
  end

  def digest(event) = Settlements::Calculator.call(event).attributes[:source_digest]

  def summary_row(event)
    OrganizationFinanceSummary.call(organization)[:events].find { |row| row[:id] == event.id }
      .slice(:gross_cents, :refund_cents, :organizer_proceeds_cents, :processing_fee_cents, :platform_processing_fee_cents,
        :sales_cents, :item_discount_cents, :absorbed_fee_cents, :refunded_proceeds_cents, :buyer_fee_cents,
        :other_adjustment_cents, :balance_cents, :payable_cents)
  end

  def sales_views(event)
    {
      summary: summary_row(event),
      orders_csv: FinanceExports.each_order_row([event]).map { |row| row.except(:order_date) },
      ledger: Commerce::LedgerTotals.call(event.orders),
      analytics: EventSalesAnalytics.call(event).slice(:sales_by_day, :sales_by_channel)
    }
  end

  def info_lines(event)
    PayoutStatement.call(event: event)[:sections].flat_map { |section| section[:lines] }.select { |line| line[:label] == info }
  end

  def statement_csv_info(event)
    FinanceExports.statement_rows(event, nil).select { |row| row[6] == info }
  end

  describe "E15: a fulfilled sale beside an order-scope classified capture" do
    it "keeps every organizer reader on the sale alone and books the classified money only as HåfaPass's" do
      ordinary_sale!
      approved_bank_account!(organization, actor: profile.user, admin: admin)
      sale = figures(event)
      sale_views = sales_views(event)
      revenue = Commerce::PlatformRevenue.call
      expect(sale).to include(organizer_proceeds_cents: 10_000, processing_fee_cents: 100, payable_cents: 9900)

      order, payment, capture, issue = classified_order!
      ingest_provider_refund!(payment, 500, id: "re_ops_five")
      lose_dispute!(payment, "dp_ops_rest", amount: 860)
      expect(order.reload.status).to eq("partially_refunded")
      expect(issue.reload).to be_resolved

      expect(figures(event)).to eq(sale)
      expect(sales_views(event)).to eq(sale_views)
      expect(FinanceExports.each_order_row([event]).map { |row| row[:order_reference] }).not_to include(order.reference)
      expect(statement_csv_info(event).map { |row| [row[5], row[7], row[8].to_s] }).to eq([["adjustment", order.reference, "0.00"]])
      expect(info_lines(event)).to eq([{ label: info, amount_cents: 0, return_status: "returned",
        note: "Returned to the buyer. Not part of your proceeds." }])
      statement = PayoutStatement.call(event: event)
      expect(statement[:reconciles]).to be(true)
      expect(statement[:notes]).to include(a_string_including("never part of your proceeds or payout"))
      expect_statement_to_reconcile(statement, event)

      # HåfaPass: fee share recognized and fully returned (P2), processing a
      # platform cost under the snapshot bearer. Not floored, not organizer.
      after = Commerce::PlatformRevenue.call
      expect(after[:classified]).to include(fee_revenue_cents: 0, fee_returned_cents: 160, platform_processing_cents: 69,
        organizer_processing_cents: 0)
      expect(after[:gross_platform_fee_cents]).to eq(revenue[:gross_platform_fee_cents])
      expect(after[:platform_processing_fee_cents]).to eq(revenue[:platform_processing_fee_cents] + 69)
      expect(after[:organizer_processing_fee_cents]).to eq(revenue[:organizer_processing_fee_cents])

      # The payout balance and the payout itself are the sale's.
      settlement = Settlements::Finalizer.call(event: event, actor: admin)
      expect(OrganizationPayoutBalance.available_cents(organization)).to eq(9900)
      expect(settlement).to have_attributes(payable_cents: 9900, platform_processing_fee_cents: 0)
      expect(settlement.settlement_items.where(description: info).sole)
        .to have_attributes(amount_cents: 0, source_type: "UnfulfilledCapture", source_id: capture.id)
      payout = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "ops-e15")
      expect(payout).to have_attributes(amount_cents: 9900)
    end

    it "keeps a fulfilled-only event's figures and digest exactly as the pre-A2 reader produced them" do
      ordinary_sale!
      expect(Settlements::Calculator.call(event).items.map { |item| item[:kind] })
        .not_to include(a_string_matching(/never/))
      expect(digest(event)).to eq(Legacy7bcd97c2.settlements_calculator.call(event).attributes[:source_digest])
    end
  end

  describe "E13: payment B on an order payment A fulfilled" do
    it "leaves A's sale exactly as it was and shows B as one $0 line" do
      order, _item, payment_a = ordinary_sale!
      approved_bank_account!(organization, actor: profile.user, admin: admin)
      sale = figures(event)
      sale_views = sales_views(event)

      payment_b, capture_b, issue_b = second_capture!(order, payment_a)
      ingest_provider_refund!(payment_b, 700, id: "re_ops_b")
      lose_dispute!(payment_b, "dp_ops_b", amount: 1500)
      Commerce::NeverFulfilledResolution.evaluate!(capture_b.reload, trigger: "spec")
      expect(issue_b.reload).to be_resolved
      expect(ledger(capture_b)).to have_attributes(owed_cents: 0, excess_cents: 700)

      expect(figures(event)).to eq(sale)
      expect(sales_views(event)).to eq(sale_views)
      row = FinanceExports.each_order_row([event]).sole
      expect(row).to include(order_reference: order.reference, refunded_to_buyer: 0, card_processing_paid_by_organizer: 100)
      expect(info_lines(event).map { |line| line[:return_status] }).to eq(["returned"])
      item = Settlements::Calculator.call(event).items.find { |entry| entry[:description] == info }
      expect(item[:metadata]).to include(capture_scope: "payment", payment_ids: [payment_b.id], captured_cents: 1500)

      revenue = Commerce::PlatformRevenue.call
      expect(revenue[:classified]).to include(platform_processing_cents: 74, fee_revenue_cents: 0, excess_returned_cents: 700)
      # The over-return is proven platform-only (P4): it holds nothing.
      overpaid = ReconciliationException.open.find_by!(payment: payment_b, code: "never_fulfilled_buyer_overpaid")
      expect(Commerce::NeverFulfilledPayoutHold.proven_platform_only_overpaid).to contain_exactly(overpaid)
      expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(false)
      expect(Settlements::Finalizer.call(event: event, actor: admin)).to have_attributes(payable_cents: 9900)
      expect(OrganizationPayoutBalance.available_cents(organization)).to eq(9900)
    end
  end

  describe "the $0 line" do
    it "reports the live return status without changing the statement digest" do
      ordinary_sale!
      _order, payment, capture, = classified_order!
      approved = digest(event)
      statuses = -> { info_lines(event).map { |line| line[:return_status] } }
      expect(statuses.call).to eq(["owed"])

      pending = ingest_provider_refund!(payment, 500, id: "re_ops_pending", status: "pending")
      expect(pending).to be_pending
      expect(statuses.call).to eq(["being_returned"])
      expect(digest(event)).to eq(approved)

      ingest_provider_refund!(payment, 500, id: "re_ops_pending")
      expect(statuses.call).to eq(["partly_returned"])
      expect(info_lines(event).sole[:note]).to eq("Partly returned; the rest is owed to the buyer. Not part of your proceeds.")

      # A provider fact the ledger cannot read yet (no posting) is never
      # shown as returned.
      allow(Commerce::NeverFulfilledReconcile).to receive(:unposted_movement_payment_ids).and_return([payment.id])
      expect(statuses.call).to eq(["confirming"])
      allow(Commerce::NeverFulfilledReconcile).to receive(:unposted_movement_payment_ids).and_call_original

      lose_dispute!(payment, "dp_ops_status", amount: 860)
      expect(statuses.call).to eq(["returned"])

      # Returned twice: still "returned" (the excess is HåfaPass's loss).
      ingest_provider_refund!(payment, 1360, id: "re_ops_twice")
      Commerce::NeverFulfilledResolution.evaluate!(capture.reload, trigger: "spec")
      expect(ledger(capture)).to have_attributes(owed_cents: 0, excess_cents: 1360)
      expect(statuses.call).to eq(["returned"])
      expect(digest(event)).to eq(approved)
    end

    it "charges an organizer-borne snapshot as its own item, which does change the digest" do
      ordinary_sale!
      classified_order!(bearer: "organizer")
      result = Settlements::Calculator.call(event)
      processing = result.items.select { |item| item[:kind] == "processing_fee" }
      expect(processing.map { |item| [item[:amount_cents], item[:description]] })
        .to contain_exactly([-100, "Actual payment processing cost"], [-69, "Card processing on an unfulfilled payment"])
      expect(result.attributes).to include(processing_fee_cents: 169, organizer_proceeds_cents: 10_000)
    end
  end

  describe "P4 and linked adjustments" do
    def post_adjustment!(kind:, amount:, order: nil, dispute: nil, reversal_of: nil, target_event: event)
      organization.balance_adjustments.create!(event: target_event, order: order, dispute: dispute, kind: kind,
        amount_cents: amount, currency: "usd", status: :posted, reason: "Fictional #{kind}", effective_at: Time.current,
        created_by_user: admin, reversal_of: reversal_of)
    end

    it "holds an over-return that is not proven platform-only in the readers and the database, until finance clears it" do
      ordinary_sale!
      approved_bank_account!(organization, actor: profile.user, admin: admin)
      order, payment, capture, = classified_order!
      ingest_provider_refund!(payment, 1360, id: "re_ops_full")
      lose_dispute!(payment, "dp_ops_twice", amount: 1360)
      Commerce::NeverFulfilledResolution.evaluate!(capture.reload, trigger: "spec")
      overpaid = ReconciliationException.open.find_by!(payment: payment, code: "never_fulfilled_buyer_overpaid")
      expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(false)

      # A manual debit linked to the classified order: not the organizer's,
      # and it breaks the P4 proof.
      debit = post_adjustment!(kind: "manual_debit", amount: -500, order: order)
      expect(figures(event)).to include(adjustment_cents: 0, payable_cents: 9900)
      expect(Commerce::NeverFulfilledPayoutHold.proven_platform_only_overpaid).to be_empty
      expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(true)
      expect(OrganizationPayoutBalance.available_cents(organization)).to eq(0)
      expect { Settlements::Finalizer.call(event: event, actor: admin) }
        .to raise_error(Settlements::Finalizer::FinalizationError, /reconciliation exceptions/)
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          Settlement.new(event: event, organization: organization, status: :finalized, version: 1, source_digest: "p4",
            calculated_at: Time.current, finalized_at: Time.current, currency: "usd").save!(validate: false)
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /Repayment fence/)
      alerts = Commerce::ClassifiedPaymentFinance.new(Time.current.beginning_of_month...Time.current.next_month.beginning_of_month).alerts
      expect(alerts).to include(a_hash_including(code: "classified_linked_adjustment", balance_adjustment_id: debit.id,
        amount_cents: -500))

      # Cleared: finance resolves the over-return; nothing holds the organizer.
      overpaid.resolve!
      expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(false)
      expect(Settlements::Finalizer.call(event: event, actor: admin)).to have_attributes(payable_cents: 9900)
      expect(OrganizationPayoutBalance.available_cents(organization)).to eq(9900)
    end

    # CodeRabbit 4703321667: the proof needs positive funding lineage. A paid
    # payout approved on a version without the capture's $0 line may have
    # funded the organizer from it, so the over-return holds.
    it "holds an over-return when a payout that moved money was approved on a version without the capture's line" do
      ordinary_sale!
      approved_bank_account!(organization, actor: profile.user, admin: admin)
      create_paid_payout!
      _order, payment, capture, = classified_order!
      ingest_provider_refund!(payment, 1360, id: "re_ops_lineage")
      lose_dispute!(payment, "dp_ops_lineage", amount: 1360)
      Commerce::NeverFulfilledResolution.evaluate!(capture.reload, trigger: "spec")
      overpaid = ReconciliationException.open.find_by!(payment: payment, code: "never_fulfilled_buyer_overpaid")

      expect(Commerce::NeverFulfilledPayoutHold.proven_platform_only_overpaid).to be_empty
      expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(true)
      expect(Commerce::NeverFulfilledPayoutHold.block_started_at(event)).to eq(overpaid.reload.created_at)

      # The same payout failed (no money moved): nothing it funded remains.
      Payout.where(event: event).update_all(status: Payout.statuses[:failed])
      expect(Commerce::NeverFulfilledPayoutHold.proven_platform_only_overpaid).to contain_exactly(overpaid)
      expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(false)
    end

    it "keeps controls and the fulfilled order's own adjustment, and books linked cash adjustments nowhere" do
      sale_order, = ordinary_sale!
      order, payment, = classified_order!
      dispute = lose_dispute!(payment, "dp_ops_linked", amount: 1360)
      post_adjustment!(kind: "manual_credit", amount: 300, order: sale_order)
      post_adjustment!(kind: "reserve_hold", amount: -200, order: order)
      now = Time.current.in_time_zone("Pacific/Guam")
      cpa_row = -> { CpaMonthlyReport.new(now.year, now.month).report[:rows].find { |entry| entry[:event_id] == event.id } }
      cpa_before = cpa_row.call
      debit = post_adjustment!(kind: "manual_debit", amount: -500, order: order)
      reversal = post_adjustment!(kind: "manual_credit", amount: 500, order: order, reversal_of: debit)
      dispute_debit = post_adjustment!(kind: "manual_debit", amount: -100, dispute: dispute)

      expect(figures(event)).to include(adjustment_cents: 300, reserve_cents: 200, payable_cents: 9900 + 300 - 200)
      items = Settlements::Calculator.call(event).items.select { |item| item[:source_type] == "BalanceAdjustment" }
      linked = items.select { |item| item[:metadata][:never_fulfilled_linked] }
      expect(linked.map { |item| [item[:source_id], item[:amount_cents], item[:metadata][:recorded_amount_cents]] })
        .to contain_exactly([debit.id, 0, -500], [reversal.id, 0, 500], [dispute_debit.id, 0, -100])
      lines = PayoutStatement.call(event: event)[:sections].flat_map { |section| section[:lines] }
      expect(lines.count { |line| line[:label].include?("not counted") }).to eq(3)
      expect(PayoutStatement.call(event: event)[:reconciles]).to be(true)

      # CPA: neither custody nor bridge (the row is unchanged); alerted.
      expect(cpa_row.call).to eq(cpa_before)
      report = CpaMonthlyReport.new(now.year, now.month).report
      expect(report[:current_integrity_alerts][:classified_payment_alerts].map { |alert| alert[:balance_adjustment_id] })
        .to include(debit.id, reversal.id, dispute_debit.id)
    end
  end

  describe "controls versus debits" do
    it "treats a classified pending refund as a hold, never an organizer debit, and leaves it out of cancellation recovery" do
      sale_order, = ordinary_sale!
      _order, payment, _capture, issue = classified_order!
      ingest_provider_refund!(payment, 1360, id: "re_ops_done")
      expect(issue.reload).to be_resolved
      pending = before_repayment_fence do
        create(:refund, order: payment.order, payment: payment, amount_cents: 400, status: :pending,
          idempotency_key: "ops-pending-#{SecureRandom.hex(3)}")
      end
      ordinary_pending = create(:refund, order: sale_order, payment: sale_order.payments.first, amount_cents: 250,
        status: :pending, idempotency_key: "ops-sale-pending-#{SecureRandom.hex(3)}")

      expect(OrganizationPayoutBalance.available_cents(organization)).to eq(0)
      entries = RefundReconciliationQueue.new(event_id: event.id).entries
      expect(entries.select { |entry| entry[:type] == "refund" }.to_h { |entry| [entry[:id], entry[:classified_payment]] })
        .to eq(pending.id => true, ordinary_pending.id => false)
      create_paid_payout!
      event.update_columns(status: Event.statuses[:cancelled])
      expect(RefundReconciliationQueue.recovery_amount_for_event(event.reload)).to eq(250)
    end

    # CodeRabbit 4703321641: payment B's newer failed refund must not take the
    # sale's refundable balance before it is left out of recovery.
    it "keeps the sale's own failed refund in cancellation recovery beside a newer failed refund on payment B" do
      sale_order, = ordinary_sale!
      payment_a = sale_order.payments.first
      full = sale_order.reload.refundable_cents
      sale_failed = create(:refund, order: sale_order, payment: payment_a, amount_cents: full, status: :failed,
        idempotency_key: "ops-sale-failed-#{SecureRandom.hex(3)}", created_at: 2.minutes.ago)
      payment_b, = second_capture!(sale_order, payment_a)
      b_failed = before_repayment_fence do
        create(:refund, order: sale_order, payment: payment_b, amount_cents: 1000, status: :failed,
          idempotency_key: "ops-b-failed-#{SecureRandom.hex(3)}", created_at: 1.minute.ago)
      end

      entries = RefundReconciliationQueue.new(event_id: event.id).entries.select { |entry| entry[:type] == "refund" }
      expect(entries.to_h { |entry| [entry[:id], [entry[:amount_cents], entry[:classified_payment]]] })
        .to eq(sale_failed.id => [full, false], b_failed.id => [1000, true])
      create_paid_payout!
      event.update_columns(status: Event.statuses[:cancelled])
      expect(RefundReconciliationQueue.recovery_amount_for_event(event.reload)).to eq(full)
    end
  end

  # CodeRabbit 4703321645: an organizer-borne verified fee on payment B with
  # no fee component is held, never silently left off the payable.
  describe "organizer-borne processing on payment B held for review" do
    def held_fee!(payment_b, bearer:)
      UnfulfilledCapture.where(payment_id: payment_b.id).then do |relation|
        ActiveRecord::Base.connection.execute("ALTER TABLE never_fulfilled_captures DISABLE TRIGGER never_fulfilled_captures_append_only")
        relation.update_all(processing_bearer: bearer)
      ensure
        ActiveRecord::Base.connection.execute("ALTER TABLE never_fulfilled_captures ENABLE TRIGGER never_fulfilled_captures_append_only")
      end
      StripeFeeEvidence.create!(payment: payment_b, context_digest: "ctx_held_#{SecureRandom.hex(3)}", status: :review_required,
        provider_charge_id: "ch_held", provider_balance_transaction_id: "txn_held_#{SecureRandom.hex(3)}",
        evidence_digest: "digest_held_#{SecureRandom.hex(3)}", currency: "usd", fee_cents: 74,
        last_error_code: StripeProcessingFees::PAYMENT_SCOPE_DEFERRED_CODE)
      return if bearer == "platform"

      ReconciliationException.create!(order: payment_b.order, payment: payment_b, code: StripeProcessingFees::REVIEW_CODE)
    end

    it "blocks finalization and every payout entry until finance books the exact cost, and holds nothing when HåfaPass bears it" do
      sale_order, = ordinary_sale!
      approved_bank_account!(organization, actor: profile.user, admin: admin)
      settlement = Settlements::Finalizer.call(event: event, actor: admin)
      sale_order.update!(fulfilled_by_payment_id: sale_order.payments.first.id)
      payment_b = create(:payment, order: sale_order, provider_payment_id: "pi_ops_held_#{SecureRandom.hex(3)}",
        amount_cents: 1500, status: :succeeded, succeeded_at: Time.current)
      UnfulfilledCapture.create!(order: sale_order, payment: payment_b, capture_scope: "payment",
        code: "unfulfilled_second_capture", captured_cents: 1500, currency: "usd", proceeds_cents: 1500, fee_cents: 0,
        organizer_fee_cents: 0, tax_cents: 0, processing_bearer: "organizer", dispute_fee_bearer: "platform",
        allocation_policy: "item_record", policy_version: Commerce::NeverFulfilledClassification::POLICY_VERSION,
        provenance: "lifecycle")
      held_fee!(payment_b, bearer: "organizer")

      expect(Commerce::NeverFulfilledPayoutHold.organizer_processing_held?(event)).to be(true)
      # Not charged on any statement line yet, so nothing may be paid.
      expect(figures(event)[:processing_fee_cents]).to eq(100)
      expect { Settlements::Finalizer.call(event: event, actor: admin) }.to raise_error(Settlements::Finalizer::FinalizationError)
      expect { PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "held-fee", amount_cents: 500) }
        .to raise_error(PayoutCreator::PayoutError, Commerce::NeverFulfilledPayoutHold::ORGANIZER_PROCESSING_MESSAGE)
      expect(Payout.where(event: event)).to be_empty

      # HåfaPass-borne (the default): no review, nothing held by it.
      ReconciliationException.where(payment: payment_b, code: StripeProcessingFees::REVIEW_CODE).delete_all
      StripeFeeEvidence.where(payment: payment_b).delete_all
      held_fee!(payment_b, bearer: "platform")
      expect(Commerce::NeverFulfilledPayoutHold.organizer_processing_held?(event)).to be(false)
    end
  end

  # CodeRabbit 4703321685: in production the statement's money leaves a
  # test-mode classified order out, but its $0 line is written, so the
  # database's restatement rule (every classification) and the statement read
  # one population.
  describe "production mode population" do
    it "gives a test-mode classified order its $0 line beside live sales, so the version is not restated" do
      _sale_order, _item, sale_payment = ordinary_sale!
      Payment.where(id: sale_payment.id).update_all(provider_environment: "live",
        provider_payment_id: "pi_live_ops_#{SecureRandom.hex(3)}")
      _order, payment, capture, issue = classified_order!
      ingest_provider_refund!(payment, 1360, id: "re_ops_testmode")
      expect(issue.reload).to be_resolved
      allow(Rails.env).to receive(:production?).and_return(true)

      settlement = Settlements::Finalizer.call(event: event, actor: admin).reload
      info = settlement.settlement_items.select { |item| item.metadata["adjustment_kind"] == "never_fulfilled_capture" }
      expect(info.map { |item| [item.amount_cents, item.metadata["payment_ids"]] }).to eq([[0, [payment.id]]])
      expect(settlement.payable_cents).to eq(figures(event)[:payable_cents])
      expect(ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(["SELECT hafapass_settlement_restated_at(?)", settlement.id])
      )).to be_nil
      expect(PayoutEntryGuard.stale?(build(:payout, event: event, settlement: settlement, organization: organization)))
        .to be(false)
      expect(capture.reload.order.never_fulfilled?).to be(true)
    end
  end

  describe "durable recording time for verified fee facts" do
    it "is stamped by the database the first time facts arrive, set once, and backfilled only at the backfill's time" do
      order, payment_a = ordinary_sale!.values_at(0, 2)
      payment_b, = second_capture!(order, payment_a)
      evidence = StripeFeeEvidence.find_by!(payment: payment_b)
      expect(evidence.facts_recorded_at).to be_present
      refused = lambda do |record, value|
        ActiveRecord::Base.transaction(requires_new: true) { record.update_columns(facts_recorded_at: value) }
      end
      expect { refused.call(evidence, 1.day.ago) }.to raise_error(ActiveRecord::StatementInvalid, /set once/)

      other_order, _other_item, other_payment = record_card_sale!(event, ticket_type: ticket_type, processing_fee_cents: 0)
      late = StripeFeeEvidence.create!(payment: other_payment, context_digest: "ctx_c_#{other_order.id}", status: :pending)
      expect(late.facts_recorded_at).to be_nil
      expect { refused.call(late, Time.current) }.to raise_error(ActiveRecord::StatementInvalid, /stamped by the database/)
      late.update!(evidence_digest: "digest_c", fee_cents: 30)
      expect(late.reload.facts_recorded_at).to be_present

      # A row that held facts before the column existed stays undated until
      # the explicit backfill names it.
      stamp!(evidence, :facts_recorded_at, nil, trigger: "stripe_fee_evidences_facts_recorded_at")
      evidence.reload.touch
      expect(evidence.reload.facts_recorded_at).to be_nil
      before = Time.current
      StripeFeeEvidence.transaction do
        FinancialIntegrity.with_evidence(:fee_facts_backfill, evidence.id) { evidence.touch }
      end
      expect(evidence.reload.facts_recorded_at).to be >= before - 1.second
    end
  end

  # A paid payout on the event, recorded below the payout fences (fixture).
  def create_paid_payout!
    tables = %w[settlements payouts]
    tables.each { |table| ActiveRecord::Base.connection.execute("ALTER TABLE #{table} DISABLE TRIGGER USER") }
    create(:payout, organization: organization, event: event, amount_cents: 1000, status: :paid, paid_at: Time.current)
  ensure
    tables.each { |table| ActiveRecord::Base.connection.execute("ALTER TABLE #{table} ENABLE TRIGGER USER") }
  end
end
