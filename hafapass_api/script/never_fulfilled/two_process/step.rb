# frozen_string_literal: true

# One step of the two-process rehearsal, run as
#   REHEARSAL_DIR=... REHEARSAL_ROLE=old|new bin/rails runner <this file> <step>
# by rehearse_two_process.sh, in the 7bcd97c2 app ("old") or this release's
# app ("new"), against the same task-owned database. Each step records what
# happened in outcomes.jsonl; provider calls go to calls.jsonl (stubs.rb).
# Fixture IDs are shared through state.json. Fictional data only.
require_relative "stubs"

module RehearsalStep
  STATE = File.join(Rehearsal::DIR, "state.json")

  module_function

  def state = File.exist?(STATE) ? JSON.parse(File.read(STATE)) : {}
  def save!(values) = File.write(STATE, JSON.pretty_generate(state.merge(values.transform_keys(&:to_s))))
  def find(model, key) = model.find(state.fetch(key))

  # Records the result or the error of one attempted action.
  def attempt(step, action)
    value = yield
    Rehearsal.outcome!(step, action: action, result: "ok", value: summarize(value))
    value
  rescue StandardError => e
    Rehearsal.outcome!(step, action: action, result: "refused", error: e.class.name, message: e.message.lines.first.to_s.strip)
    nil
  end

  def summarize(value)
    case value
    when ActiveRecord::Base then { type: value.class.name, id: value.id, status: value.try(:status) }.compact
    when Hash, Array, String, Integer, Symbol, true, false, nil then value
    else value.class.name
    end
  end

  def refund_rows(order)
    Refund.where(order_id: order.id).order(:id).map do |refund|
      [refund.id, refund.payment_id, refund.status, refund.amount_cents, refund.provider_refund_id, refund.failure_code]
    end
  end

  def sale(order)
    order.reload
    { status: order.status, refund_amount_cents: order.refund_amount_cents,
      tickets: order.tickets.order(:id).pluck(:status), refund_items: RefundItem.joins(:refund).where(refunds: { order_id: order.id }).count,
      commissions: order.promoter_commission_entries.order(:id).pluck(:kind, :amount_cents) }
  end

  def webhook!(type, object, id:)
    payload = { "id" => id, "type" => type, "data" => { "object" => object.deep_stringify_keys } }
    StripeWebhookProcessor.call(event: Stripe::Event.construct_from(payload), payload: payload)
  end

  def receipt(id) = WebhookEvent.find_by(provider_event_id: id)&.slice(:status, :last_error)&.transform_values { |v| v.to_s.lines.first.to_s.strip }
end

# Fixtures are built only by this release (the setup step and one helper).
module RehearsalFixtures
  # Spec helpers for fixtures only; RSpec itself is not loaded here.
  if Rehearsal::ROLE == "new"
    Object.const_set(:RSpec, Module.new { def self.configure(*) = nil }) unless defined?(::RSpec)
    root = Rails.root.join("spec/support")
    require root.join("payout_statement_helpers").to_s
    require root.join("never_fulfilled_return_helpers").to_s
    extend FactoryBot::Syntax::Methods
    extend PayoutStatementHelpers
    extend NeverFulfilledReturnHelpers
  end

  module_function

  def late_capture!(event, key)
    order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]], event: event, intent: "pi_reh_#{key}")
    ReconciliationException.create!(order: order, payment: payment, code: "late_payment_success_after_hold_expiry")
    [order, payment, capture]
  end

  def legacy_row!(payment, failure_code:)
    before_repayment_fence do
      payment.refunds.create!(order: payment.order, provider: "stripe", idempotency_key: "late-capture:payment:#{payment.id}",
        amount_cents: payment.amount_cents, currency: "usd", status: :pending, reason: "late_capture_refund",
        failure_code: failure_code)
    end
  end

  # A fulfilled two-ticket online sale paid by payment A (with a commission).
  def online_sale!(event, ticket_type)
    result = Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: ticket_type.id, quantity: 2 }],
      buyer_email: "rehearsal.buyer@example.com", buyer_name: "Rehearsal Buyer")
    promoter = create(:promoter, event: event, commission_bps: 1000)
    ReferralAttribution.create!(order: result.order, promoter: promoter, code_snapshot: promoter.code, attributed_at: Time.current)
    payment = result.payment
    RehearsalStep.webhook!("payment_intent.succeeded", { id: payment.provider_payment_id, amount: payment.amount_cents,
      amount_received: payment.amount_cents, currency: "usd", status: "succeeded" }, id: "evt_reh_a_#{payment.id}")
    [result.order.reload, payment.reload]
  end

  def verified_processing!(order, payment, cents)
    component = create(:fee_component, order: order, order_item: order.order_items.first, kind: "processing",
      amount_cents: cents, estimated: false, provider_reference: "txn_reh_#{payment.id}")
    create(:stripe_fee_evidence, :verified, payment: payment, fee_component: component,
      provider_balance_transaction_id: component.provider_reference)
  end

  def close_fee_reviews!(order)
    ReconciliationException.open.where(order: order).where(code: StripeProcessingFees::REVIEW_CODE)
      .or(ReconciliationException.open.where(order: order, code: "stripe_fee_adjustment_review_required"))
      .find_each(&:resolve!)
  end

  # Payment.provider_environment is read-only in Active Record; a fixture
  # sets it directly, as a live checkout would have recorded it.
  def make_live!(payment)
    Payment.where(id: payment.id).update_all(provider_environment: "live")
  end

  def second_payment!(order, a, intent)
    order.payments.create!(provider: "stripe", provider_environment: "test",
      provider_platform_account_id: a.provider_platform_account_id, provider_payment_id: intent,
      idempotency_key: "second:#{order.id}:#{intent}", amount_cents: 1500, currency: "usd", status: :pending)
  end
