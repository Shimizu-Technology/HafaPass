# frozen_string_literal: true

# One step of the A2 overlap rehearsal (rehearse_a2_overlap.sh), run as
#   REHEARSAL_DIR=... REHEARSAL_ROLE=old|new bin/rails runner <this file> <step>
# in the merged A1 app ("old", a0b25ffe) or this release ("new"), against one
# task-owned database. Stripe and the payout gateway are the two-process
# rehearsal's stubs (every payout submission is logged with its role). Each
# step records what happened in outcomes.jsonl. Fixture IDs are shared
# through state.json. Fictional data only; every fixture is built by the
# old release before the upgrade, so factory sequences never collide.
require_relative "../two_process/stubs"
require "csv"

Object.const_set(:RSpec, Module.new { def self.configure(*) = nil }) unless defined?(::RSpec)
require Rails.root.join("spec/support/payout_statement_helpers").to_s
require Rails.root.join("spec/support/never_fulfilled_return_helpers").to_s

module A2Step
  STATE = File.join(Rehearsal::DIR, "state.json")
  extend FactoryBot::Syntax::Methods
  extend PayoutStatementHelpers
  extend NeverFulfilledReturnHelpers

  module_function

  def state = File.exist?(STATE) ? JSON.parse(File.read(STATE)) : {}
  def save!(values) = File.write(STATE, JSON.pretty_generate(state.merge(values.transform_keys(&:to_s))))
  def find(model, key) = model.find(state.fetch(key))
  def admin = find(User, "admin")
  def new_release? = Rehearsal::ROLE == "new"

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

  def webhook!(type, object, id:, livemode: false)
    payload = { "id" => id, "type" => type, "created" => Time.now.to_i, "livemode" => livemode,
      "data" => { "object" => object.deep_stringify_keys } }
    StripeWebhookProcessor.call(event: Stripe::Event.construct_from(payload), payload: payload)
  end

  def capture!(payment, id:)
    webhook!("payment_intent.succeeded", { id: payment.provider_payment_id, amount: payment.amount_cents,
      amount_received: payment.amount_cents, currency: "usd", status: "succeeded" }, id: id)
  end

  def evidence(confirmed_at, **flags)
    { reference: "Bank transfer record", reason: "Transfer confirmed by the bank", confirmed_at: confirmed_at.utc.iso8601(6),
      approved_tax_payee_confirmed: true, approved_payee_confirmed: true }.merge(flags)
  end

  def record_paid(step, key, confirmed_at, label, **flags)
    payout = find(Payout, key)
    attempt(step, "PayoutReconciler paid #{key} (#{label})") do
      PayoutReconciler.call(payout: payout.reload, actor: admin, status: "paid",
        provider_payout_id: "bank-a2-#{payout.id}-#{Rehearsal::ROLE}", evidence: evidence(confirmed_at, **flags)).reload
    end
  end

  def finalize(step, key)
    attempt(step, "Settlements::Finalizer #{key}") { Settlements::Finalizer.call(event: find(Event, key), actor: admin) }
  end

  def submitted(event, key, amount)
    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "a2-#{key}", amount_cents: amount).tap do |payout|
      save!("payout_#{key}" => payout.id)
    end
  end

  def reserved(event, key, amount)
    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    PayoutCreator.new(settlement: settlement, actor: admin, idempotency_key: "a2-#{key}", amount_cents: amount)
      .send(:reserve!).first.tap { |payout| save!("payout_#{key}" => payout.id) }
  end

  def verified_processing!(order, payment, cents)
    component = create(:fee_component, order: order, order_item: order.order_items.first, kind: "processing",
      amount_cents: cents, estimated: false, provider_reference: "txn_a2_#{payment.id}")
    create(:stripe_fee_evidence, :verified, payment: payment, fee_component: component,
      provider_balance_transaction_id: component.provider_reference)
  end

  def completed_event!(organization, profile, title)
    create(:event, :completed, organization: organization, organizer_profile: profile, title: title)
  end

  # An online sale paid by A with its fulfilling payment recorded, and a
  # pending second payment B on the same order (A1 classifies B's capture
  # in payment scope and holds the event).
  def sale_with_second!(event, key)
    type = create(:ticket_type, event: event, price_cents: 2000, quantity_available: 50, quantity_sold: 0)
    order, _item, a = record_card_sale!(event, ticket_type: type, quantity: 5, processing_fee_cents: 100)
    order.update!(fulfilled_by_payment_id: a.id)
    b = order.payments.create!(provider: "stripe", provider_environment: "test", provider_payment_id: "pi_a2_#{key}_b",
      idempotency_key: "a2:#{key}:b", amount_cents: 1500, currency: "usd", status: :pending)
    [order, a, b]
  end

  def exports!(tag)
    month = Time.current.in_time_zone("Pacific/Guam")
    period = format("%04d-%02d", month.year, month.month)
    dir = File.join(Rehearsal::DIR, "exports", tag)
    FileUtils.mkdir_p(dir)
    cpa = CpaMonthlyReport.new(month.year, month.month)
    File.write(File.join(dir, "cpa-#{period}.csv"),
      CSV.generate { |csv| csv << CpaMonthlyReport::HEADER.map(&:to_s); cpa.csv_rows.each { |row| csv << row.map(&:to_s) } })
    bpt = TaxReports.new(month.year).bpt_event_rows(month.month).to_a
    File.write(File.join(dir, "bpt-#{period}.csv"), CSV.generate do |csv|
      csv << Api::V1::Admin::TaxReportsController::BPT_EVENT_HEADER
      bpt.each { |organization_id, event_id, *amounts| csv << [period, organization_id, event_id, *amounts.map { |v| FinanceExports.money(v) }, "USD"] }
    end)
    # The annual organizer view's payout population, as this process's
    # release reads it (A2 recheck finding 5): { organization_id => net_paid_cents }.
    annual = TaxReports.new(month.year).organizers.group_by { |row| row[:organization_id] }
      .transform_values { |rows| rows.sum { |row| row[:net_paid_cents] } }.sort.to_h
    File.write(File.join(dir, "annual-organizers-#{month.year}.json"), JSON.generate(annual))
    { dir: dir, annual: annual, files: Dir[File.join(dir, "*.csv")].sort.to_h { |path| [File.basename(path), Digest::SHA256.file(path).hexdigest] } }
  end

  def payouts(key)
    find(Event, key).payouts.order(:id).map do |payout|
      [payout.id, payout.status, payout.amount_cents, payout.settlement.version, payout.paid_at&.utc&.iso8601(6),
        new_release? && PayoutCustodyDetermination.find_by(payout_id: payout.id)&.slice(:determination, :basis)]
    end
  end
