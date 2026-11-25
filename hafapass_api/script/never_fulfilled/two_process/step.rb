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

  def webhook!(type, object, id:, livemode: nil)
    # Stripe stamps every event with its creation time.
    payload = { "id" => id, "type" => type, "created" => Time.now.to_i, "data" => { "object" => object.deep_stringify_keys } }
    payload["livemode"] = livemode unless livemode.nil?
    StripeWebhookProcessor.call(event: Stripe::Event.construct_from(payload), payload: payload)
  end

  def capture!(payment, id:)
    webhook!("payment_intent.succeeded", { id: payment.provider_payment_id, amount: payment.amount_cents,
      amount_received: payment.amount_cents, currency: "usd", status: "succeeded" }, id: id, livemode: false)
  end

  def refund_notice!(payment, refund_id, amount, id:)
    webhook!("refund.created", { id: refund_id, object: "refund", payment_intent: payment.provider_payment_id, amount: amount,
      currency: "usd", status: "succeeded" }, id: id, livemode: false)
  end

  def money(order)
    sale(order).merge(sold: order.order_items.filter_map(&:ticket_type).sum { |type| type.reload.quantity_sold },
      refunds: refund_rows(order).map { |row| row[1..3] })
  end

  # This release's classification (the previous release has none).
  def classification(payment)
    return unless defined?(::UnfulfilledCapture)

    capture = UnfulfilledCapture.find_by(payment_id: payment.id)
    capture && { scope: capture.capture_scope, code: capture.code, provenance: capture.provenance,
      webhook_event_id: capture.provenance_evidence["webhook_event_id"], receipt_facts: capture.provenance_evidence["receipt_facts"],
      receipt_status: capture.provenance_evidence["receipt_status"],
      postings: capture.buyer_return_postings.in_sequence.pluck(:kind, :gross_cents, :applied_cents, :excess_cents) }
  end

  def verify_counts
    report = Commerce::NeverFulfilledReconcile.call(dry_run: true)
    { pending: report.assessments.reject { |item| %w[held reconciled].include?(item.disposition) }
      .map { |item| [item.payment_id, item.disposition, item.reason] },
      unposted: Commerce::NeverFulfilledReconcile.unposted_movement_payment_ids.sort,
      overlap: Commerce::NeverFulfilledReconcile.overlap_capture_ids,
      orphans_without_identity: Commerce::NeverFulfilledReconcile.orphan_receipts_without_identity.count }
  end

  def receipt(id) = WebhookEvent.find_by(provider_event_id: id)&.slice(:status, :last_error)&.transform_values { |v| v.to_s.lines.first.to_s.strip }
end