end

step = ARGV.fetch(0)
S = RehearsalStep
F = RehearsalFixtures
new_release = Rehearsal::ROLE == "new"

case step
when "setup"
  raise "setup runs in this release" unless new_release

  SiteSetting.instance.update!(payment_mode: "test")
  admin = F.create(:user, :admin)
  profile = F.create(:organizer_profile, :verified)
  organization = profile.organization
  late_event = F.create(:event, :completed, organization: organization, organizer_profile: profile)
  l1, p1, = F.late_capture!(late_event, "l1")
  _l2, p2, = F.late_capture!(late_event, "l2")
  F.legacy_row!(p2, failure_code: nil)
  _l3, p3, = F.late_capture!(late_event, "l3")
  r3 = F.legacy_row!(p3, failure_code: "provider_result_unknown")
  _l4, p4, = F.late_capture!(late_event, "l4")
  r4 = F.legacy_row!(p4, failure_code: nil)

  iso_event = F.create(:event, :published, organization: organization, organizer_profile: profile)
  iso_type = F.create(:ticket_type, event: iso_event, price_cents: 1200, quantity_available: 20, quantity_sold: 0)
  iso_order, iso_a = F.online_sale!(iso_event, iso_type)
  iso_b = F.second_payment!(iso_order, iso_a, "pi_reh_iso_b")
  S.webhook!("payment_intent.succeeded", { id: iso_b.provider_payment_id, amount: 1500, amount_received: 1500,
    currency: "usd", status: "succeeded" }, id: "evt_reh_iso_b")
  pend_order, pend_a = F.online_sale!(iso_event, iso_type)
  pend_b = F.second_payment!(pend_order, pend_a, "pi_reh_pend_b")

  legacy_event = F.create(:event, :completed, organization: organization, organizer_profile: profile)
  legacy_order = F.create(:order, event: legacy_event, status: :completed, total_cents: 1500, subtotal_cents: 1500,
    service_fee_cents: 0)
  F.create(:order_item, order: legacy_order, unit_price_cents: 1500, subtotal_cents: 1500, organizer_proceeds_cents: 1500)
  legacy_a = F.create(:payment, :succeeded, order: legacy_order, amount_cents: 1500, provider_payment_id: "pi_reh_leg_a")
  legacy_b = F.create(:payment, :succeeded, order: legacy_order, amount_cents: 1500, provider_payment_id: "pi_reh_leg_b")
  ReconciliationException.create!(order: legacy_order, payment: legacy_b,
    code: Commerce::NeverFulfilledClassification::OWNERSHIP_AMBIGUOUS_CODE, details: { reason: "no_completion_evidence" })

  pay_profile = F.create(:organizer_profile, :verified)
  pay_event = F.create(:event, :completed, organization: pay_profile.organization, organizer_profile: pay_profile)
  F.record_card_sale!(pay_event, ticket_type: F.create(:ticket_type, event: pay_event, price_cents: 2000), quantity: 5,
    processing_fee_cents: 100)
  F.approved_bank_account!(pay_event.organization, actor: pay_profile.user, admin: admin)

  nf_profile = F.create(:organizer_profile, :verified)
  nf_event = F.create(:event, :completed, organization: nf_profile.organization, organizer_profile: nf_profile)
  F.record_card_sale!(nf_event, ticket_type: F.create(:ticket_type, event: nf_event, price_cents: 2000), quantity: 5,
    processing_fee_cents: 100)
  F.approved_bank_account!(nf_event.organization, actor: nf_profile.user, admin: admin)
  nf_order, nf_payment, = F.late_capture!(nf_event, "nf")
  F.verified_processing!(nf_order, nf_payment, 69)
  F.ingest_provider_refund!(nf_payment, 500, id: "re_reh_nf_five")
  F.lose_dispute!(nf_payment, "dp_reh_nf", amount: 860)
  # Finance reviewed the fee adjustments; only the reader guard decides now.
  F.close_fee_reviews!(nf_order)

  # Live-mode data for the CPA and BPT comparison (both export live money
  # only): an ordinary sale, a fully returned never-fulfilled capture and a
  # sale with a classified second capture refunded on its own.
  cpa_profile = F.create(:organizer_profile, :verified)
  cpa_event = F.create(:event, :completed, organization: cpa_profile.organization, organizer_profile: cpa_profile)
  _sale, _item, sale_payment = F.record_card_sale!(cpa_event, ticket_type: F.create(:ticket_type, event: cpa_event, price_cents: 1500),
    quantity: 4, processing_fee_cents: 80)
  F.make_live!(sale_payment)
  live_nf_order, live_nf, = F.late_capture!(cpa_event, "live_nf")
  F.make_live!(live_nf)
  F.verified_processing!(live_nf_order, live_nf, 69)
  F.ingest_provider_refund!(live_nf, 500, id: "re_reh_live_nf")
  F.lose_dispute!(live_nf, "dp_reh_live_nf", amount: 860)
  F.close_fee_reviews!(live_nf_order)

  S.save!(cpa_event: cpa_event.id, admin: admin.id, late_event: late_event.id, l1_payment: p1.id, l1_order: l1.id, l2_payment: p2.id,
    l3_payment: p3.id, l3_refund: r3.id, l4_payment: p4.id, l4_refund: r4.id,
    iso_order: iso_order.id, iso_a: iso_a.id, iso_b: iso_b.id, pend_order: pend_order.id, pend_a: pend_a.id, pend_b: pend_b.id,
    legacy_order: legacy_order.id, legacy_a: legacy_a.id, legacy_b: legacy_b.id,
    pay_event: pay_event.id, nf_event: nf_event.id, nf_order: nf_order.id, nf_payment: nf_payment.id)
  Rehearsal.outcome!(step, action: "fixtures", result: "ok", value: S.state.keys.length)