end

S = A2Step
step = ARGV.fetch(0)

case step
when "u_a1_data"
  # The merged A1 release (a0b25ffe) on its own schema, before the upgrade.
  raise "the A1 data is written by the previous release" if S.new_release?

  SiteSetting.instance.update!(payment_mode: "test")
  admin = S.create(:user, :admin, clerk_id: "clerk_a2_admin", email: "rehearsal.a2.admin@example.com")
  owner = S.create(:user, :organizer, clerk_id: "clerk_a2_owner", email: "rehearsal.a2.owner@example.com")
  organization = S.create(:organization, name: "Rehearsal A2 Organization")
  profile = S.create(:organizer_profile, :verified, user: owner, organization: organization)
  S.save!(admin: admin.id, organization: organization.id)
  S.approved_bank_account!(organization, actor: owner, admin: admin)

  # Affected: a fulfilled sale, then an order-scope classified capture
  # (repaid; no open item), finalized and paid out by A1.
  aff = S.completed_event!(organization, profile, "Rehearsal A2 Affected")
  S.save!(aff: aff.id)
  type = S.create(:ticket_type, event: aff, price_cents: 2000, quantity_available: 50, quantity_sold: 0)
  _sale, _item, sale_payment = S.record_card_sale!(aff, ticket_type: type, quantity: 5, processing_fee_cents: 100)
  # Live Stripe custody, so frozen custody names it.
  Payment.where(id: sale_payment.id).update_all(provider_environment: "live", provider_payment_id: "pi_live_a2_aff_sale")
  order, c1, = S.classified_capture(items: [[1200, 160, 0, 0]], event: aff, intent: "pi_a2_c1")
  S.verified_processing!(order, c1, 69)
  S.save!(c1: c1.id)
  early = S.submitted(aff, "aff_early", 1000)
  S.record_paid("u_a1_data", "payout_aff_early", Time.current, "A1 early paid, before the upgrade")
  S.submitted(aff, "aff_sent", 2000)
  S.reserved(aff, "aff_pend", 3000)
  held = S.reserved(aff, "aff_held", nil)
  held.update!(status: :held, held_from_status: "pending")

  # Not affected: no classified capture.
  plain = S.completed_event!(organization, profile, "Rehearsal A2 Plain")
  S.save!(plain: plain.id)
  plain_type = S.create(:ticket_type, event: plain, price_cents: 2000, quantity_available: 50, quantity_sold: 0)
  S.record_card_sale!(plain, ticket_type: plain_type, quantity: 5, processing_fee_cents: 100)
  S.submitted(plain, "plain_sent", 2000)
  S.reserved(plain, "plain_held", 1000).update!(status: :held, held_from_status: "pending")
  S.reserved(plain, "plain_pend", 500)

  # R2-2 named example (E14 form): a payout funded only by non-custodial
  # sales (test-mode card), paid by A1; a live Stripe capture on the same
  # event comes later, after the upgrade.
  r22 = S.completed_event!(organization, profile, "Rehearsal A2 R2-2")
  S.save!(r22: r22.id)
  r22_type = S.create(:ticket_type, event: r22, price_cents: 2000, quantity_available: 50, quantity_sold: 0)
  S.record_card_sale!(r22, ticket_type: r22_type, quantity: 5, processing_fee_cents: 100)
  S.submitted(r22, "r22_paid", 1000)
  S.record_paid("u_a1_data", "payout_r22_paid", Time.current, "A1 paid, before the upgrade")
  later = S.create(:order, :pending, event: r22, subtotal_cents: 1200, service_fee_cents: 0, total_cents: 1200,
    buyer_email: "rehearsal.a2.later@example.com")
  S.create(:order_item, order: later, ticket_type: r22_type, unit_price_cents: 1200, quantity: 1, subtotal_cents: 1200,
    organizer_proceeds_cents: 1200, fee_cents: 0)
  later_payment = later.payments.create!(provider: "stripe", provider_environment: "live", provider_payment_id: "pi_live_a2_r22",
    idempotency_key: "a2:r22:later", amount_cents: 1200, currency: "usd", status: :pending)
  S.save!(r22_later_order: later.id, r22_later_payment: later_payment.id)

  # Review finding 1: an affected event with a live sale and a repaid
  # classified capture and no payouts yet; A2 approves payouts on it, then an
  # ordinary refund changes the statement.
  ord = S.completed_event!(organization, profile, "Rehearsal A2 Ordinary change")
  S.save!(ord: ord.id)
  ord_type = S.create(:ticket_type, event: ord, price_cents: 2000, quantity_available: 50, quantity_sold: 0)
  ord_sale, ord_item, ord_payment = S.record_card_sale!(ord, ticket_type: ord_type, quantity: 5, processing_fee_cents: 100)
  Payment.where(id: ord_payment.id).update_all(provider_environment: "live", provider_payment_id: "pi_live_a2_ord_sale")
  ord_order, ord_c, = S.classified_capture(items: [[1200, 160, 0, 0]], event: ord, intent: "pi_a2_ord_c")
  S.verified_processing!(ord_order, ord_c, 69)
  S.save!(ord_sale: ord_sale.id, ord_item: ord_item.id, ord_payment: ord_payment.id)

  # Review finding 3: an adjustment-only payout (its version funds no sale
  # line) on an event with no sale, paid by A1 before the upgrade.
  adj = S.completed_event!(organization, profile, "Rehearsal A2 Adjustment only")
  S.save!(adj: adj.id)
  organization.balance_adjustments.create!(event: adj, kind: "manual_credit", amount_cents: 500, currency: "usd",
    status: :posted, reason: "Rehearsal credit", effective_at: Time.current, created_by_user: admin)
  S.submitted(adj, "adj_paid", 500)
  S.record_paid("u_a1_data", "payout_adj_paid", Time.current, "A1 paid adjustment-only, before the upgrade")

  # Capture races: two events with a fulfilled sale and a pending second
  # payment B each, in their own organization (an open hold holds the whole
  # organization's balance).
  race_owner = S.create(:user, :organizer, clerk_id: "clerk_a2_race_owner", email: "rehearsal.a2.race@example.com")
  race_organization = S.create(:organization, name: "Rehearsal A2 Race Organization")
  race_profile = S.create(:organizer_profile, :verified, user: race_owner, organization: race_organization)
  S.approved_bank_account!(race_organization, actor: race_owner, admin: admin, last_four: "5555")
  %w[race race2].each do |key|
    event = S.completed_event!(race_organization, race_profile, "Rehearsal A2 #{key}")
    S.save!(key => event.id)
    _order, _a, b = S.sale_with_second!(event, key)
    S.save!("#{key}_b" => b.id)
  end
  S.submitted(S.find(Event, "race"), "race_pre", 1000)
  S.submitted(S.find(Event, "race"), "race_gap", 1000)
  S.reserved(S.find(Event, "race2"), "race2_sub", 1000)

  Rehearsal.outcome!(step, action: "a1 data", value: %w[aff plain r22 adj race race2].to_h { |key| [key, S.payouts(key)] })
  S.save!(pre_upgrade_at: Time.current.utc.iso8601(6))