# Fixtures are built only by this release (the setup step and one helper).
module RehearsalFixtures
  # Both releases' factories (factory_bot_rails, test environment). The
  # previous release builds only the data that existed before the upgrade.
  extend FactoryBot::Syntax::Methods
  # Spec helpers for fixtures only; RSpec itself is not loaded here.
  if Rehearsal::ROLE == "new"
    Object.const_set(:RSpec, Module.new { def self.configure(*) = nil }) unless defined?(::RSpec)
    root = Rails.root.join("spec/support")
    require root.join("payout_statement_helpers").to_s
    require root.join("never_fulfilled_return_helpers").to_s
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

  # A fulfilled online sale paid by payment A (with a commission).
  def online_sale!(event, ticket_type, quantity: 2)
    result = Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: ticket_type.id, quantity: quantity }],
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

  def second_payment!(order, a, intent, amount_cents: 1500)
    order.payments.create!(provider: "stripe", provider_environment: "test",
      provider_platform_account_id: a.provider_platform_account_id, provider_payment_id: intent,
      idempotency_key: "second:#{order.id}:#{intent}", amount_cents: amount_cents, currency: "usd", status: :pending)
  end

  # A settled card sale 7bcd97c2 recorded before the upgrade, as its
  # checkout does (line item, platform fee, captured payment A, verified
  # processing cost) with its completion audit naming A. Runs in the
  # previous release on its schema, so A has no capture recording time and
  # the order no recorded fulfilling payment. Unique fields are explicit.
  def legacy_settled_sale!(key)
    user = create(:user, :organizer, clerk_id: "clerk_reh_#{key}", email: "rehearsal.#{key}.organizer@example.com")
    organization = create(:organization, name: "Rehearsal #{key} Organization")
    profile = create(:organizer_profile, :verified, user: user, organization: organization)
    event = create(:event, :published, organization: organization, organizer_profile: profile, title: "Rehearsal #{key} Event")
    type = create(:ticket_type, event: event, price_cents: 2000, quantity_available: 20, quantity_sold: 0)
    order = create(:order, event: event, subtotal_cents: 10_000, service_fee_cents: 500, total_cents: 10_500,
      processing_fee_bearer_snapshot: "organizer", buyer_email: "rehearsal.#{key}@example.com", completed_at: Time.current)
    item = create(:order_item, order: order, ticket_type: type, name: type.name, unit_price_cents: 2000, quantity: 5,
      subtotal_cents: 10_000, discount_cents: 0, fee_cents: 500, organizer_fee_cents: 0, organizer_proceeds_cents: 10_000)
    create(:fee_component, order: order, kind: "platform", amount_cents: 500, estimated: true)
    a = create(:payment, :succeeded, order: order, amount_cents: 10_500, provider_payment_id: "pi_reh_#{key}_a",
      idempotency_key: "reh-#{key}-a")
    component = create(:fee_component, order: order, order_item: item, kind: "processing", amount_cents: 100, estimated: false,
      provider_reference: "txn_reh_#{key}_a")
    create(:stripe_fee_evidence, :verified, payment: a, fee_component: component, provider_charge_id: "ch_reh_#{key}_a",
      provider_balance_transaction_id: component.provider_reference)
    AuditLogger.record!(action: "order.completed", auditable: order, organization: organization, event: event, outcome: "succeeded",
      deduplication_key: "order:#{order.id}:completed", after_data: { status: order.status }, metadata: { payment_id: a.id })
    [event, order.reload, a.reload, user]
  end

  # Builds the data 7bcd97c2 had before the upgrade: an ordinary online sale
  # it fulfilled itself and two orphan refund notices, one of which its
  # retention already cleared. Runs in the previous release on its schema.
  def existing_data!
    SiteSetting.instance.update!(payment_mode: "test")
    # Factory sequences restart in each process: unique fields are explicit.
    user = create(:user, :organizer, clerk_id: "clerk_reh_existing", email: "rehearsal.existing.organizer@example.com")
    organization = create(:organization, name: "Rehearsal Existing Organization")
    profile = create(:organizer_profile, :verified, user: user, organization: organization)
    event = create(:event, :published, organization: organization, organizer_profile: profile, title: "Rehearsal Existing Event")
    type = create(:ticket_type, event: event, price_cents: 1200, quantity_available: 20, quantity_sold: 0)
    result = Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: type.id, quantity: 1 }],
      buyer_email: "rehearsal.existing@example.com", buyer_name: "Existing Buyer")
    RehearsalStep.capture!(result.payment, id: "evt_reh_u_sale")
    # Live money, so the CPA and BPT exports compare real rows across the
    # upgrade (Payment.provider_environment is read-only in Active Record).
    Payment.where(id: result.payment.id).update_all(provider_environment: "live")
    RehearsalStep.webhook!("refund.created", { id: "re_reh_u_partial", object: "refund", payment_intent: result.payment.provider_payment_id,
      amount: 300, currency: "usd", status: "succeeded" }, id: "evt_reh_u_partial", livemode: true)
    RehearsalStep.webhook!("refund.created", { id: "re_reh_orphan", object: "refund", payment_intent: "pi_reh_orphan",
      amount: 1360, currency: "usd", status: "succeeded" }, id: "evt_reh_orphan", livemode: false)
    RehearsalStep.webhook!("refund.created", { id: "re_reh_orphan_gone", object: "refund", payment_intent: "pi_reh_orphan_gone",
      amount: 900, currency: "usd", status: "succeeded" }, id: "evt_reh_orphan_gone", livemode: false)
    # Cleared before the upgrade, as 7bcd97c2's retention would: no column
    # kept its identity then.
    WebhookEvent.where(provider_event_id: "evt_reh_orphan_gone").update_all(payload: {}, last_error: nil)
    [event, type, result.order.reload, result.payment.reload]
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

  # Fixtures for the later scenarios, built here because factory sequences
  # restart in each process.
  # The payment a redacted orphan notice (from before the upgrade) names.
  _orphan_order, orphan_payment, = F.late_capture!(late_event, "orphan")
  # Blocker 1: A's $13.60 sale; B captured and classified, refunded $7.00.
  r10_type = F.create(:ticket_type, event: iso_event, price_cents: 1200, quantity_available: 20, quantity_sold: 0)
  r10_order, r10_a = F.online_sale!(iso_event, r10_type, quantity: 1)
  r10_b = F.second_payment!(r10_order, r10_a, "pi_reh_r10_b", amount_cents: r10_order.total_cents)
  S.capture!(r10_b, id: "evt_reh_r10_b")
  S.refund_notice!(r10_b, "re_reh_r10_b", 700, id: "evt_reh_r10_b_refund")
  # Blocker 3: two fulfilled sales whose second payments the old release
  # will acknowledge.
  r12_profile = F.create(:organizer_profile, :verified)
  r12_event = F.create(:event, :published, organization: r12_profile.organization, organizer_profile: r12_profile)
  r12_type = F.create(:ticket_type, event: r12_event, price_cents: 1200, quantity_available: 20, quantity_sold: 0)
  r12 = { r12_event: r12_event.id }
  %w[x y].each do |key|
    order, a = F.online_sale!(r12_event, r12_type, quantity: 1)
    b = F.second_payment!(order, a, "pi_reh_r12_#{key}_b", amount_cents: order.total_cents)
    r12.merge!("r12_#{key}_order" => order.id, "r12_#{key}_a" => a.id, "r12_#{key}_b" => b.id)
  end
  r12_event.update_columns(status: Event.statuses.fetch("completed"))
  S.save!(orphan_payment: orphan_payment.id, r10_order: r10_order.id, r10_a: r10_a.id, r10_b: r10_b.id, **r12)

  # Boundary fix 1: A's late capture marks its order (this release), and a
  # $5.00 refund on A moves it to partially refunded; B waits for the old
  # release's capture.
  r14_profile = F.create(:organizer_profile, :verified)
  r14_event = F.create(:event, :published, organization: r14_profile.organization, organizer_profile: r14_profile)
  r14_type = F.create(:ticket_type, event: r14_event, price_cents: 1200, quantity_available: 20, quantity_sold: 0)
  r14 = Commerce::OrderCreator.call(event: r14_event, line_items: [{ ticket_type_id: r14_type.id, quantity: 1 }],
    buyer_email: "rehearsal.marked@example.com", buyer_name: "Marked Buyer")
  S.webhook!("payment_intent.payment_failed", { id: r14.payment.provider_payment_id, amount: r14.payment.amount_cents,
    currency: "usd" }, id: "evt_reh_r14_a_failed", livemode: false)
  S.capture!(r14.payment, id: "evt_reh_r14_a")
  S.refund_notice!(r14.payment, "re_reh_r14_a_part", 500, id: "evt_reh_r14_a_part")
  r14_b = F.second_payment!(r14.order, r14.payment, "pi_reh_r14_b", amount_cents: r14.order.total_cents)
  S.save!(r14_event: r14_event.id, r14_order: r14.order.id, r14_a: r14.payment.id, r14_b: r14_b.id)

  # Boundary fix 2: a payout submitted (and its transfer made) before B's
  # capture on a fulfilled sale.
  r15_profile = F.create(:organizer_profile, :verified)
  r15_event = F.create(:event, :completed, organization: r15_profile.organization, organizer_profile: r15_profile)
  r15_order, _item, r15_a = F.record_card_sale!(r15_event, ticket_type: F.create(:ticket_type, event: r15_event, price_cents: 2000),
    quantity: 5, processing_fee_cents: 100)
  r15_order.update!(fulfilled_by_payment_id: r15_a.id)
  F.approved_bank_account!(r15_event.organization, actor: r15_profile.user, admin: admin)
  r15_sent = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: r15_event, actor: admin), actor: admin,
    idempotency_key: "reh-r15-sent", amount_cents: 2000)
  sleep 0.05
  r15_pre_hold = Time.current
  sleep 0.05
  r15_b = F.second_payment!(r15_order, r15_a, "pi_reh_r15_b", amount_cents: r15_order.total_cents)
  S.save!(r15_event: r15_event.id, r15_order: r15_order.id, r15_b: r15_b.id, r15_sent: r15_sent.id,
    r15_pre_hold: r15_pre_hold.utc.iso8601(6))

  # Boundary fix 3: payout writers and captures on one event. r16 for the
  # capture-first race (a pending and a sent payout, B1), an unrelated event
  # of the same organizer, and r16b for the payout-first race (B2).
  r16_profile = F.create(:organizer_profile, :verified)
  r16 = {}
  %w[r16 r16_other r16b].each do |key|
    target = F.create(:event, :completed, organization: r16_profile.organization, organizer_profile: r16_profile)
    order, _item, a = F.record_card_sale!(target, ticket_type: F.create(:ticket_type, event: target, price_cents: 2000),
      quantity: 5, processing_fee_cents: 100)
    order.update!(fulfilled_by_payment_id: a.id)
    r16["#{key}_event"] = target.id
    r16["#{key}_order"] = order.id
    r16["#{key}_b"] = F.second_payment!(order, a, "pi_reh_#{key}_b", amount_cents: order.total_cents).id
  end
  F.approved_bank_account!(r16_profile.organization, actor: r16_profile.user, admin: admin)
  reserve = lambda do |key, idempotency|
    PayoutCreator.new(settlement: Settlements::Finalizer.call(event: Event.find(r16["#{key}_event"]), actor: admin), actor: admin,
      idempotency_key: idempotency, amount_cents: 2000).send(:reserve!).first.id
  end
  r16["r16_pending"] = reserve.call("r16", "reh-r16-pending")
  r16["r16_sent"] = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: Event.find(r16["r16_event"]), actor: admin),
    actor: admin, idempotency_key: "reh-r16-sent", amount_cents: 2000).id
  r16["r16_other_pending"] = reserve.call("r16_other", "reh-r16-other")
  r16["r16b_pending"] = reserve.call("r16b", "reh-r16b-pending")
  S.save!(**r16)

  # Upgrade cutoff (2f961e48 recheck): on each legacy sale the previous
  # release recorded before the upgrade, B and C wait for its captures, and
  # a payout is submitted (and its transfer made) before B's capture.
  r17 = {}
  %w[r17c r17b].each do |key|
    target = Event.find(S.state.fetch("#{key}_event"))
    target.update_columns(status: Event.statuses.fetch("completed"))
    order = Order.find(S.state.fetch("#{key}_order"))
    a = Payment.find(S.state.fetch("#{key}_a"))
    r17["#{key}_b"] = F.second_payment!(order, a, "pi_reh_#{key}_b", amount_cents: order.total_cents).id
    r17["#{key}_c"] = F.second_payment!(order, a, "pi_reh_#{key}_c", amount_cents: order.total_cents).id
    F.approved_bank_account!(target.organization, actor: User.find(S.state.fetch("#{key}_user")), admin: admin)
    r17["#{key}_sent"] = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: target, actor: admin), actor: admin,
      idempotency_key: "reh-#{key}-sent", amount_cents: 2000).id
    sleep 0.05
    r17["#{key}_pre_hold"] = Time.current.utc.iso8601(6)
  end
  sleep 0.05
  S.save!(**r17)

  S.save!(cpa_event: cpa_event.id, admin: admin.id, late_event: late_event.id, iso_event: iso_event.id, l1_payment: p1.id, l1_order: l1.id, l2_payment: p2.id,
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
  S.save!(hold_at: issue.created_at.utc.iso8601(6))
  Rehearsal.outcome!(step, action: "block opened", value: { exception_id: issue.id, at: issue.created_at.utc.iso8601(6) })

when "r8_record_paid"
  # Each release records paid with a transfer time after the hold (the
  # in-flight outcome was recorded after it, so initiated_at is post-hold)
  # and with one between the pre-hold submission and the hold. A submission
  # is not a transfer: only this release's verified pre-hold confirmation
  # may record paid on the held event; 7bcd97c2 is refused for both.
  event = S.find(Event, "pay_event")
  hold_at = Time.iso8601(S.state.fetch("hold_at"))
  event.payouts.order(:id).each do |payout|
    submitted = AuditLog.where(auditable: payout, action: "payout.submission_requested").minimum(:occurred_at)
    times = { "post-hold initiated_at" => payout.initiated_at || payout.created_at }
    times["pre-hold transfer"] = submitted + ((hold_at - submitted) / 2) if submitted && submitted < hold_at
    times.each do |label, confirmed_at|
      S.attempt(step, "PayoutReconciler.call paid (payout #{payout.id}, #{payout.reload.status}, #{label} #{confirmed_at.utc.iso8601(6)})") do
        PayoutReconciler.call(payout: payout.reload, actor: S.find(User, "admin"), status: "paid", provider_payout_id: "bank-reh-#{payout.id}",
          evidence: { reference: "Bank record", reason: "Transfer confirmed", confirmed_at: confirmed_at.utc.iso8601(6),
            approved_tax_payee_confirmed: true, approved_payee_confirmed: true, sent_before_hold_confirmed: true })
      end
    end
  end
  Rehearsal.outcome!(step, action: "payouts", value: event.payouts.order(:id).pluck(:id, :status, :amount_cents, :paid_at)
    .map { |row| row[0..2] + [row[3]&.utc&.iso8601(6)] })

when "r8_hold_second"
  payout = S.find(Payout, "payout_second")
  payout.update!(status: :held, held_from_status: payout.status)
  Rehearsal.outcome!(step, action: "held", value: payout.reload.slice(:id, :status, :held_from_status))

when "r8_release_held"
  payout = S.find(Payout, "payout_second")
  S.attempt(step, "PayoutHoldRelease.call (payout #{payout.id})") { PayoutHoldRelease.call(payout: payout, actor: S.find(User, "admin")) }
  Rehearsal.outcome!(step, action: "payout", value: payout.reload.slice(:id, :status, :held_from_status))

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
  File.write(File.join(Rehearsal::DIR, "exports_#{ENV.fetch('EXPORT_TAG', Rehearsal::ROLE)}.json"),
    JSON.pretty_generate(cpa_header: CpaMonthlyReport::HEADER.map(&:to_s), cpa: cpa_rows, bpt: bpt_rows))
  Rehearsal.outcome!(step, action: "exports", value: { cpa_rows: cpa_rows.length, bpt_rows: bpt_rows.length,
    cpa_sha256: Digest::SHA256.hexdigest(JSON.generate(cpa_rows)), bpt_sha256: Digest::SHA256.hexdigest(JSON.generate(bpt_rows)) })

when "u_existing_data"
  raise "existing data comes from the previous release" if new_release

  event, type, order, a = F.existing_data!
  S.save!(u_event: event.id, u_type: type.id, u_order: order.id, u_a: a.id)
  Rehearsal.outcome!(step, action: "existing data", value: { sale: S.money(order), payment: a.slice(:id, :status),
    receipts: WebhookEvent.order(:id).pluck(:provider_event_id, :status, :event_type) })

when "u_upgrade_checks"
  order = S.find(Order, "u_order")
  a = S.find(Payment, "u_a")
  orphan = WebhookEvent.find_by!(provider_event_id: "evt_reh_orphan")
  Rehearsal.outcome!(step, action: "after upgrade", value: { fulfilled_by: order.fulfilled_by_payment_id,
    capture_recorded_at: a.capture_recorded_at, blocked: Commerce::NeverFulfilledPayoutHold.blocked?(order.event),
    orphan_identity: orphan.provider_payment_intent_id, cutovers: FinancialCutover.order(:recorded_at).pluck(:key),
    verify: S.verify_counts })

when "u_old_redact_orphan"
  # 7bcd97c2's retention clearing an orphan receipt's payload (update_all,
  # as DataRetention does), after the upgrade.
  WebhookEvent.where(provider_event_id: "evt_reh_orphan").update_all(payload: {}, last_error: nil, updated_at: Time.current)
  Rehearsal.outcome!(step, action: "redacted", value: WebhookEvent.where(provider_event_id: "evt_reh_orphan").pick(:payload))

when "u_after_redaction"
  orphan = WebhookEvent.find_by!(provider_event_id: "evt_reh_orphan")
  payment = S.find(Payment, "orphan_payment")
  receipts = StripeWebhookProcessor.replayable_receipts(payment).pluck(:id)
  replay = S.attempt(step, "StripeWebhookProcessor.replay! (redacted orphan)") { StripeWebhookProcessor.replay!(orphan, payment: payment) }
  Rehearsal.outcome!(step, action: "state", value: { identity: orphan.slice(:payload, :provider_payment_intent_id,
    :provider_object_id, :provider_amount_cents, :provider_currency, :provider_livemode), found_by_identity: receipts.include?(orphan.id),
    replay: replay, orphan_items: orphan.reconciliation_exceptions.pluck(:code, :status, :payment_id),
    verify: S.verify_counts })

when "u_old_capture_on_legacy_sale"
  # The previous release acknowledges a second capture on the sale it
  # fulfilled before the upgrade (no fulfilling payment recorded).
  order = S.find(Order, "u_order")
  a = S.find(Payment, "u_a")
  b = order.payments.create!(provider: "stripe", provider_environment: "test", provider_platform_account_id: a.provider_platform_account_id,
    provider_payment_id: "pi_reh_u_b", idempotency_key: "second:#{order.id}:u_b", amount_cents: order.total_cents, currency: "usd",
    status: :pending)
  Payment.where(id: b.id).update_all(provider_environment: "live") # same mode as A
  S.attempt(step, "payment_intent.succeeded on legacy sale's B") do
    S.webhook!("payment_intent.succeeded", { id: b.provider_payment_id, amount: b.amount_cents, amount_received: b.amount_cents,
      currency: "usd", status: "succeeded" }, id: "evt_reh_u_b", livemode: true)
  end
  S.save!(u_b: b.id)
  Rehearsal.outcome!(step, action: "state", value: { receipt: S.receipt("evt_reh_u_b"), b: b.reload.slice(:status, :capture_recorded_at),
    exceptions: ReconciliationException.where(payment_id: b.id).count })

when "r13_hold_order_lock"
  # Lock contention: the previous release holds the legacy order's row lock
  # (as its refund or lifecycle writers do) while this release discovers.
  Order.transaction do
    S.find(Order, "u_order").lock!
    Rehearsal.pause("order_lock")
    sleep 2
  end
  Rehearsal.outcome!(step, action: "order lock released", value: Time.now.utc.iso8601(6))

when "u_new_discover_legacy_sale"
  order = S.find(Order, "u_order")
  a = S.find(Payment, "u_a")
  b = S.find(Payment, "u_b")
  before = S.verify_counts
  blocked = Commerce::NeverFulfilledPayoutHold.blocked?(order.event)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  report = S.attempt(step, "NeverFulfilledReconcile.call (legacy sale, under the old process's order lock)") do
    Commerce::NeverFulfilledReconcile.call(dry_run: false, payment_ids: [a.id, b.id]).assessments.map { |item| [item.payment_id, item.disposition] }
  end
  waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  Rehearsal.outcome!(step, action: "state", value: { verify_before: before, blocked_before: blocked, report: report,
    waited_seconds: waited.round(2), fulfilled_by: order.reload.fulfilled_by_payment_id, b: S.classification(b),
    a_classified: UnfulfilledCapture.exists?(payment_id: a.id), sale: S.money(order), verify_after: S.verify_counts })

when "r10_state"
  order = S.find(Order, "r10_order")
  Rehearsal.outcome!(step, action: "state", value: { total_cents: order.total_cents, sale: S.money(order),
    b: S.classification(S.find(Payment, "r10_b")) })

when "r10_refund_a"
  # Stripe's $6.60 refund on A, delivered to this process (twice in this release).
  a = S.find(Payment, "r10_a")
  (new_release ? 2 : 1).times do |delivery|
    S.attempt(step, "refund.created $6.60 on A (delivery #{delivery + 1})") { S.refund_notice!(a, "re_reh_r10_a", 660, id: "evt_reh_r10_a_refund") }
  end
  Rehearsal.outcome!(step, action: "state", value: { receipt: S.receipt("evt_reh_r10_a_refund"), sale: S.money(a.order),
    emails: nil })

when "r12_old_capture_b"
  key = ENV.fetch("REHEARSAL_KEY")
  b = S.find(Payment, "r12_#{key}_b")
  S.attempt(step, "payment_intent.succeeded on B (#{key})") { S.capture!(b, id: "evt_reh_r12_#{key}") }
  Rehearsal.outcome!(step, action: "state", value: { receipt: S.receipt("evt_reh_r12_#{key}"),
    b: b.reload.slice(:status, :capture_recorded_at), exceptions: ReconciliationException.where(payment_id: b.id).count })

when "r12_old_redact_receipt"
  key = ENV.fetch("REHEARSAL_KEY")
  WebhookEvent.where(provider_event_id: "evt_reh_r12_#{key}").update_all(payload: {}, last_error: nil, updated_at: Time.current)
  Rehearsal.outcome!(step, action: "redacted", value: WebhookEvent.find_by!(provider_event_id: "evt_reh_r12_#{key}")
    .slice(:payload, :provider_payment_intent_id, :provider_amount_cents, :provider_livemode))

when "r12_old_finalize"
  # 7bcd97c2's own checks see no exception on this event; its unrelated fee
  # precheck is set aside so only the database decides.
  Settlements::Finalizer.define_singleton_method(:open_money_blocker) { |_event| nil }
  S.attempt(step, "Settlements::Finalizer.call (event with unclassified captures)") do
    Settlements::Finalizer.call(event: S.find(Event, "r12_event"), actor: S.find(User, "admin"))
  end

when "r12_check_held"
  event = S.find(Event, "r12_event")
  S.attempt(step, "Settlements::Finalizer.call") { Settlements::Finalizer.call(event: event, actor: S.find(User, "admin")) }
  Rehearsal.outcome!(step, action: "state", value: { block_started_at: Commerce::NeverFulfilledPayoutHold.block_started_at(event)&.utc&.iso8601(6),
    b_capture_times: %w[x y].map { |key| S.find(Payment, "r12_#{key}_b").capture_recorded_at&.utc&.iso8601(6) },
    verify: S.verify_counts })

when "r12_new_redeliver"
  b = S.find(Payment, "r12_x_b")
  2.times do |delivery|
    S.attempt(step, "redelivered payment_intent.succeeded on B (x, delivery #{delivery + 1})") { S.capture!(b, id: "evt_reh_r12_x") }
  end
  Rehearsal.outcome!(step, action: "state", value: { receipt: S.receipt("evt_reh_r12_x"), b: S.classification(b),
    exceptions: ReconciliationException.where(payment_id: b.id).pluck(:code, :status), sale: S.money(b.order) })

when "r12_new_reconcile"
  b = S.find(Payment, "r12_y_b")
  dry = Commerce::NeverFulfilledReconcile.call(dry_run: true, payment_ids: [b.id]).assessments.map { |item| [item.disposition, item.reason] }
  S.attempt(step, "RefundReconciliationJob.perform_now (scheduled discovery)") { RefundReconciliationJob.perform_now }
  Rehearsal.outcome!(step, action: "state", value: { dry_run: dry, b: S.classification(b),
    exceptions: ReconciliationException.where(payment_id: b.id).pluck(:code, :status), sale: S.money(b.order), verify: S.verify_counts })

when "r12_refund_b"
  # Stripe's $5.00 refund on classified B (x), after classification.
  b = S.find(Payment, "r12_x_b")
  S.attempt(step, "refund.created $5.00 on classified B") { S.refund_notice!(b, "re_reh_r12_x_b", 500, id: "evt_reh_r12_x_b_refund") }
  Rehearsal.outcome!(step, action: "state", value: { receipt: S.receipt("evt_reh_r12_x_b_refund"), b: S.classification(b),
    sale: S.money(b.order) })

when "r12_old_late_return"
  # The previous release records a Stripe refund on an order-scope
  # classified capture (its order has no sale): written, never posted.
  p1 = S.find(Payment, "l1_payment")
  S.attempt(step, "refund.created $5.00 on classified order-scope capture") { S.refund_notice!(p1, "re_reh_l1_late", 500, id: "evt_reh_l1_late") }
  Rehearsal.outcome!(step, action: "state", value: { receipt: S.receipt("evt_reh_l1_late"), refunds: S.refund_rows(p1.order),
    postings: S.classification(p1)&.dig(:postings) })

when "r12_new_post_late_return"
  p1 = S.find(Payment, "l1_payment")
  before = S.verify_counts
  dry = Commerce::NeverFulfilledReconcile.call(dry_run: true, payment_ids: [p1.id]).assessments.map { |item| [item.disposition, item.reason] }
  S.attempt(step, "NeverFulfilledReconcile.call (post)") { Commerce::NeverFulfilledReconcile.call(dry_run: false, payment_ids: [p1.id]).counts }
  capture = UnfulfilledCapture.find_by!(payment_id: p1.id)
  Rehearsal.outcome!(step, action: "state", value: { verify_before: before, dry_run: dry, postings: S.classification(p1)[:postings],
    owed_cents: Commerce::BuyerReturnLedger.for(capture).owed_cents,
    holds: ReconciliationException.where(payment_id: p1.id).pluck(:code, :status), verify_after: S.verify_counts })

when "r14_old_capture_b", "r14_new_redeliver"
  # 7bcd97c2 receives B's success on the partially refunded marked order;
  # this release later receives the redelivery (twice).
  b = S.find(Payment, "r14_b")
  (new_release ? 2 : 1).times do |delivery|
    S.attempt(step, "payment_intent.succeeded on B (delivery #{delivery + 1})") { S.capture!(b, id: "evt_reh_r14_b") }
  end
  Rehearsal.outcome!(step, action: "state", value: { receipt: S.receipt("evt_reh_r14_b"), b: b.reload.slice(:status, :capture_recorded_at),
    order: b.order.slice(:status, :never_fulfilled_at, :refund_amount_cents),
    exceptions: ReconciliationException.where(payment_id: b.id).order(:id).pluck(:code, :status),
    hold_started_at: (ReconciliationException.where(payment_id: b.id).order(:id).pluck(:hold_started_at).map { |t| t&.utc&.iso8601(6) } if new_release),
    classification: S.classification(b),
    block_started_at: (Commerce::NeverFulfilledPayoutHold.block_started_at(b.order.event)&.utc&.iso8601(6) if new_release),
    money: S.money(b.order) })

when "r14_check_held"
  event = S.find(Event, "r14_event")
  b = S.find(Payment, "r14_b")
  b_start = ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array(["SELECT hafapass_overlap_hold_start(?)", b.id]))
  Rehearsal.outcome!(step, action: "state", value: { block_started_at: Commerce::NeverFulfilledPayoutHold.block_started_at(event)&.utc&.iso8601(6),
    b_hold_start: b_start && ActiveRecord::Type::DateTime.new.cast(b_start).utc.iso8601(6),
    b_capture_recorded_at: b.capture_recorded_at&.utc&.iso8601(6), verify: S.verify_counts })
  S.save!(r14_hold_before: Commerce::NeverFulfilledPayoutHold.block_started_at(event)&.utc&.iso8601(6))
  event.update_columns(status: Event.statuses.fetch("completed"))