when "r1_old_reserve"
  S.attempt(step, "LateCaptureRefund.call (no earlier refund)") { Commerce::LateCaptureRefund.call(payment: S.find(Payment, "l1_payment")) }
  Rehearsal.outcome!(step, action: "refunds", value: S.refund_rows(S.find(Payment, "l1_payment").order))

when "r2_old_pre_fence_reservation"
  S.attempt(step, "LateCaptureRefund.call (reserved before the fence)") { Commerce::LateCaptureRefund.call(payment: S.find(Payment, "l2_payment")) }
  Rehearsal.outcome!(step, action: "refunds", value: S.refund_rows(S.find(Payment, "l2_payment").order))

when "r3_old_retry_past_gate"
  S.attempt(step, "LateCaptureRefund.call (row already past its gate)") { Commerce::LateCaptureRefund.call(payment: S.find(Payment, "l3_payment")) }
  Rehearsal.outcome!(step, action: "refunds", value: S.refund_rows(S.find(Payment, "l3_payment").order))

when "r3_new_adjudicate", "r3_new_adjudicate_after"
  refund = S.find(Refund, "l3_refund")
  S.attempt(step, "RepaymentAdjudication.call") { Commerce::RepaymentAdjudication.call(refund).outcome }
  S.attempt(step, "LateCaptureRefund.call (R1)") { Commerce::LateCaptureRefund.call(payment: refund.payment) }
  capture = UnfulfilledCapture.find_by!(payment_id: refund.payment_id)
  Rehearsal.outcome!(step, action: "state", value: { refunds: S.refund_rows(refund.order),
    owed_cents: Commerce::BuyerReturnLedger.for(capture).owed_cents,
    operations: RepaymentOperation.where(payment_id: refund.payment_id).pluck(:sequence, :state, :submission_count) })

when "r4_old_replay_unsent"
  S.attempt(step, "LateCaptureRefund.call (unsent reservation, paused at its lookup)") do
    Commerce::LateCaptureRefund.call(payment: S.find(Payment, "l4_payment"))
  end
  Rehearsal.outcome!(step, action: "refunds", value: S.refund_rows(S.find(Payment, "l4_payment").order))