when "exports"
  Rehearsal.outcome!(step, action: "exports #{ENV.fetch('EXPORT_TAG')}", value: S.exports!(ENV.fetch("EXPORT_TAG")))

when "upgrade_state"
  aff = S.find(Event, "aff")
  versions = aff.settlements.order(:version).map { |s| [s.version, s.finalized_reader, PayoutEntryGuard.restated_at(s)&.utc&.iso8601(6)] }
  Rehearsal.outcome!(step, action: "upgraded", value: {
    cutover: FinancialCutover.recorded_at(FinancialIntegrity::PAYOUT_ENTRY_CUTOVER)&.utc&.iso8601(6),
    aff_versions: versions, aff_affected: PayoutEntryGuard.affected?(aff), plain_affected: PayoutEntryGuard.affected?(S.find(Event, "plain"))
  })

# ---- Overlap: the old A1 process against the migrated database (M-09) ----
when "o_a1_actions"
  raise "A1 actions run in the previous release" if S.new_release?

  %w[aff plain].each do |key|
    event = S.find(Event, key)
    S.finalize(step, key)
    latest = event.settlements.status_finalized.order(:version).last
    S.attempt(step, "PayoutCreator.call on #{key} (A1 reserve and submit)") do
      PayoutCreator.call(settlement: latest, actor: S.admin, idempotency_key: "a2-a1-#{key}-new", amount_cents: 100)
    end
    # A1's reservation insert itself, under its own reader marker.
    S.attempt(step, "A1-marked payout insert on #{key}") do
      Payout.transaction do
        FinancialIntegrity.with_settlement_reader do
          Payout.create!(organization: event.organization, event: event, settlement: latest,
            connected_account: S.find(Payout, "payout_#{key}_held").connected_account, provider: "manual",
            idempotency_key: "a2-a1-raw-#{key}", amount_cents: 100, currency: "usd", status: :pending)
        end
      end
    end
    S.attempt(step, "PayoutHoldRelease automatic #{key}_held") do
      PayoutHoldRelease.call(payout: S.find(Payout, "payout_#{key}_held"), actor: S.admin, automatic: true)
    end
  end
  pend = S.find(Payout, "payout_aff_pend")
  creator = PayoutCreator.new(settlement: pend.settlement, actor: S.admin, idempotency_key: pend.idempotency_key)
  S.attempt(step, "PayoutCreator#submit_payout! aff_pend") { creator.send(:submit_payout!, pend) }
  plain_pend = S.find(Payout, "payout_plain_pend")
  plain_creator = PayoutCreator.new(settlement: plain_pend.settlement, actor: S.admin, idempotency_key: plain_pend.idempotency_key)
  S.attempt(step, "PayoutCreator#submit_payout! plain_pend") { plain_creator.send(:submit_payout!, plain_pend) }
  pre = Time.iso8601(S.state.fetch("pre_upgrade_at"))
  S.record_paid(step, "payout_aff_sent", pre, "A1 late paid, transfer before the upgrade", sent_before_hold_confirmed: true)
  S.record_paid(step, "payout_plain_sent", pre, "A1 late paid, transfer before the upgrade")
  Rehearsal.outcome!(step, action: "after A1 actions", value: %w[aff plain].to_h { |key| [key, S.payouts(key)] })