when "r14_old_finalize", "r14_new_finalize"
  Settlements::Finalizer.define_singleton_method(:open_money_blocker) { |_event| nil } unless new_release
  S.attempt(step, "Settlements::Finalizer.call (marked order with B)") do
    Settlements::Finalizer.call(event: S.find(Event, "r14_event"), actor: S.find(User, "admin"))
  end

when "r14_new_repay_a"
  # A is repaid in full; A's own hold closes, B's stays.
  a = S.find(Payment, "r14_a")
  S.attempt(step, "refund.created for the rest of A") { S.refund_notice!(a, "re_reh_r14_a_rest", a.amount_cents - 500, id: "evt_reh_r14_a_rest") }
  Rehearsal.outcome!(step, action: "state", value: {
    holds: ReconciliationException.where(payment_id: [a.id, S.state.fetch("r14_b")], code: FinancialIntegrity::PAYOUT_BLOCKING_CODES)
      .order(:id).pluck(:payment_id, :code, :status),
    blocked: Commerce::NeverFulfilledPayoutHold.blocked?(a.order.event),
    block_started_at: Commerce::NeverFulfilledPayoutHold.block_started_at(a.order.event)&.utc&.iso8601(6),
    owed_b: Commerce::BuyerRepayment.availability(UnfulfilledCapture.find_by!(payment_id: S.state.fetch("r14_b"))).owed_cents,
    money: S.money(a.order) })