when "r4_new_adjudicate"
  S.attempt(step, "RepaymentAdjudication.call") { Commerce::RepaymentAdjudication.call(S.find(Refund, "l4_refund")).outcome }

when "r5_inbound_refund_on_isolated_b"
  b = S.find(Payment, "iso_b")
  S.attempt(step, "refund.created webhook on payment B") do
    S.webhook!("refund.created", { id: "re_reh_iso_b", object: "refund", payment_intent: b.provider_payment_id, amount: 700,
      currency: "usd", status: "succeeded" }, id: "evt_reh_iso_b_refund")
  end
  Rehearsal.outcome!(step, action: "state", value: { receipt: S.receipt("evt_reh_iso_b_refund"), sale: S.sale(b.order),
    refunds: S.refund_rows(b.order) })

when "r6_dispute_on_pending_b"
  b = S.find(Payment, "pend_b")
  object = { id: "dp_reh_pend_b", payment_intent: b.provider_payment_id, amount: 1500, currency: "usd", reason: "fraudulent" }
  S.attempt(step, "charge.dispute.created") { S.webhook!("charge.dispute.created", object.merge(status: "needs_response"), id: "evt_reh_pend_b_open") }
  S.attempt(step, "charge.dispute.closed lost") { S.webhook!("charge.dispute.closed", object.merge(status: "lost"), id: "evt_reh_pend_b_lost") }
  Rehearsal.outcome!(step, action: "state", value: { receipt: S.receipt("evt_reh_pend_b_lost"), sale: S.sale(b.order),
    disputes: Dispute.where(order_id: b.order_id).pluck(:provider_dispute_id, :status, :payment_id) })

when "r6_new_capture_b"
  b = S.find(Payment, "pend_b")
  S.webhook!("payment_intent.succeeded", { id: b.provider_payment_id, amount: 1500, amount_received: 1500, currency: "usd",
    status: "succeeded" }, id: "evt_reh_pend_b_capture")
  S.attempt(step, "SaleEffectHold.release!") { Commerce::SaleEffectHold.release!(b.order) }
  Rehearsal.outcome!(step, action: "state", value: { sale: S.sale(b.order),
    holds: ReconciliationException.where(order_id: b.order_id, code: Commerce::SaleEffectHold::CODE).pluck(:status),
    postings: BuyerReturnPosting.joins(:unfulfilled_capture).where(never_fulfilled_captures: { payment_id: b.id }).pluck(:kind, :applied_cents) })

when "r7_inbound_refund_on_legacy_a"
  a = S.find(Payment, "legacy_a")
  S.attempt(step, "refund.created webhook on legacy payment A") do
    S.webhook!("refund.created", { id: "re_reh_leg_a", object: "refund", payment_intent: a.provider_payment_id, amount: 1500,
      currency: "usd", status: "succeeded" }, id: "evt_reh_leg_a_refund")
  end
  Rehearsal.outcome!(step, action: "state", value: { receipt: S.receipt("evt_reh_leg_a_refund"), sale: S.sale(a.order),
    refunds: S.refund_rows(a.order) })

when "r8_finalize"
  event = S.find(Event, "pay_event")
  S.attempt(step, "Settlements::Finalizer.call") { Settlements::Finalizer.call(event: event, actor: S.find(User, "admin")) }

when "r8_reserve"
  # A pending payout reserved before the hold (finalizing a new version
  # first when an earlier reservation changed the statement).
  event = S.find(Event, "pay_event")
  key = ENV.fetch("REHEARSAL_KEY")
  settlement = S.attempt(step, "Settlements::Finalizer.call (#{key})") { Settlements::Finalizer.call(event: event, actor: S.find(User, "admin")) } ||
    event.settlements.status_finalized.order(:version).last
  payout = S.attempt(step, "PayoutCreator#reserve! (#{key})") do
    PayoutCreator.new(settlement: settlement, actor: S.find(User, "admin"), idempotency_key: "reh-#{key}",
      amount_cents: ENV["REHEARSAL_AMOUNT"]&.to_i).send(:reserve!).first
  end
  S.save!("payout_#{key}" => payout.id) if payout

when "r8_submit"
  # The release's own submission path: authorization (its audit), gateway
  # call, outcome recording.
  payout = S.find(Payout, "payout_#{ENV.fetch('REHEARSAL_KEY')}")
  creator = PayoutCreator.new(settlement: payout.settlement, actor: S.find(User, "admin"), idempotency_key: payout.idempotency_key)
  result = S.attempt(step, "PayoutCreator#submit_payout! (payout #{payout.id})") { creator.send(:submit_payout!, payout) }
  if result
    S.attempt(step, "record submission outcome (payout #{payout.id})") do
      creator.send(:record_submission_outcome!, payout, provider_payout_id: result.provider_payout_id, status: result.status,
        initiated_at: Time.current, paid_at: nil)
      payout.reload
    end
  end
  Rehearsal.outcome!(step, action: "payouts", value: payout.event.payouts.order(:id).pluck(:id, :status, :amount_cents))