# ---- Capture interactions ----
when "x_old_capture"
  # A1 captures B (REHEARSAL_KEY race|race2); with REHEARSAL_PAUSE=capture
  # it stops inside its open capture transaction, holding the event.
  key = ENV.fetch("REHEARSAL_KEY")
  b = S.find(Payment, "#{key}_b")
  S.save!("#{key}_capture_started_at" => Time.current.utc.iso8601(6)) if key == "race"
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  S.attempt(step, "A1 payment_intent.succeeded on #{key} B") { S.capture!(b, id: "evt_a2_#{key}_b") }
  Rehearsal.outcome!(step, action: "capture state #{key}", value: { seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2),
    b: b.reload.slice(:status, :capture_recorded_at) })

when "x_new_paid_race_pre"
  # This release records the transfer sent before B's capture began, while
  # the capture is still open: it waits for the event, then reads it.
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  sent_at = Time.iso8601(S.state.fetch("pre_upgrade_at"))
  S.record_paid(step, "payout_race_pre", sent_at, "transfer before the capture", sent_before_hold_confirmed: true)
  Rehearsal.outcome!(step, action: "waited", value: { seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2) })

when "x_new_paid_race_gap"
  b = S.find(Payment, "race_b")
  S.record_paid(step, "payout_race_gap", b.reload.capture_recorded_at + 0.5, "transfer after the capture",
    sent_before_hold_confirmed: true, sent_before_restatement_confirmed: true)

when "x_new_submit_race2"
  # With REHEARSAL_PAUSE=submission_audit this release stops right after its
  # submission authorization, holding the event; A1's capture waits.
  payout = S.find(Payout, "payout_race2_sub")
  creator = PayoutCreator.new(settlement: payout.settlement, actor: S.admin, idempotency_key: payout.idempotency_key)
  result = S.attempt(step, "PayoutCreator#submit_payout! race2_sub") { creator.send(:submit_payout!, payout) }
  if result
    S.attempt(step, "record outcome race2_sub") do
      creator.send(:record_submission_outcome!, payout, provider_payout_id: result.provider_payout_id, status: result.status,
        initiated_at: Time.current, paid_at: nil)
      payout.reload
    end
  end

when "x_state"
  rows = %w[race race2].to_h do |key|
    event = S.find(Event, key)
    b = S.find(Payment, "#{key}_b")
    [key, { block_started_at: Commerce::NeverFulfilledPayoutHold.block_started_at(event)&.utc&.iso8601(6),
      b_capture_recorded_at: b.reload.capture_recorded_at&.utc&.iso8601(6),
      b_classified: UnfulfilledCapture.where(payment_id: b.id).pluck(:capture_scope),
      submissions: AuditLog.where(auditable_type: "Payout", auditable_id: event.payouts.select(:id), action: "payout.submission_requested")
        .order(:id).pluck(:auditable_id, :occurred_at).map { |id, at| [id, at.utc.iso8601(6)] },
      payouts: S.payouts(key) }]
  end
  Rehearsal.outcome!(step, action: "state", value: rows)