when "r15_old_capture_b"
  b = S.find(Payment, "r15_b")
  S.attempt(step, "payment_intent.succeeded on B (fulfilled sale)") { S.capture!(b, id: "evt_reh_r15_b") }
  Rehearsal.outcome!(step, action: "state", value: { receipt: S.receipt("evt_reh_r15_b"), b: b.reload.slice(:status, :capture_recorded_at),
    exceptions: ReconciliationException.where(payment_id: b.id).count })

when "r15_paid_gap"
  # The same during-gap transfer (after B's capture, before discovery), in
  # each release, before and after discovery (REHEARSAL_KEY).
  payout = S.find(Payout, "r15_sent")
  b = S.find(Payment, "r15_b")
  unless S.state["r15_gap"]
    sleep 0.05
    S.save!(r15_gap: (b.capture_recorded_at + ((Time.current - b.capture_recorded_at) / 2)).utc.iso8601(6))
  end
  gap = Time.iso8601(S.state.fetch("r15_gap"))
  S.attempt(step, "PayoutReconciler.call paid (#{ENV.fetch('REHEARSAL_KEY')} discovery, transfer #{gap.utc.iso8601(6)})") do
    PayoutReconciler.call(payout: payout.reload, actor: S.find(User, "admin"), status: "paid", provider_payout_id: "bank-reh-r15-gap",
      evidence: { reference: "Bank record", reason: "Transfer confirmed", confirmed_at: gap.utc.iso8601(6),
        approved_tax_payee_confirmed: true, approved_payee_confirmed: true, sent_before_hold_confirmed: true })
  end
  Rehearsal.outcome!(step, action: "state", value: { payout: payout.reload.slice(:status, :paid_at),
    block_started_at: (Commerce::NeverFulfilledPayoutHold.block_started_at(payout.event)&.utc&.iso8601(6) if new_release),
    b_capture_recorded_at: b.capture_recorded_at.utc.iso8601(6) })