when "r8_open_block"
  event = S.find(Event, "pay_event")
  order = F.create(:order, event: event, status: :completed, total_cents: 1360, subtotal_cents: 1360, service_fee_cents: 0)
  # Factory sequences restart in each process: name these rows explicitly.
  F.create(:payment, :succeeded, order: order, amount_cents: 1360, idempotency_key: "reh:block:a:#{order.id}",
    provider_payment_id: "pi_reh_block_a_#{order.id}")
  second = F.create(:payment, :succeeded, order: order, amount_cents: 1360, idempotency_key: "reh:block:b:#{order.id}",
    provider_payment_id: "pi_reh_block_b_#{order.id}")
  issue = ReconciliationException.create!(order: order, payment: second,
    code: Commerce::NeverFulfilledClassification::OWNERSHIP_AMBIGUOUS_CODE, details: { reason: "no_completion_evidence" })
  Rehearsal.outcome!(step, action: "block opened", value: { exception_id: issue.id, at: issue.created_at.utc.iso8601(6) })

when "r8_record_paid"
  event = S.find(Event, "pay_event")
  event.payouts.order(:id).each do |payout|
    S.attempt(step, "PayoutReconciler.call paid (payout #{payout.id}, #{payout.status})") do
      PayoutReconciler.call(payout: payout, actor: S.find(User, "admin"), status: "paid", provider_payout_id: "bank-reh-#{payout.id}",
        evidence: { reference: "Bank record", reason: "Transfer confirmed", confirmed_at: (payout.initiated_at || payout.created_at).utc.iso8601(6),
          approved_tax_payee_confirmed: true, approved_payee_confirmed: true, sent_before_hold_confirmed: true })
    end
  end
  Rehearsal.outcome!(step, action: "payouts", value: event.payouts.order(:id).pluck(:id, :status, :amount_cents))

when "r9_readers"
  event = S.find(Event, "nf_event")
  attributes = Settlements::Calculator.call(event).attributes
  Rehearsal.outcome!(step, action: "calculator", value: attributes.slice(:gross_cents, :refund_cents, :organizer_proceeds_cents,
    :processing_fee_cents, :adjustment_cents, :payable_cents).merge(source_digest: attributes[:source_digest]))
  S.attempt(step, "Settlements::Finalizer.call") { Settlements::Finalizer.call(event: event, actor: S.find(User, "admin")) }
  settlement = event.settlements.status_finalized.order(:version).last
  if settlement
    S.attempt(step, "PayoutCreator.call") do
      PayoutCreator.call(settlement: settlement, actor: S.find(User, "admin"), idempotency_key: "reh-r9-#{Rehearsal::ROLE}")
    end
  end
  Rehearsal.outcome!(step, action: "payouts", value: event.payouts.order(:id).pluck(:id, :status, :amount_cents))

when "exports"
  month = Time.current.in_time_zone("Pacific/Guam")
  cpa = CpaMonthlyReport.new(month.year, month.month)
  cpa_rows = cpa.csv_rows.to_a
  bpt_rows = TaxReports.new(month.year).bpt_event_rows(month.month)
  bpt_rows = bpt_rows.respond_to?(:to_a) ? bpt_rows.to_a : bpt_rows
  cpa_rows = cpa_rows.map { |row| row.map(&:to_s) }
  File.write(File.join(Rehearsal::DIR, "exports_#{Rehearsal::ROLE}.json"),
    JSON.pretty_generate(cpa_header: CpaMonthlyReport::HEADER.map(&:to_s), cpa: cpa_rows, bpt: bpt_rows))
  Rehearsal.outcome!(step, action: "exports", value: { cpa_rows: cpa_rows.length, bpt_rows: bpt_rows.length,
    cpa_sha256: Digest::SHA256.hexdigest(JSON.generate(cpa_rows)), bpt_sha256: Digest::SHA256.hexdigest(JSON.generate(bpt_rows)) })

when "payout_history"
  rows = AuditLog.where(auditable_type: "Payout").where("action LIKE 'payout.%'").order(:id)
    .pluck(:auditable_id, :action, :outcome)
  Rehearsal.outcome!(step, action: "payout transitions", value: rows)

else
  raise ArgumentError, "unknown rehearsal step #{step}"
end