# ---- After drain: this release alone ----
when "n_affected"
  aff = S.find(Event, "aff")
  held = S.find(Payout, "payout_aff_held")
  pend = S.find(Payout, "payout_aff_pend")
  S.attempt(step, "PayoutHoldRelease aff_held (stale version)") { PayoutHoldRelease.call(payout: held, actor: S.admin) }
  S.attempt(step, "PayoutHoldRelease automatic aff_held") { PayoutHoldRelease.call(payout: held, actor: S.admin, automatic: true) }
  creator = PayoutCreator.new(settlement: pend.settlement, actor: S.admin, idempotency_key: pend.idempotency_key)
  S.attempt(step, "PayoutCreator#submit_payout! aff_pend (stale version)") { creator.send(:submit_payout!, pend) }
  S.record_paid(step, "payout_aff_pend", Time.current, "never submitted", sent_before_restatement_confirmed: true)
  restated = PayoutEntryGuard.restated_at(S.find(Payout, "payout_aff_sent").settlement)
  S.record_paid(step, "payout_aff_sent", restated + 1, "transfer after the restatement", sent_before_restatement_confirmed: true)
  S.record_paid(step, "payout_aff_sent", Time.iso8601(S.state.fetch("pre_upgrade_at")), "already sent before the upgrade",
    sent_before_restatement_confirmed: true)
  current = S.finalize(step, "aff")
  S.attempt(step, "PayoutCreator.call aff on the current version (full amount)") do
    PayoutCreator.call(settlement: current, actor: S.admin, idempotency_key: "a2-aff-new-all")
  end
  [pend, held].each do |payout|
    S.attempt(step, "PayoutReconciler failed #{payout.id} (never sent; reissue)") do
      PayoutReconciler.call(payout: payout.reload, actor: S.admin, status: "failed",
        evidence: { reference: "Not sent", reason: "Reissued on the current statement", confirmed_at: Time.current.utc.iso8601(6) })
    end
  end
  reissued = S.attempt(step, "PayoutCreator.call aff reissue on the current version") do
    PayoutCreator.call(settlement: Settlements::Finalizer.call(event: aff, actor: S.admin), actor: S.admin, idempotency_key: "a2-aff-reissue")
  end
  S.save!(payout_aff_reissue: reissued.id) if reissued
  S.record_paid(step, "payout_aff_reissue", Time.current, "matching version") if reissued
  Rehearsal.outcome!(step, action: "aff payouts", value: { payouts: S.payouts("aff"),
    payable: Settlements::Calculator.call(aff).attributes[:payable_cents],
    versions: aff.settlements.order(:version).pluck(:version, :finalized_reader) })

when "n_plain"
  held = S.find(Payout, "payout_plain_held")
  S.attempt(step, "PayoutHoldRelease plain_held") { held.reload.status_held? ? PayoutHoldRelease.call(payout: held, actor: S.admin) : held.status }
  S.record_paid(step, "payout_plain_sent", Time.iso8601(S.state.fetch("pre_upgrade_at")), "recorded again from A2")
  Rehearsal.outcome!(step, action: "plain payouts", value: S.payouts("plain"))

when "n_derive"
  PayoutCustody.derive_history!(dry_run: true).then { |rows| Rehearsal.outcome!(step, action: "derive dry run", value: rows) }
  S.attempt(step, "derive without authority") { PayoutCustody.derive_history!(dry_run: false) }
  S.attempt(step, "derive with authority") { PayoutCustody.derive_history!(dry_run: false, authorized_by: "FIN-A2") }
  S.attempt(step, "derive again") { PayoutCustody.derive_history!(dry_run: false, authorized_by: "FIN-A2") }

when "n_ordinary"
  # Review finding 1: A2 approves and submits three payouts on the current
  # statement; an ordinary refund then changes it. Its database-stamped
  # success time is the cutoff: before it is paid, at and after it refused.
  ord = S.find(Event, "ord")
  %w[ord_pre ord_at ord_post].each { |key| S.submitted(ord, key, 1000) }
  S.save!(ord_pre_sent_at: Time.current.utc.iso8601(6))
  sleep 0.05
  sale = S.find(Order, "ord_sale")
  refund = Refund.create!(order: sale, payment: S.find(Payment, "ord_payment"), provider: "stripe",
    provider_refund_id: "re_a2_ord_ordinary", idempotency_key: "a2-ord-ordinary-refund", amount_cents: 500, currency: "usd",
    status: :succeeded, succeeded_at: Time.current)
  RefundItem.create!(refund: refund, order_item: S.find(OrderItem, "ord_item"), amount_cents: 500, organizer_proceeds_cents: 500,
    fee_cents: 0, organizer_fee_cents: 0, tax_cents: 0, quantity: 0)
  changed_at = refund.reload.success_recorded_at
  S.save!(ord_changed_at: changed_at.utc.iso8601(6))
  entry = PayoutEntryGuard.paid_cutoff(S.find(Payout, "payout_ord_at"))
  Rehearsal.outcome!(step, action: "ordinary cutoff", value: { cutoff_at: entry[:cutoff_at]&.utc&.iso8601(6),
    changed_at: changed_at.utc.iso8601(6), unproven: entry[:unproven].size,
    changes: entry[:changes].map { |change| change.merge(at: change[:at]&.utc&.iso8601(6)) } })
  Rehearsal.outcome!(step, action: "dispatch ord_at", value: PayoutEntryGuard.dispatch(S.find(Payout, "payout_ord_at")))
  pre = Time.iso8601(S.state.fetch("ord_pre_sent_at"))
  S.record_paid(step, "payout_ord_post", pre, "confirmation flag missing")
  S.record_paid(step, "payout_ord_at", changed_at, "transfer at the change", sent_before_restatement_confirmed: true)
  S.record_paid(step, "payout_ord_post", Time.current, "transfer after the change", sent_before_restatement_confirmed: true)
  S.record_paid(step, "payout_ord_pre", pre, "transfer before the change", sent_before_restatement_confirmed: true)
  Rehearsal.outcome!(step, action: "ord payouts", value: S.payouts("ord"))