when "r15_new_discover"
  event = S.find(Event, "r15_event")
  before = Commerce::NeverFulfilledPayoutHold.block_started_at(event)
  S.attempt(step, "RefundReconciliationJob.perform_now (scheduled discovery)") { RefundReconciliationJob.perform_now }
  b = S.find(Payment, "r15_b")
  Rehearsal.outcome!(step, action: "state", value: { before: before&.utc&.iso8601(6),
    after: Commerce::NeverFulfilledPayoutHold.block_started_at(event)&.utc&.iso8601(6), classification: S.classification(b),
    exceptions: ReconciliationException.where(payment_id: b.id).order(:id).map { |e| [e.code, e.created_at.utc.iso8601(6), e.hold_started_at&.utc&.iso8601(6)] } })

when "r15_new_paid_pre_hold"
  payout = S.find(Payout, "r15_sent")
  pre = Time.iso8601(S.state.fetch("r15_pre_hold"))
  S.attempt(step, "PayoutReconciler.call paid (pre-hold transfer #{pre.utc.iso8601(6)})") do
    PayoutReconciler.call(payout: payout.reload, actor: S.find(User, "admin"), status: "paid", provider_payout_id: "bank-reh-r15-pre",
      evidence: { reference: "Bank record", reason: "Transfer confirmed", confirmed_at: pre.utc.iso8601(6),
        approved_tax_payee_confirmed: true, approved_payee_confirmed: true, sent_before_hold_confirmed: true })
  end
  Rehearsal.outcome!(step, action: "state", value: { payout: payout.reload.slice(:status, :paid_at, :provider_payout_id),
    audit_hold: AuditLog.where(auditable: payout, action: "payout.reconciled").pluck(Arel.sql("metadata ->> 'never_fulfilled_hold_started_at'")) })

when "r16_old_capture"
  # 7bcd97c2 captures B on a fulfilled sale (REHEARSAL_KEY r16 or r16b); with
  # REHEARSAL_PAUSE=capture it stops inside the open capture transaction.
  key = ENV.fetch("REHEARSAL_KEY")
  b = S.find(Payment, "#{key}_b")
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  S.attempt(step, "payment_intent.succeeded on B (#{key})") { S.capture!(b, id: "evt_reh_#{key}_b") }
  Rehearsal.outcome!(step, action: "state", value: { seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2),
    b: b.reload.slice(:status, :capture_recorded_at), committed_at: Time.now.utc.iso8601(6) })

when "r16_submit"
  # Submission authorization and gateway call (REHEARSAL_KEY names the
  # payout), timed; then the gateway outcome, as each release records it.
  payout = S.find(Payout, ENV.fetch("REHEARSAL_KEY"))
  creator = PayoutCreator.new(settlement: payout.settlement, actor: S.find(User, "admin"), idempotency_key: payout.idempotency_key)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = S.attempt(step, "PayoutCreator#submit_payout! (#{ENV.fetch('REHEARSAL_KEY')})") { creator.send(:submit_payout!, payout) }
  seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)
  if result
    S.attempt(step, "record submission outcome (#{ENV.fetch('REHEARSAL_KEY')})") do
      creator.send(:record_submission_outcome!, payout, provider_payout_id: result.provider_payout_id, status: result.status,
        initiated_at: Time.current, paid_at: nil)
      payout.reload
    end
  end
  Rehearsal.outcome!(step, action: "state", value: { seconds: seconds, payout: payout.reload.slice(:status),
    submission_audit_at: AuditLog.where(auditable: payout, action: "payout.submission_requested").pick(:occurred_at)&.utc&.iso8601(6) })

when "r16_paid_during"
  # Paid recording with a transfer time after B1's (uncommitted) capture.
  payout = S.find(Payout, "r16_sent")
  confirmed_at = Time.current
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  S.attempt(step, "PayoutReconciler.call paid (transfer #{confirmed_at.utc.iso8601(6)}, capture in flight)") do
    PayoutReconciler.call(payout: payout.reload, actor: S.find(User, "admin"), status: "paid", provider_payout_id: "bank-reh-r16-#{Rehearsal::ROLE}",
      evidence: { reference: "Bank record", reason: "Transfer confirmed", confirmed_at: confirmed_at.utc.iso8601(6),
        approved_tax_payee_confirmed: true, approved_payee_confirmed: true, sent_before_hold_confirmed: true })
  end
  Rehearsal.outcome!(step, action: "state", value: { seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2),
    payout: payout.reload.slice(:status, :paid_at) })

when "r16_state"
  rows = %w[r16 r16_other r16b].to_h do |key|
    event = S.find(Event, "#{key}_event")
    b = S.find(Payment, "#{key}_b")
    [key, { block_started_at: Commerce::NeverFulfilledPayoutHold.block_started_at(event)&.utc&.iso8601(6),
      b: b.slice(:status, :capture_recorded_at), payouts: event.payouts.order(:id).pluck(:id, :status),
      submissions: AuditLog.where(auditable_type: "Payout", auditable_id: event.payouts.select(:id), action: "payout.submission_requested")
        .order(:id).pluck(:auditable_id, :occurred_at) }]
  end
  Rehearsal.outcome!(step, action: "state", value: rows)

when "r16_discover"
  S.attempt(step, "RefundReconciliationJob.perform_now (scheduled discovery)") { RefundReconciliationJob.perform_now }
  Rehearsal.outcome!(step, action: "state", value: %w[r16 r16b].to_h { |key|
    b = S.find(Payment, "#{key}_b")
    [key, { classification: S.classification(b), holds: ReconciliationException.where(payment_id: b.id).pluck(:code, :hold_started_at)
      .map { |code, at| [code, at&.utc&.iso8601(6)] }, block_started_at: Commerce::NeverFulfilledPayoutHold.block_started_at(b.order.event)&.utc&.iso8601(6) }]
  })

when "u_existing_r17"
  raise "existing data comes from the previous release" if new_release

  saved = %w[r17c r17b].each_with_object({}) do |key, values|
    event, order, a, user = F.legacy_settled_sale!(key)
    values.merge!("#{key}_event" => event.id, "#{key}_order" => order.id, "#{key}_a" => a.id, "#{key}_user" => user.id)
  end
  S.save!(**saved)
  Rehearsal.outcome!(step, action: "legacy sales", value: saved)

when "r17_old_capture"
  # 7bcd97c2 acknowledges B or C on its own legacy sale. C's notice carries
  # no mode, which 7bcd97c2 accepts outside production and this release
  # cannot prove from the receipt.
  key = ENV.fetch("REHEARSAL_KEY")
  which = ENV.fetch("REHEARSAL_PAYMENT")
  payment = S.find(Payment, "#{key}_#{which}")
  object = { id: payment.provider_payment_id, amount: payment.amount_cents, amount_received: payment.amount_cents, currency: "usd",
    status: "succeeded" }
  S.attempt(step, "payment_intent.succeeded on #{which.upcase} (#{key})") do
    S.webhook!("payment_intent.succeeded", object, id: "evt_reh_#{key}_#{which}", livemode: which == "b" ? false : nil)
  end
  Rehearsal.outcome!(step, action: "state", value: { key: key, payment: which, receipt: S.receipt("evt_reh_#{key}_#{which}"),
    captured: payment.reload.slice(:status, :capture_recorded_at), exceptions: ReconciliationException.where(payment_id: payment.id).count })

when "r17_paid_gap"
  # The same transfer, made between B's and C's captures, in each release
  # after each step (REHEARSAL_PHASE).
  key = ENV.fetch("REHEARSAL_KEY")
  payout = S.find(Payout, "#{key}_sent")
  b = S.find(Payment, "#{key}_b")
  unless S.state["#{key}_gap"]
    sleep 0.05
    S.save!("#{key}_gap" => (b.capture_recorded_at + ((Time.current - b.capture_recorded_at) / 2)).utc.iso8601(6))
  end
  gap = Time.iso8601(S.state.fetch("#{key}_gap"))
  S.attempt(step, "PayoutReconciler.call paid (#{key} #{ENV.fetch('REHEARSAL_PHASE')}, transfer #{gap.utc.iso8601(6)})") do
    PayoutReconciler.call(payout: payout.reload, actor: S.find(User, "admin"), status: "paid", provider_payout_id: "bank-reh-#{key}-gap",
      evidence: { reference: "Bank record", reason: "Transfer confirmed", confirmed_at: gap.utc.iso8601(6),
        approved_tax_payee_confirmed: true, approved_payee_confirmed: true, sent_before_hold_confirmed: true })
  end
  Rehearsal.outcome!(step, action: "state", value: { key: key, phase: ENV.fetch("REHEARSAL_PHASE"), payout: payout.reload.slice(:status, :paid_at),
    block_started_at: (Commerce::NeverFulfilledPayoutHold.block_started_at(payout.event)&.utc&.iso8601(6) if new_release),
    b_capture_recorded_at: b.capture_recorded_at.utc.iso8601(6), c_capture_recorded_at: S.find(Payment, "#{key}_c").capture_recorded_at&.utc&.iso8601(6) })

when "r17_discover"
  key = ENV.fetch("REHEARSAL_KEY")
  payment = S.find(Payment, "#{key}_#{ENV.fetch('REHEARSAL_PAYMENT')}")
  ids = %w[a b c].map { |which| S.state.fetch("#{key}_#{which}") }
  overlap = -> { Commerce::NeverFulfilledReconcile.overlap_capture_ids & ids }
  before = overlap.call
  report = S.attempt(step, "NeverFulfilledReconcile.call (#{key} #{ENV.fetch('REHEARSAL_PAYMENT').upcase})") do
    Commerce::NeverFulfilledReconcile.call(dry_run: false, payment_ids: [payment.id]).assessments.map { |item| [item.payment_id, item.disposition, item.reason] }
  end
  Rehearsal.outcome!(step, action: "state", value: { key: key, report: report, overlap_before: before, overlap_after: overlap.call,
    fulfilled_by: payment.order.reload.fulfilled_by_payment_id,
    block_started_at: Commerce::NeverFulfilledPayoutHold.block_started_at(payment.order.event)&.utc&.iso8601(6),
    holds: ReconciliationException.where(payment_id: ids, code: FinancialIntegrity::PAYOUT_BLOCKING_CODES).order(:id)
      .map { |item| [item.payment_id, item.code, item.status, item.hold_started_at&.utc&.iso8601(6), item.details["reason"]] } })

when "r17_paid_pre_hold"
  key = ENV.fetch("REHEARSAL_KEY")
  payout = S.find(Payout, "#{key}_sent")
  pre = Time.iso8601(S.state.fetch("#{key}_pre_hold"))
  S.attempt(step, "PayoutReconciler.call paid (#{key} pre-hold transfer #{pre.utc.iso8601(6)})") do
    PayoutReconciler.call(payout: payout.reload, actor: S.find(User, "admin"), status: "paid", provider_payout_id: "bank-reh-#{key}-pre",
      evidence: { reference: "Bank record", reason: "Transfer confirmed", confirmed_at: pre.utc.iso8601(6),
        approved_tax_payee_confirmed: true, approved_payee_confirmed: true, sent_before_hold_confirmed: true })
  end
  Rehearsal.outcome!(step, action: "state", value: { key: key, payout: payout.reload.slice(:status, :paid_at, :provider_payout_id),
    audit_hold: AuditLog.where(auditable: payout, action: "payout.reconciled").pluck(Arel.sql("metadata ->> 'never_fulfilled_hold_started_at'")) })