when "o_a1_ordinary"
  raise "A1 actions run in the previous release" if S.new_release?

  pre = Time.iso8601(S.state.fetch("ord_pre_sent_at"))
  S.record_paid(step, "payout_ord_post", pre, "A1 paid after an ordinary change", sent_before_hold_confirmed: true)

when "n_baseline"
  # The published BPT treatment of the ambiguous adjustment-only payout: the
  # A1 baseline export reports no organizer_payouts for its event.
  adj = S.find(Event, "adj")
  baseline = Dir[File.join(Rehearsal::DIR, "exports", "baseline", "bpt-*.csv")].flat_map { |path| CSV.read(path, headers: true).map(&:to_h) }
  included = baseline.any? { |row| row["event_id"] == adj.id.to_s && row["organizer_payouts"].to_s != "0.00" }
  File.write(File.join(Rehearsal::DIR, "published_baseline.csv"),
    "payout_id,included,source\n#{S.state.fetch('payout_adj_paid')},#{included},A1 baseline BPT export (rehearsal)\n")
  Rehearsal.outcome!(step, action: "published baseline", value: { payout_id: S.state.fetch("payout_adj_paid"), included: included })

when "n_r22_capture"
  # The live Stripe capture on the R2-2 event, after its payout was paid.
  order = S.find(Order, "r22_later_order")
  payment = S.find(Payment, "r22_later_payment")
  Order.transaction do
    Passes::Locking.lock_events_for_order!(order)
    order.lock!
    payment.lock!.update!(status: :succeeded, succeeded_at: Time.current)
    order.update!(status: :completed, completed_at: Time.current, fulfilled_by_payment_id: payment.id)
  end
  Rehearsal.outcome!(step, action: "r22 capture", value: payment.reload.slice(:status, :capture_recorded_at))

when "assertions"
  outcomes = File.readlines(File.join(Rehearsal::DIR, "outcomes.jsonl")).map { |line| JSON.parse(line) }
  calls = File.readlines(File.join(Rehearsal::DIR, "calls.jsonl")).map { |line| JSON.parse(line) }.select { |c| c["kind"] == "payout_submit" }
  find_outcome = ->(role, step_name, action) { outcomes.find { |row| row["role"] == role && row["step"] == step_name && row["action"] == action } }
  results = []
  check = ->(label, ok) { results << "#{ok ? 'PASS' : 'FAIL'} #{label}" }
  refused = ->(role, step_name, action, pattern = nil) {
    row = find_outcome.call(role, step_name, action)
    row && row["result"] == "refused" && (pattern.nil? || row["message"].to_s.match?(pattern))
  }
  ok = ->(role, step_name, action) { find_outcome.call(role, step_name, action)&.fetch("result") == "ok" }
  id = ->(key) { S.state.fetch(key) }

  # M-09: A1 during the overlap.
  check.call("M-09: A1 finalization refused on the affected event", refused.call("old", "o_a1_actions", "Settlements::Finalizer aff", /settlement reader/))
  check.call("M-09: A1 payout creation refused on the affected event", refused.call("old", "o_a1_actions", "PayoutCreator.call on aff (A1 reserve and submit)"))
  check.call("M-09: A1's own marked payout insert refused by the database", refused.call("old", "o_a1_actions",
    "A1-marked payout insert on aff", /Payout entry fence/))
  check.call("A1-marked payout insert allowed on a non-affected event", ok.call("old", "o_a1_actions", "A1-marked payout insert on plain"))
  auto = find_outcome.call("old", "o_a1_actions", "PayoutHoldRelease automatic aff_held")
  check.call("M-09: A1 automatic held release refused on the affected event", auto && (auto["result"] == "refused" || auto["value"] == false))
  check.call("M-09: A1 submission refused on the affected event", refused.call("old", "o_a1_actions", "PayoutCreator#submit_payout! aff_pend", /fence/))
  check.call("M-09: A1 paid recording refused on the affected event", refused.call("old", "o_a1_actions",
    "PayoutReconciler paid payout_aff_sent (A1 late paid, transfer before the upgrade)", /fence/))
  check.call("A1 on a non-affected event: finalization allowed", ok.call("old", "o_a1_actions", "Settlements::Finalizer plain"))
  plain_auto = find_outcome.call("old", "o_a1_actions", "PayoutHoldRelease automatic plain_held")
  check.call("A1 on a non-affected event: automatic held release allowed", plain_auto&.fetch("value") == true)
  check.call("A1 on a non-affected event: submission allowed", ok.call("old", "o_a1_actions", "PayoutCreator#submit_payout! plain_pend"))
  check.call("A1 late paid recording fails closed (no custody row), any event", refused.call("old", "o_a1_actions",
    "PayoutReconciler paid payout_plain_sent (A1 late paid, transfer before the upgrade)", /Payout custody fence/))
  check.call("A2 records the same plain transfer with its custody row", Payout.find(id.call("payout_plain_sent")).status_paid? &&
    PayoutCustodyDetermination.exists?(payout_id: id.call("payout_plain_sent"), basis: "recorded_at_paid"))

  # Stale and matching versions on the affected event.
  check.call("stale: A2 held release refused", refused.call("new", "n_affected", "PayoutHoldRelease aff_held (stale version)",
    /approved statement is out of date/))
  check.call("stale: A2 submission refused", refused.call("new", "n_affected", "PayoutCreator#submit_payout! aff_pend (stale version)",
    /approved statement is out of date/))
  check.call("stale: never-submitted payout not paid", refused.call("new", "n_affected", "PayoutReconciler paid payout_aff_pend (never submitted)"))
  check.call("stale: transfer after the restatement refused", refused.call("new", "n_affected",
    "PayoutReconciler paid payout_aff_sent (transfer after the restatement)"))
  check.call("already sent before the upgrade: recorded once with custody", ok.call("new", "n_affected",
    "PayoutReconciler paid payout_aff_sent (already sent before the upgrade)") &&
    PayoutCustodyDetermination.exists?(payout_id: id.call("payout_aff_sent"), basis: "recorded_at_paid"))
  check.call("no new funds: full-amount payout on the current version refused while reservations stand",
    refused.call("new", "n_affected", "PayoutCreator.call aff on the current version (full amount)", /must be positive|exceeds/))
  sent_custody = PayoutCustodyDetermination.find_by(payout_id: id.call("payout_aff_sent"))
  check.call("already-sent A1 payout frozen as Stripe custody with its funded sale", sent_custody&.determination == "stripe_custody")
  aff = S.find(Event, "aff")
  reissue = Payout.find_by(id: S.state["payout_aff_reissue"])
  check.call("matching version: reissue equals the failed reservations and is paid", reissue&.status_paid? &&
    reissue.amount_cents == Payout.where(id: [id.call("payout_aff_pend"), id.call("payout_aff_held")]).sum(:amount_cents))
  committed = aff.payouts.where(status: %i[pending processing held paid]).sum(:amount_cents)
  check.call("affected event: sent plus reserved equals the current payable exactly",
    committed == Settlements::Calculator.call(aff).attributes[:payable_cents])
  check.call("affected event: latest version is A2's and has the $0 line",
    aff.settlements.status_finalized.order(:version).last.then { |s| s.finalized_reader == "nfc-a2" && PayoutEntryGuard.restated_at(s).nil? })
  check.call("history kept: A1 versions unchanged and still restated", aff.settlements.where(finalized_reader: nil).all? { |s| PayoutEntryGuard.restated_at(s) })

  # Gateway calls.
  new_aff_calls = calls.count { |c| c["role"] == "new" && Payout.find_by(id: c["payout_id"])&.event_id == aff.id }
  check.call("gateway: A2 submitted exactly once on the affected event (the reissue)", new_aff_calls == 1)
  old_after = calls.select { |c| c["role"] == "old" }.map { |c| Payout.find_by(id: c["payout_id"])&.event_id }
  # A1's two submissions on it were before the upgrade (aff_early, aff_sent).
  check.call("gateway: A1 made no submission on the affected event during the overlap", old_after.count(aff.id) == 2)

  # Capture interactions.
  race_b = S.find(Payment, "race_b")
  check.call("capture first: A1's capture held the event and classified B", UnfulfilledCapture.exists?(payment_id: race_b.id))
  waited = find_outcome.call("new", "x_new_paid_race_pre", "waited")
  check.call("capture first: A2 paid recording waited on the event (>= 1 s)", waited && waited["value"]["seconds"] >= 1.0)
  check.call("capture first: transfer sent before the capture recorded", Payout.find(id.call("payout_race_pre")).status_paid?)
  check.call("capture first: transfer after the capture refused", refused.call("new", "x_new_paid_race_gap",
    "PayoutReconciler paid payout_race_gap (transfer after the capture)", /fence|sent before/))
  race2_b = S.find(Payment, "race2_b")
  sub = AuditLog.where(auditable_id: id.call("payout_race2_sub"), auditable_type: "Payout", action: "payout.submission_requested").pick(:occurred_at)
  check.call("payout first: A2 submission committed before A1's capture", sub && race2_b.reload.capture_recorded_at && sub < race2_b.capture_recorded_at)
  check.call("payout first: the submitted payout's outcome recorded", Payout.find(id.call("payout_race2_sub")).status_processing?)

  # Review finding 1: an ordinary statement change on an A2 version.
  cutoff = find_outcome.call("new", "n_ordinary", "ordinary cutoff")&.fetch("value")
  check.call("ordinary change: cutoff is the refund's recorded success time",
    cutoff && cutoff["cutoff_at"] == cutoff["changed_at"] && cutoff["unproven"].zero?)
  dispatch = find_outcome.call("new", "n_ordinary", "dispatch ord_at")&.fetch("value")
  check.call("ordinary change: the manual transfer is a placeholder and not actionable",
    dispatch && dispatch["placeholder"] == true && dispatch["actionable"] == false && dispatch["reasons"] == ["statement_changed"])
  check.call("ordinary change: no confirmation, not paid", refused.call("new", "n_ordinary",
    "PayoutReconciler paid payout_ord_post (confirmation flag missing)", /out of date/))
  check.call("ordinary change: transfer at the change refused", refused.call("new", "n_ordinary",
    "PayoutReconciler paid payout_ord_at (transfer at the change)", /out of date/))
  check.call("ordinary change: transfer after the change refused", refused.call("new", "n_ordinary",
    "PayoutReconciler paid payout_ord_post (transfer after the change)", /out of date/))
  check.call("ordinary change: transfer before the change recorded with custody", ok.call("new", "n_ordinary",
    "PayoutReconciler paid payout_ord_pre (transfer before the change)") &&
    PayoutCustodyDetermination.exists?(payout_id: id.call("payout_ord_pre"), basis: "recorded_at_paid"))
  check.call("ordinary change: A1 cannot record it either", refused.call("old", "o_a1_ordinary",
    "PayoutReconciler paid payout_ord_post (A1 paid after an ordinary change)", /fence/))
  ord = S.find(Event, "ord")
  check.call("ordinary change: payouts after it are still in flight, not paid",
    Payout.where(id: [id.call("payout_ord_at"), id.call("payout_ord_post")]).pluck(:status).uniq == ["processing"])
  check.call("gateway: A2 submitted the three approved payouts on the ordinary-change event once each",
    calls.count { |c| c["role"] == "new" && Payout.find_by(id: c["payout_id"])&.event_id == ord.id } == 3)

  # Custody and R2-2.
  check.call("custody: derive refused without authority", refused.call("new", "n_derive", "derive without authority", /AUTHORIZED_BY/))
  dry = find_outcome.call("new", "n_derive", "derive dry run")&.fetch("value").to_a
  adj_row = dry.find { |row| row["payout_id"] == id.call("payout_adj_paid") }
  check.call("missing lines: the adjustment-only payout is ambiguous and needs the published baseline",
    adj_row && adj_row["determination"] == "ambiguous" && adj_row["skipped"] == "needs_published_baseline")
  adj = PayoutCustodyDetermination.find_by(payout_id: id.call("payout_adj_paid"))
  published = find_outcome.call("new", "n_baseline", "published baseline")&.fetch("value")
  check.call("missing lines: frozen ambiguous from the authorized baseline, keeping the published treatment",
    adj && adj.determination == "ambiguous" && adj.basis == "derived_history" &&
      adj.conservative_inclusion == published&.fetch("included") && adj.evidence.dig("published_baseline", "included") == published&.fetch("included"))
  adj_event = S.find(Event, "adj").id.to_s
  bpt_cell = ->(tag) {
    Dir[File.join(Rehearsal::DIR, "exports", tag, "bpt-*.csv")].flat_map { |path| CSV.read(path, headers: true).map(&:to_h) }
      .find { |row| row["event_id"] == adj_event }&.fetch("organizer_payouts")
  }
  check.call("missing lines: the published BPT row is unchanged after derive", bpt_cell.call("baseline") == bpt_cell.call("after_r22_capture"))
  paid = Payout.where(status: %i[paid reversed]).where.not(paid_at: nil)
  check.call("custody: zero undetermined paid payouts after the authorized derive", PayoutCustody.undetermined(paid).none?)
  r22 = PayoutCustodyDetermination.find_by(payout_id: id.call("payout_r22_paid"))
  check.call("R2-2: the non-custodial payout is frozen non_custodial (derived history)", r22&.determination == "non_custodial" &&
    r22.basis == "derived_history" && r22.evidence["authorized_by"] == "FIN-A2")
  check.call("R2-2: the later live capture is not in its determination", !r22&.qualifying_payment_ids&.include?(id.call("r22_later_payment")))

  # Annual organizer population (A2 recheck finding 5): A1 and this release
  # agree on the same data, and a later capture adds no earlier payout.
  annual = ->(tag) { JSON.parse(File.read(Dir[File.join(Rehearsal::DIR, "exports", tag, "annual-organizers-*.json")].sole)) }
  check.call("annual: A1 and A2 read the same organizer payout population after the upgrade " \
    "(#{annual.call('upgraded').values.sum} cents)", annual.call("baseline") == annual.call("upgraded"))
  check.call("annual: A1 and A2 read the same organizer payout population before the R2-2 capture " \
    "(#{annual.call('before_r22_capture').values.sum} cents)",
    annual.call("a1_before_r22_capture") == annual.call("before_r22_capture"))
  check.call("annual: the later R2-2 capture adds no earlier payout (A2)",
    annual.call("before_r22_capture") == annual.call("after_r22_capture"))

  File.write(File.join(Rehearsal::DIR, "assertions.txt"), results.join("\n") + "\n")
  puts results
end