when "verify_task"
  output = `bin/rails never_fulfilled:verify 2>&1`
  Rehearsal.outcome!(step, action: "never_fulfilled:verify", value: output.lines.map(&:strip))

when "assertions"
  checks = {}
  check = ->(name, actual, expected) { checks[name] = { pass: actual == expected, actual: actual, expected: expected } }
  r10 = S.find(Order, "r10_order").reload
  check.call("blocker1: A's sale partially refunded by its own $6.60 only",
    [r10.status, r10.refund_amount_cents, r10.tickets.pluck(:status).uniq], ["partially_refunded", 660, ["issued"]])
  check.call("blocker1: refunds A $6.60 once, B $7.00", Refund.where(order_id: r10.id, status: :succeeded).order(:id).pluck(:payment_id, :amount_cents),
    [[S.state.fetch("r10_b"), 700], [S.state.fetch("r10_a"), 660]])
  check.call("blocker1: A's refund items $6.60, no inventory retention",
    [RefundItem.joins(:refund).where(refunds: { order_id: r10.id }).sum(:amount_cents),
      TicketInventoryRetention.joins(:ticket).where(tickets: { order_id: r10.id }).count], [660, 0])
  check.call("blocker1: one commission reversal", r10.promoter_commission_entries.order(:id).pluck(:kind), %w[earned refund_reversal])
  hold_at = Time.iso8601(S.state.fetch("hold_at"))
  first = S.find(Payout, "payout_first")
  check.call("blocker2: pre-hold transfer recorded paid by this release, before the hold",
    [first.status, first.paid_at.present? && first.paid_at < hold_at], ["paid", true])
  check.call("blocker2: paid audit carries the hold and the confirmation",
    AuditLog.where(auditable: first, action: "payout.reconciled").map { |a| [a.metadata.key?("never_fulfilled_hold_started_at"), a.metadata.dig("reconciliation", "sent_before_hold_confirmed")] },
    [[true, true]])
  check.call("blocker2: never-submitted payout stays held, never paid or released",
    [S.find(Payout, "payout_second").status, AuditLog.where(auditable: S.find(Payout, "payout_second"), action: %w[payout.paid payout.reconciled payout.released_from_cancellation_hold]).count],
    ["held", 0])
  %w[x y].each do |key|
    b = S.find(Payment, "r12_#{key}_b")
    receipt = WebhookEvent.find_by!(provider_event_id: "evt_reh_r12_#{key}")
    info = S.classification(b)
    check.call("blocker3: B (#{key}) classified in payment scope from the old receipt",
      info&.values_at(:scope, :code, :webhook_event_id, :receipt_status), ["payment", "unfulfilled_second_capture", receipt.id, "processed"])
  end
  check.call("blocker3: redacted receipt proven from its kept identity", S.classification(S.find(Payment, "r12_y_b"))[:receipt_facts], "stored_identity")
  check.call("blocker3: B (x) refund after classification posted on B", S.classification(S.find(Payment, "r12_x_b"))[:postings],
    [["refund", 500, 500, 0]])
  check.call("blocker3: A's sales untouched", %w[x y].map { |key| S.find(Order, "r12_#{key}_order").reload.slice(:status, :refund_amount_cents).values },
    [["completed", 0], ["completed", 0]])
  check.call("blocker3: legacy return on an order-scope capture posted", S.classification(S.find(Payment, "l1_payment"))[:postings].map(&:first), ["refund"])
  check.call("upgrade: legacy sale's fulfilling payment recovered, B classified",
    [S.find(Order, "u_order").reload.fulfilled_by_payment_id, S.classification(S.find(Payment, "u_b"))&.fetch(:scope)], [S.state.fetch("u_a"), "payment"])
  check.call("upgrade: redacted orphan keeps its identity and binds to the payment it names",
    [WebhookEvent.find_by!(provider_event_id: "evt_reh_orphan").provider_payment_intent_id,
      ReconciliationException.joins(:webhook_event).where(webhook_events: { provider_event_id: "evt_reh_orphan" }).pluck(:payment_id, :status)],
    ["pi_reh_orphan", [[S.state.fetch("orphan_payment"), "open"]]])
  check.call("upgrade: orphan cleared before the upgrade is reported for finance", S.verify_counts[:orphans_without_identity], 1)
  check.call("verify: no overlap captures or unposted movements left", S.verify_counts.slice(:overlap, :unposted), { overlap: [], unposted: [] })
  # Boundary fixes (§6.9). Outcomes by step and process, from outcomes.jsonl.
  rows = File.readlines(File.join(Rehearsal::DIR, "outcomes.jsonl")).map { |line| JSON.parse(line) }
  pick = ->(role, name, action = nil) { rows.select { |row| row["role"] == role && row["step"] == name && (action.nil? || row["action"].start_with?(action)) } }
  r14_old = pick.call("old", "r14_old_capture_b", "state").last["value"]
  check.call("fix1: 7bcd97c2 acknowledged B on the partially refunded marked order without an exception",
    [r14_old.dig("receipt", "status"), r14_old.dig("b", "status"), r14_old["exceptions"], r14_old.dig("order", "status")],
    ["processed", "succeeded", [], "partially_refunded"])
  held = pick.call("new", "r14_check_held", "state").last["value"]
  check.call("fix1: held from B's capture before discovery, and counted by verify",
    [held["b_hold_start"] == held["b_capture_recorded_at"], held["block_started_at"] <= held["b_capture_recorded_at"],
      held.dig("verify", "overlap"), held.dig("verify", "pending").map { |row| row[0..1] }],
    [true, true, [S.state.fetch("r14_b")], [[S.state.fetch("r14_b"), "discover"]]])
  check.call("fix1: both finalizers refused while B holds the event",
    (pick.call("old", "r14_old_finalize") + pick.call("new", "r14_new_finalize")).map { |row| row["result"] }, %w[refused refused refused])
  b14 = S.find(Payment, "r14_b")
  b14_issue = ReconciliationException.where(payment_id: b14.id).order(:id).first
  check.call("fix1: redelivery classified B in order scope from the old receipt, once",
    [S.classification(b14)&.values_at(:scope, :code, :provenance, :webhook_event_id), UnfulfilledCapture.where(payment_id: b14.id).count,
      ReconciliationException.where(payment_id: b14.id).count],
    [["order", "late_payment_success_after_inventory_release", "lifecycle", WebhookEvent.find_by!(provider_event_id: "evt_reh_r14_b").id], 1, 1])
  check.call("fix1: B's hold keeps B's capture as its start", b14_issue.hold_started_at&.utc&.iso8601(6), b14.capture_recorded_at.utc.iso8601(6))
  repaid = pick.call("new", "r14_new_repay_a", "state").last["value"]
  check.call("fix1: A repaid and closed, B still owed and holding the event from its own capture",
    [repaid["holds"].map { |row| row[2] }, repaid["blocked"], repaid["block_started_at"], repaid["owed_b"], repaid.dig("money", "status"),
      repaid.dig("money", "tickets")],
    [%w[resolved open], true, b14.capture_recorded_at.utc.iso8601(6), b14.amount_cents, "refunded", []])
  gaps = pick.call("new", "r15_paid_gap", "PayoutReconciler") + pick.call("old", "r15_paid_gap", "PayoutReconciler")
  check.call("fix2: the same during-gap transfer refused before and after discovery, in both releases",
    gaps.map { |row| [row["role"], row["action"][/(before|after)/], row["result"]] }.sort,
    [%w[new after refused], %w[new before refused], %w[old after refused], %w[old before refused]])
  discovered = pick.call("new", "r15_new_discover", "state").last["value"]
  check.call("fix2: discovery keeps the hold start at B's capture",
    [discovered["before"] == discovered["after"], discovered["exceptions"].map(&:last).uniq == [discovered["before"]],
      discovered.dig("classification", "scope")], [true, true, "payment"])
  r15 = S.find(Payout, "r15_sent")
  check.call("fix2: the pre-hold transfer is recorded paid, with the original hold start in its audit",
    [r15.status, r15.paid_at.utc.iso8601(6), AuditLog.where(auditable: r15, action: "payout.reconciled").pluck(Arel.sql("metadata ->> 'never_fulfilled_hold_started_at'"))],
    ["paid", S.state.fetch("r15_pre_hold"), [discovered["before"]]])
  old_submit = pick.call("old", "r16_submit", "PayoutCreator#submit_payout! (r16_pending)").sole
  old_paid = pick.call("old", "r16_paid_during", "PayoutReconciler").sole
  check.call("fix3: 7bcd97c2's submission and paid recording refused at once during the capture",
    [old_submit.values_at("result", "error"), old_paid.values_at("result", "error"),
      [old_submit, old_paid].all? { |row| row["message"].include?("in progress") }],
    [%w[refused ActiveRecord::LockWaitTimeout], %w[refused ActiveRecord::LockWaitTimeout], true])
  new_submit = pick.call("new", "r16_submit", "state").select { |row| row["value"]["payout"]["status"] != "processing" }
  new_rows = pick.call("new", "r16_submit", "PayoutCreator#submit_payout! (r16_pending)").sole
  new_paid = pick.call("new", "r16_paid_during")
  check.call("fix3: this release's submission and paid recording waited for the capture, then refused",
    [new_rows.values_at("result", "error"), new_submit.map { |row| row["value"]["seconds"] >= 1.0 },
      new_paid.find { |row| row["action"].start_with?("PayoutReconciler") }.values_at("result", "error"),
      new_paid.find { |row| row["action"] == "state" }["value"]["seconds"] >= 1.0],
    [%w[refused PayoutCreator::PayoutError], [true], %w[refused PayoutReconciler::ReconciliationError], true])
  r16_state = pick.call("new", "r16_state", "state").last["value"]
  check.call("fix3: unrelated event's payout submitted during the capture; B1's event payouts unchanged",
    [r16_state.dig("r16_other", "payouts").map(&:last), r16_state.dig("r16", "payouts").map(&:last)],
    [["processing"], %w[pending processing]])
  first = pick.call("old", "r16_old_capture", "state").select { |row| row["value"]["b"]["status"] == "succeeded" }.last["value"]
  b2 = S.find(Payment, "r16b_b")
  b2_audit = AuditLog.where(auditable_type: "Payout", auditable_id: S.state.fetch("r16b_pending"), action: "payout.submission_requested").sole
  check.call("fix3: payout first: 7bcd97c2's capture waited for its submission, which is recorded as pre-hold",
    [first["seconds"] >= 1.0, b2.capture_recorded_at > b2_audit.occurred_at, S.find(Payout, "r16b_pending").status],
    [true, true, "processing"])
  check.call("fix3: the held payout on B1's event never reached the gateway", File.readlines(File.join(Rehearsal::DIR, "calls.jsonl"))
    .map { |line| JSON.parse(line) }.select { |call| call["kind"] == "payout_submit" }.map { |call| call["payout_id"] }
    .include?(S.state.fetch("r16_pending")), false)
  # Upgrade cutoff (2f961e48 recheck): r17c discovers C first, r17b B first.
  %w[r17c r17b].each do |key|
    a, b, c = %w[a b c].map { |which| S.find(Payment, "#{key}_#{which}") }
    t1 = b.capture_recorded_at.utc.iso8601(6)
    gap_rows = rows.select { |row| row["step"] == "r17_paid_gap" && row["action"].start_with?("PayoutReconciler") && row["action"].include?("(#{key} ") }
    check.call("cutoff #{key}: the same transfer between B and C refused after B, after C and after each discovery, in both releases",
      gap_rows.map { |row| [row["role"], row["action"][/(after_\w+)/], row["result"]] }.sort,
      %w[old new].product(%w[after_b after_c after_first after_second]).map { |role, phase| [role, phase, "refused"] }.sort)
    gap_states = rows.select { |row| row["role"] == "new" && row["step"] == "r17_paid_gap" && row["action"] == "state" && row.dig("value", "key") == key }
    check.call("cutoff #{key}: block start stays at B's capture through C and discovery",
      [gap_states.map { |row| row.dig("value", "block_started_at") }.uniq, a.capture_recorded_at,
        gap_states.all? { |row| row.dig("value", "c_capture_recorded_at").nil? || row.dig("value", "c_capture_recorded_at") > S.state.fetch("#{key}_gap") }],
      [[t1], nil, true])
    found = rows.select { |row| row["step"] == "r17_discover" && row["action"] == "state" && row.dig("value", "key") == key }
    check.call("cutoff #{key}: one payment's item never hides the other; both discovered",
      found.map { |row| [Array(row.dig("value", "report")).map { |item| item[1..2] }, row.dig("value", "overlap_after"), row.dig("value", "block_started_at")] },
      key == "r17c" ? [[[["quarantine", "receipt_mode_mismatch"]], [b.id], t1], [[["discover", nil]], [], t1]] :
        [[[["discover", nil]], [c.id], t1], [[["quarantine", "receipt_mode_mismatch"]], [], t1]])
    holds = ReconciliationException.where(payment_id: [b.id, c.id], code: FinancialIntegrity::PAYOUT_BLOCKING_CODES).order(:id)
    check.call("cutoff #{key}: A recovered as the sale, B classified, C quarantined, the first item keeps B's capture",
      [S.find(Order, "#{key}_order").reload.fulfilled_by_payment_id, S.classification(b)&.values_at(:scope, :code), S.classification(c),
        holds.where(payment_id: c.id).pluck(:code), holds.first.hold_started_at.utc.iso8601(6)],
      [a.id, %w[payment unfulfilled_second_capture], nil, [Commerce::NeverFulfilledClassification::QUARANTINE_CODE], t1])
    sent = S.find(Payout, "#{key}_sent")
    check.call("cutoff #{key}: the pre-hold transfer is recorded paid with B's capture as the hold start",
      [sent.status, sent.paid_at.utc.iso8601(6), AuditLog.where(auditable: sent, action: "payout.reconciled").pluck(Arel.sql("metadata ->> 'never_fulfilled_hold_started_at'"))],
      ["paid", S.state.fetch("#{key}_pre_hold"), [t1]])
  end
  baseline, upgraded = %w[baseline upgraded].map { |tag| JSON.parse(File.read(File.join(Rehearsal::DIR, "exports_#{tag}.json"))) }
  check.call("upgrade: CPA rows identical before and after the migration", upgraded["cpa"], baseline["cpa"])
  check.call("upgrade: BPT rows identical before and after the migration", upgraded["bpt"], baseline["bpt"])
  checks.each { |name, result| Rehearsal.outcome!(step, action: name, result: result[:pass] ? "PASS" : "FAIL", value: result.except(:pass)) }
  File.write(File.join(Rehearsal::DIR, "assertions.txt"), checks.map { |name, result| "#{result[:pass] ? 'PASS' : 'FAIL'} #{name}" }.join("\n") + "\n")

when "payout_history"
  rows = AuditLog.where(auditable_type: "Payout").where("action LIKE 'payout.%'").order(:id)
    .pluck(:auditable_id, :action, :outcome)
  Rehearsal.outcome!(step, action: "payout transitions", value: rows)

else
  raise ArgumentError, "unknown rehearsal step #{step}"
end
