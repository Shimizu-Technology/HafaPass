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

  # CodeRabbit 4704013214: a classified capture fully repaid (no
  # over-return yet) on its own event, in its own organization (a P4 hold
  # holds the organization's balance). A2 submits payouts on it; A1 then
  # writes the refunds, the dispute and the over-return during the overlap.
  p4_owner = S.create(:user, :organizer, clerk_id: "clerk_a2_p4_owner", email: "rehearsal.a2.p4@example.com")
  p4_organization = S.create(:organization, name: "Rehearsal A2 P4 Organization")
  p4_profile = S.create(:organizer_profile, :verified, user: p4_owner, organization: p4_organization)
  S.approved_bank_account!(p4_organization, actor: p4_owner, admin: admin, last_four: "6666")
  p4 = S.completed_event!(p4_organization, p4_profile, "Rehearsal A2 P4 episode")
  p4_type = S.create(:ticket_type, event: p4, price_cents: 2000, quantity_available: 50, quantity_sold: 0)
  S.record_card_sale!(p4, ticket_type: p4_type, quantity: 5, processing_fee_cents: 100)
  p4_order, p4_c, p4_capture = S.classified_capture(items: [[1200, 160, 0, 0]], event: p4, intent: "pi_a2_p4_c")
  S.verified_processing!(p4_order, p4_c, 69)
  S.ingest_provider_refund!(p4_c, 1360, id: "re_a2_p4_full")
  Commerce::NeverFulfilledResolution.evaluate!(p4_capture.reload, trigger: "rehearsal")
  # Finance closes the refund's fee-adjustment review (HåfaPass-borne).
  ReconciliationException.open.where(payment_id: p4_c.id, code: "stripe_fee_adjustment_review_required").find_each(&:resolve!)
  S.save!(p4: p4.id, p4_order: p4_order.id, p4_c: p4_c.id, p4_capture: p4_capture.id)

  # A2 recheck finding 1 (7664e143): an affected event in its own
  # organization (a live sale and a repaid classified capture, no payouts
  # yet). This release approves a version with the capture's $0 line and
  # pays $10 from it; A1 then reverses that transfer with its generic
  # confirmation during the overlap.
  rev_owner = S.create(:user, :organizer, clerk_id: "clerk_a2_rev_owner", email: "rehearsal.a2.rev@example.com")
  rev_organization = S.create(:organization, name: "Rehearsal A2 Reversal Organization")
  rev_profile = S.create(:organizer_profile, :verified, user: rev_owner, organization: rev_organization)
  S.approved_bank_account!(rev_organization, actor: rev_owner, admin: admin, last_four: "7777")
  rev = S.completed_event!(rev_organization, rev_profile, "Rehearsal A2 Reversal")
  rev_type = S.create(:ticket_type, event: rev, price_cents: 2000, quantity_available: 50, quantity_sold: 0)
  _rev_sale, _rev_item, rev_payment = S.record_card_sale!(rev, ticket_type: rev_type, quantity: 5, processing_fee_cents: 100)
  Payment.where(id: rev_payment.id).update_all(provider_environment: "live", provider_payment_id: "pi_live_a2_rev_sale")
  rev_order, rev_c, = S.classified_capture(items: [[1200, 160, 0, 0]], event: rev, intent: "pi_a2_rev_c")
  S.verified_processing!(rev_order, rev_c, 69)
  S.save!(rev: rev.id, rev_organization: rev_organization.id)

  # A2 recheck finding 1 (758485ae): two ordinary events (no
  # never-fulfilled capture), each with a sale in its own organization. A2
  # submits $10.00 on each, a cancellation hold commits during the gateway
  # call and the stubbed provider reports it paid; A1 then records its
  # generic failed (acc_fail) or reversed (acc_rev) outcome.
  # CodeRabbit 4706251677 (a292e277): acc_stale, a third ordinary event,
  # where the provider's paid result reaches a still-pending payout after a
  # hold whose cutoff predates its submission (both the paid and the
  # processing write are refused at that cutoff).
  %w[acc_fail acc_rev acc_stale].each_with_index do |key, index|
    acc_owner = S.create(:user, :organizer, clerk_id: "clerk_a2_#{key}_owner", email: "rehearsal.a2.#{key.tr('_', '-')}@example.com")
    acc_organization = S.create(:organization, name: "Rehearsal A2 Accepted #{key}")
    acc_profile = S.create(:organizer_profile, :verified, user: acc_owner, organization: acc_organization)
    S.approved_bank_account!(acc_organization, actor: acc_owner, admin: admin, last_four: "888#{index + 1}")
    acc = S.completed_event!(acc_organization, acc_profile, "Rehearsal A2 Accepted #{key}")
    acc_type = S.create(:ticket_type, event: acc, price_cents: 2000, quantity_available: 50, quantity_sold: 0)
    S.record_card_sale!(acc, ticket_type: acc_type, quantity: 5, processing_fee_cents: 100)
    S.save!(key => acc.id)
  end

  # A2 recheck finding 2 (8132fe22): three more ordinary events, each in its
  # own organization. acc_eo gets an acceptance shown only by its audit on an
  # in-flight payout, acc_eo_hist one on a payout already failed (a persisted
  # recognized conflict no longer committed), and acc_ctl an ordinary
  # payout with no acceptance (the control).
  %w[acc_eo acc_eo_hist acc_ctl].each_with_index do |key, index|
    eo_owner = S.create(:user, :organizer, clerk_id: "clerk_a2_#{key}_owner", email: "rehearsal.a2.#{key.tr('_', '-')}@example.com")
    eo_organization = S.create(:organization, name: "Rehearsal A2 Evidence #{key}")
    eo_profile = S.create(:organizer_profile, :verified, user: eo_owner, organization: eo_organization)
    S.approved_bank_account!(eo_organization, actor: eo_owner, admin: admin, last_four: "777#{index + 1}")
    eo = S.completed_event!(eo_organization, eo_profile, "Rehearsal A2 Evidence #{key}")
    eo_type = S.create(:ticket_type, event: eo, price_cents: 2000, quantity_available: 50, quantity_sold: 0)
    S.record_card_sale!(eo, ticket_type: eo_type, quantity: 5, processing_fee_cents: 100)
    S.save!(key => eo.id)
  end

  # A2 recheck of bca5f904: six more ordinary events, each in its own
  # organization. sub_eo, sub_org and sub_lock: A1 reserves a payout before
  # an acceptance shown only by its audit appears (on that payout, on an
  # earlier failed payout of the organization, or committed while A1 waits
  # on the event lock), then A1 and A2 try to submit it. ret_eo and ret_eo2:
  # an expired paid-refusal audit on a reversed payout meets the scheduled
  # retention job (A1's, then A2's); ret_ctl: an expired ordinary conflict
  # audit (the control).
  %w[sub_eo sub_org sub_lock ret_eo ret_eo2 ret_ctl].each_with_index do |key, index|
    owner = S.create(:user, :organizer, clerk_id: "clerk_a2_#{key}_owner", email: "rehearsal.a2.#{key.tr('_', '-')}@example.com")
    sub_organization = S.create(:organization, name: "Rehearsal A2 Audit-only #{key}")
    sub_profile = S.create(:organizer_profile, :verified, user: owner, organization: sub_organization)
    S.approved_bank_account!(sub_organization, actor: owner, admin: admin, last_four: "666#{index + 1}")
    sub = S.completed_event!(sub_organization, sub_profile, "Rehearsal A2 Audit-only #{key}")
    sub_type = S.create(:ticket_type, event: sub, price_cents: 2000, quantity_available: 50, quantity_sold: 0)
    S.record_card_sale!(sub, ticket_type: sub_type, quantity: 5, processing_fee_cents: 100)
    S.save!(key => sub.id, "#{key}_owner" => owner.id)
  end

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
  paths = Dir[File.join(Rehearsal::DIR, "exports", "baseline", "bpt-*.csv")].sort
  baseline = paths.flat_map { |path| CSV.read(path, headers: true).map(&:to_h) }
  included = baseline.any? { |row| row["event_id"] == adj.id.to_s && row["organizer_payouts"].to_s != "0.00" }
  # A structured reference to the filed export and its digest, never free text.
  path = paths.fetch(0)
  source = "bpt-export:#{File.basename(path, '.csv').delete_prefix('bpt-')}@sha256:#{Digest::SHA256.file(path).hexdigest}"
  File.write(File.join(Rehearsal::DIR, "published_baseline.csv"),
    "payout_id,included,source\n#{S.state.fetch('payout_adj_paid')},#{included},#{source}\n")
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

# ---- CodeRabbit 4704013214: the P4 episode start across both releases ----
when "n_p4_anchor"
  # This release approves and submits three payouts (the last passing fence).
  p4 = S.find(Event, "p4")
  %w[p4_pre p4_at p4_post].each { |key| S.submitted(p4, key, 1000) }
  anchor = ActiveRecord::Base.connection.select_value(
    ActiveRecord::Base.sanitize_sql_array(["SELECT hafapass_overpaid_proof_anchor(?)", S.state.fetch("p4_c")]))
  S.save!(p4_anchor: ActiveRecord::Type::DateTime.new.cast(anchor).utc.iso8601(6))
  Rehearsal.outcome!(step, action: "p4 anchor", value: { anchor: S.state.fetch("p4_anchor"), payouts: S.payouts("p4") })

when "o_p4_episode"
  raise "the A1 P4 facts are written by the previous release" if S.new_release?

  # A1 ingests a pending refund and the dispute that over-returns. Both rows
  # are dated before the fence (written then, committed after it: their row
  # times precede the anchor), so the fence did not test this proof. A1's
  # evaluator opens the over-return; the database checks its proof.
  payment = S.find(Payment, "p4_c")
  anchor = Time.iso8601(S.state.fetch("p4_anchor"))
  block_start = -> {
    value = ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(["SELECT hafapass_payout_block_start(?)", S.state.fetch("p4")]))
    value && ActiveRecord::Type::DateTime.new.cast(value).utc.iso8601(6)
  }
  first = S.ingest_provider_refund!(payment, 500, id: "re_a2_p4_first", status: "pending")
  dispute = S.lose_dispute!(payment, "dp_a2_p4", amount: 1360)
  Refund.where(id: first.id).update_all(created_at: anchor - 1)
  Dispute.where(id: dispute.id).update_all(created_at: anchor - 1)
  Commerce::NeverFulfilledResolution.evaluate!(S.find(UnfulfilledCapture, "p4_capture").reload, trigger: "rehearsal")
  overpaid = ReconciliationException.where(payment_id: payment.id, code: "never_fulfilled_buyer_overpaid").order(:id).first
  S.save!(p4_overpaid: overpaid&.id)
  opened = { created_at: overpaid&.created_at&.utc&.iso8601(6),
    proof_checked_at: overpaid && ReconciliationException.where(id: overpaid.id).pick(Arel.sql("proof_checked_at"))&.utc&.iso8601(6),
    hold_started_at: overpaid && ReconciliationException.where(id: overpaid.id).pick(:hold_started_at)&.utc&.iso8601(6) }
  Rehearsal.outcome!(step, action: "p4 opened by A1", value: opened.merge(block_start: block_start.call))
  sleep 0.1
  S.save!(p4_between: Time.current.utc.iso8601(6))
  sleep 0.1
  S.ingest_provider_refund!(payment, 300, id: "re_a2_p4_second", status: "pending")
  Rehearsal.outcome!(step, action: "p4 newer pending refund", value: { block_start: block_start.call })
  # The first refund posts (recognized) while the newer one is pending.
  S.ingest_provider_refund!(payment, 500, id: "re_a2_p4_first", status: "succeeded")
  Rehearsal.outcome!(step, action: "p4 first refund posted", value: { block_start: block_start.call,
    first_posted: BuyerReturnPosting.where(source_type: "Refund", source_id: first.id, kind: "refund").exists? })
  S.record_paid(step, "payout_p4_pre", Time.iso8601(opened[:created_at]) - 0.000001, "A1 paid before the opening",
    sent_before_hold_confirmed: true)

when "n_p4_paid"
  # The database fence (any writer, the transfer named) at the exact bank
  # timestamps while the newer refund is pending, then this release's
  # reconciler once the newer refund has posted and a linked debit still
  # defeats the proof.
  p4 = S.find(Event, "p4")
  cutoff = Commerce::NeverFulfilledPayoutHold.block_started_at(p4)
  between = Time.iso8601(S.state.fetch("p4_between"))
  db_paid = lambda do |key, paid_at|
    payout = S.find(Payout, key)
    ActiveRecord::Base.transaction do
      FinancialIntegrity.with_settlement_reader do
        FinancialIntegrity.with_payout_transfer(payout.id) do
          PayoutCustody.record!(payout, basis: "recorded_at_paid")
          Payout.where(id: payout.id).update_all(status: Payout.statuses[:paid], paid_at: paid_at)
        end
      end
      raise ActiveRecord::Rollback
    end
    "accepted"
  rescue ActiveRecord::StatementInvalid => e
    e.message[/Repayment fence[^\n]*/] || e.message.lines.first.strip
  end
  Rehearsal.outcome!(step, action: "p4 database fence", value: { cutoff: cutoff&.utc&.iso8601(6),
    pre_before: db_paid.call("payout_p4_pre", cutoff - 0.000001), at_between: db_paid.call("payout_p4_at", between),
    post_at_cutoff: db_paid.call("payout_p4_post", cutoff) })
  p4.organization.balance_adjustments.create!(event: p4, order: S.find(Order, "p4_order"), kind: "manual_debit",
    amount_cents: -500, currency: "usd", status: :posted, reason: "Rehearsal linked debit", effective_at: Time.current,
    created_by_user: S.admin)
  S.ingest_provider_refund!(S.find(Payment, "p4_c"), 300, id: "re_a2_p4_second", status: "succeeded")
  Rehearsal.outcome!(step, action: "p4 after the newer refund posted", value: {
    block_start: Commerce::NeverFulfilledPayoutHold.block_started_at(p4)&.utc&.iso8601(6),
    pending_refunds: Refund.pending.where(payment_id: S.state.fetch("p4_c")).count })
  S.record_paid(step, "payout_p4_post", cutoff, "transfer at the cutoff", sent_before_hold_confirmed: true)
  S.record_paid(step, "payout_p4_at", between, "transfer after the opening", sent_before_hold_confirmed: true)
  S.record_paid(step, "payout_p4_pre", cutoff - 0.000001, "transfer just before the cutoff", sent_before_hold_confirmed: true)
  Rehearsal.outcome!(step, action: "p4 payouts", value: S.payouts("p4"))

# ---- A2 recheck finding 1 (7664e143): A1's reversal during the overlap ----
when "n_rev_paid"
  rev = S.find(Event, "rev")
  S.submitted(rev, "rev_paid", 1000)
  S.record_paid(step, "payout_rev_paid", Time.current, "A2 paid on a version with the $0 line")
  payout = S.find(Payout, "payout_rev_paid")
  # The version a fresh payout would be approved on (the paid payout is on
  # the statement now).
  S.save!(rev_available_before: OrganizationPayoutBalance.available_cents(rev.organization),
    rev_fresh_settlement: Settlements::Finalizer.call(event: rev, actor: S.admin).id)
  # CodeRabbit 4705527099: the funded version's line for the classified
  # capture (its $0 adjustment), as written.
  captured = UnfulfilledCapture.joins(:order).where(orders: { event_id: rev.id }).pluck(:payment_id).sort
  capture_lines = payout.settlement.settlement_items.where(kind: "adjustment").select do |item|
    item.metadata["adjustment_kind"] == Commerce::ClassifiedOrganizerView::INFO_ADJUSTMENT_KIND &&
      Array(item.metadata["payment_ids"]).intersect?(captured)
  end
  Rehearsal.outcome!(step, action: "rev paid", value: { payout: S.payouts("rev"),
    version_reader: payout.settlement.finalized_reader, version_restated_at: PayoutEntryGuard.restated_at(payout.settlement),
    available_cents: S.state.fetch("rev_available_before"), captured_payment_ids: captured,
    capture_lines: capture_lines.map { |item| { amount_cents: item.amount_cents, payment_ids: item.metadata["payment_ids"] } } })

when "o_rev_a1_reverse"
  raise "A1's reversal runs in the previous release" if S.new_release?

  # A1's generic reversal (no return evidence). With
  # REHEARSAL_PAUSE=reversal_audit it stops after its audit row, before its
  # commit, holding the organization, event and payout.
  payout = S.find(Payout, "payout_rev_paid")
  S.attempt(step, "A1 PayoutReconciler reversed payout_rev_paid (generic confirmation)") do
    PayoutReconciler.call(payout: payout, actor: S.admin, status: "reversed", provider_payout_id: payout.provider_payout_id,
      evidence: S.evidence(Time.current)).reload
  end
  Rehearsal.outcome!(step, action: "rev after A1 reversal", value: { status: payout.reload.status,
    available_cents: OrganizationPayoutBalance.available_cents(payout.organization) })

when "n_rev_reserve_race"
  # While A1's reversal is open: a fresh payout for the amount the reversal
  # would release (the reviewer's $69 -> $79). It waits for A1's locks.
  rev = S.find(Event, "rev")
  amount = S.state.fetch("rev_available_before") + 1000
  settlement = S.find(Settlement, "rev_fresh_settlement")
  # CodeRabbit 4705527122: the marker (with this backend's pid) and the
  # timer start immediately before the reservation; the driver releases A1
  # only once pg_blocking_pids shows this backend waiting on A1's.
  Rehearsal.mark("rev_reserve")
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  S.attempt(step, "PayoutCreator.call rev for #{amount} (would need the released $10)") do
    PayoutCreator.call(settlement: settlement, actor: S.admin, idempotency_key: "a2-rev-race", amount_cents: amount)
  end
  Rehearsal.outcome!(step, action: "rev race waited", value: { seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2) })

when "n_rev_after"
  rev = S.find(Event, "rev")
  payout = S.find(Payout, "payout_rev_paid")
  before = S.state.fetch("rev_available_before")
  available = -> { OrganizationPayoutBalance.available_cents(rev.organization) }
  Rehearsal.outcome!(step, action: "rev after the A1 attempt", value: { status: payout.reload.status, available_cents: available.call })
  # Approved on a version finalized now, as the reviewer's reproduction did.
  S.attempt(step, "PayoutCreator.call rev for #{before + 1000} after the A1 attempt") do
    PayoutCreator.call(settlement: Settlements::Finalizer.call(event: rev, actor: S.admin), actor: S.admin,
      idempotency_key: "a2-rev-fresh", amount_cents: before + 1000)
  end
  S.attempt(step, "A2 PayoutReconciler reversed payout_rev_paid (generic confirmation)") do
    PayoutReconciler.call(payout: payout.reload, actor: S.admin, status: "reversed", provider_payout_id: payout.provider_payout_id,
      evidence: S.evidence(Time.current))
  end
  exact = { "return_reference" => "RET-A2-REV", "returned_amount_cents" => payout.disbursement_cents,
    "returned_at" => Time.current.utc.iso8601(6), "sent_at" => payout.paid_at.utc.iso8601(6) }
  # CodeRabbit 4704933005: the fence reads the durable proof
  # (payout_return_proofs), so the exact audit alone is refused; `proof`
  # writes it the way the current reconciler does.
  raw = lambda do |label, metadata, immediate: false, proof: false|
    S.attempt(step, "raw SQL reversal (#{label})") do
      ActiveRecord::Base.transaction do
        Payout.where(id: payout.id).update_all(status: Payout.statuses[:reversed])
        if metadata
          AuditLog.create!(auditable: payout, organization: payout.organization, action: "payout.reconciled", occurred_at: Time.current,
            before_data: { "status" => "paid" }, after_data: { "status" => "reversed" }, metadata: metadata)
        end
        if proof
          FinancialIntegrity.with_payout_return(payout.id) do
            PayoutReturnProof.create!(payout: payout, kind: "verified_return", returned_amount_cents: payout.disbursement_cents,
              returned_at: Time.current, sent_at: payout.paid_at, return_reference_digest: PayoutReturnProof.reference_digest("RET-A2-REV"))
          end
        end
        if immediate
          ActiveRecord::Base.connection.execute("SET CONSTRAINTS payouts_reversal_return_check IMMEDIATE")
          raise ActiveRecord::Rollback
        end
      end
      immediate ? "accepted, rolled back" : payout.reload.status
    end
  end
  raw.call("no audit", nil)
  raw.call("generic audit", { "reconciliation" => { "reference" => "Bank" } })
  raw.call("return key without the exact return", { "verified_return" => { "return_reference" => "RET-A2-REV" } })
  raw.call("return of the wrong amount", { "verified_return" => exact.merge("returned_amount_cents" => 1) })
  raw.call("exact audit without the durable proof", { "verified_return" => exact })
  raw.call("exact return in the same transaction", { "verified_return" => exact }, immediate: true, proof: true)
  Rehearsal.outcome!(step, action: "rev after the refused writers", value: { status: payout.reload.status, available_cents: available.call })
  S.attempt(step, "A2 PayoutReconciler reversed payout_rev_paid (bank's exact return)") do
    PayoutReconciler.call(payout: payout.reload, actor: S.admin, status: "reversed", provider_payout_id: payout.provider_payout_id,
      evidence: S.evidence(Time.current, return_reference: "RET-A2-REV", returned_amount_cents: payout.disbursement_cents,
        returned_at: Time.current.utc.iso8601(6))).reload
  end
  released = available.call
  Rehearsal.outcome!(step, action: "rev after the verified return", value: { status: payout.reload.status, available_cents: released })
  S.attempt(step, "reserve rev for #{released} after the verified return") do
    PayoutCreator.new(settlement: Settlements::Finalizer.call(event: rev, actor: S.admin), actor: S.admin,
      idempotency_key: "a2-rev-after-return", amount_cents: released).send(:reserve!).first
  end

# ---- A2 recheck finding 1 (758485ae): accepted transfers on ordinary events ----
when "n_acc_held"
  # This release submits $10.00 on each; the cancellation hold commits while
  # the gateway call runs and the stubbed provider reports it paid (the
  # stock manual gateway returns processing, so this is a paid-result
  # adapter's path).
  PayoutGateway.singleton_class.prepend(Module.new do
    def submit(payout)
      super
      EventCancellationRefunds.hold_payouts!(payout.event, actor: A2Step.admin)
      PayoutGateway::Result.new(provider_payout_id: "BANK-ACC-#{payout.id}", status: :paid)
    end
  end)
  %w[acc_fail acc_rev].each do |key|
    event = S.find(Event, key)
    settlement = Settlements::Finalizer.call(event: event, actor: S.admin)
    before = OrganizationPayoutBalance.available_cents(event.organization)
    payout = S.attempt(step, "PayoutCreator.call #{key} (provider pays while held)") do
      PayoutCreator.call(settlement: settlement, actor: S.admin, idempotency_key: "a2-#{key}", amount_cents: 1000)
    end
    S.save!("payout_#{key}" => payout.id, "#{key}_available_before" => before)
    payout.reload
    Rehearsal.outcome!(step, action: "#{key} accepted", value: { status: payout.status, held_from: payout.held_from_status,
      failure_code: payout.failure_code, provider_payout_id: payout.provider_payout_id,
      provider_accepted_at: payout.provider_accepted_at&.utc&.iso8601(6), classified: PayoutEntryGuard.affected?(event),
      available_before: before, available_cents: OrganizationPayoutBalance.available_cents(event.organization) })
  end

when "o_acc_a1"
  raise "A1's outcomes run in the previous release" if S.new_release?

  # A1's PayoutReconciler (a0b25ffe) with the conflict acknowledged, as the
  # reviewer ran it; ENV ACC_PHASE names the trial (before or after A2's
  # acceptance record).
  phase = ENV.fetch("ACC_PHASE")
  { "acc_fail" => "failed", "acc_rev" => "reversed" }.each do |key, outcome|
    payout = S.find(Payout, "payout_#{key}")
    conflict = AuditLog.where(auditable_type: "Payout", auditable_id: payout.id, action: "payout.provider_result_conflict").order(:id).last
    S.attempt(step, "A1 PayoutReconciler #{outcome} payout_#{key} (#{phase})") do
      PayoutReconciler.call(payout: payout, actor: S.admin, status: outcome, provider_payout_id: payout.provider_payout_id,
        evidence: S.evidence(Time.current, conflict_audit_id: conflict.id, reason: "Generic bank confirmation")).reload
    end
    S.attempt(step, "A1 PayoutHoldRelease payout_#{key} (#{phase})") { PayoutHoldRelease.call(payout: payout.reload, actor: S.admin) }
    payout.reload
    Rehearsal.outcome!(step, action: "#{key} after A1 #{phase}", value: { status: payout.status, failure_code: payout.failure_code,
      provider_payout_id: payout.provider_payout_id,
      available_cents: OrganizationPayoutBalance.available_cents(payout.organization) })
  end

when "n_acc_ack", "n_acc_return"
  %w[acc_fail acc_rev].each do |key|
    event = S.find(Event, key)
    payout = S.find(Payout, "payout_#{key}")
    conflict = AuditLog.where(auditable: payout, action: "payout.provider_result_conflict").order(:id).last
    before = S.state.fetch("#{key}_available_before")
    S.attempt(step, "PayoutCreator.call #{key} fresh key for $10.00 (#{step})") do
      PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: S.admin), actor: S.admin,
        idempotency_key: "a2-#{key}-fresh-#{step}", amount_cents: 1000)
    end
    if step == "n_acc_ack"
      S.attempt(step, "A2 PayoutReconciler accepted_transfer payout_#{key}") do
        PayoutReconciler.call(payout: payout.reload, actor: S.admin, status: "accepted_transfer",
          provider_payout_id: payout.provider_payout_id, evidence: S.evidence(Time.current, conflict_audit_id: conflict.id)).reload
      end
    else
      S.attempt(step, "A2 PayoutReconciler reversed payout_#{key} (bank's exact return)") do
        PayoutReconciler.call(payout: payout.reload, actor: S.admin, status: "reversed", provider_payout_id: payout.provider_payout_id,
          evidence: S.evidence(Time.current, conflict_audit_id: conflict.id, return_reference: "RET-A2-#{key.upcase}",
            returned_amount_cents: payout.disbursement_cents, returned_at: Time.current.utc.iso8601(6))).reload
      end
      released = OrganizationPayoutBalance.available_cents(event.organization)
      S.attempt(step, "reserve #{key} for #{released} after the verified return") do
        PayoutCreator.new(settlement: Settlements::Finalizer.call(event: event, actor: S.admin), actor: S.admin,
          idempotency_key: "a2-#{key}-after-return", amount_cents: released).send(:reserve!).first
      end
    end
    payout.reload
    Rehearsal.outcome!(step, action: "#{key} after #{step}", value: { status: payout.status, failure_code: payout.failure_code,
      acceptance_recorded: payout.accepted_transfer_recorded_at.present?, available_before: before,
      available_cents: OrganizationPayoutBalance.available_cents(event.organization),
      proof: PayoutReturnProof.find_by(payout_id: payout.id)&.slice(:kind, :returned_amount_cents) })
  end

# ---- CodeRabbit a292e277 (4706251677, 4706251665, 4706251703): a paid ----
# ---- result on a pending payout after a stale cutoff, across versions ----
when "n_acc_stale"
  # The hold opens while the gateway call runs, dated an hour earlier (an
  # exception's hold starts at its creation, as a backdated overlap capture's
  # would), so the submission is after the cutoff; the stubbed provider then
  # reports the transfer paid with no paid time of its own.
  PayoutGateway.singleton_class.prepend(Module.new do
    def submit(payout)
      super
      ReconciliationException.create!(order: payout.event.orders.order(:id).first, code: "unfulfilled_second_capture",
        status: :open, details: {}, created_at: 1.hour.ago)
      PayoutGateway::Result.new(provider_payout_id: "BANK-STALE-#{payout.id}", status: :paid)
    end
  end)
  event = S.find(Event, "acc_stale")
  settlement = Settlements::Finalizer.call(event: event, actor: S.admin)
  before = OrganizationPayoutBalance.available_cents(event.organization)
  payout = S.attempt(step, "PayoutCreator.call acc_stale (provider pays a pending payout after a stale cutoff)") do
    PayoutCreator.call(settlement: settlement, actor: S.admin, idempotency_key: "a2-acc_stale", amount_cents: 1000)
  end
  S.save!("payout_acc_stale" => payout.id, "acc_stale_available_before" => before)
  payout.reload
  conflict = AuditLog.where(auditable: payout, action: "payout.provider_result_conflict").order(:id).last
  submitted = AuditLog.where(auditable: payout, action: "payout.submission_requested").minimum(:occurred_at)
  Rehearsal.outcome!(step, action: "acc_stale accepted", value: { status: payout.status, failure_code: payout.failure_code,
    provider_payout_id: payout.provider_payout_id, basis: payout.provider_accepted_basis,
    provider_accepted_at: payout.provider_accepted_at&.utc&.iso8601(6), submitted_at: submitted&.utc&.iso8601(6),
    cutoff: Commerce::NeverFulfilledPayoutHold.block_started_at(event)&.utc&.iso8601(6),
    refusal: conflict&.metadata&.fetch("refusal", nil), conflict_basis: conflict&.metadata&.fetch("provider_accepted_basis", nil),
    provider_paid_at_claimed: conflict&.metadata&.key?("provider_paid_at"),
    available_cents: OrganizationPayoutBalance.available_cents(event.organization) })
  S.attempt(step, "PayoutCreator.call acc_stale same key") do
    PayoutCreator.call(settlement: payout.settlement, actor: S.admin, idempotency_key: "a2-acc_stale", amount_cents: 1000).id
  end
  S.attempt(step, "PayoutCreator.call acc_stale fresh key for $10.00") do
    PayoutCreator.call(settlement: payout.settlement, actor: S.admin, idempotency_key: "a2-acc_stale-fresh", amount_cents: 1000)
  end
  # Raw SQL on the acknowledgement (4706251703): one update that stamps it
  # and reverses, with the exact proof, and a stamp from outside the
  # audited reconciler path.
  S.attempt(step, "raw SQL stamp and reverse in one update (exact proof)") do
    Payout.transaction do
      FinancialIntegrity.with_payout_return(payout.id) do
        PayoutReturnProof.create!(payout: payout, kind: "accepted_transfer_return", returned_amount_cents: payout.confirmed_check_amount_cents,
          returned_at: Time.current, sent_at: payout.provider_accepted_at, return_reference_digest: PayoutReturnProof.reference_digest("RET-RAW-STALE"))
      end
      Payout.where(id: payout.id).update_all(status: Payout.statuses[:reversed], failure_code: nil,
        accepted_transfer_recorded_at: Time.current)
      ActiveRecord::Base.connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
      raise ActiveRecord::Rollback
    end
    "accepted, rolled back"
  end
  S.attempt(step, "raw SQL acknowledgement stamp outside the reconciler") do
    Payout.transaction do
      Payout.where(id: payout.id).update_all(accepted_transfer_recorded_at: Time.current)
      raise ActiveRecord::Rollback
    end
    "accepted, rolled back"
  end

when "o_acc_stale_a1"
  raise "A1's outcomes run in the previous release" if S.new_release?

  payout = S.find(Payout, "payout_acc_stale")
  conflict = AuditLog.where(auditable_type: "Payout", auditable_id: payout.id, action: "payout.provider_result_conflict").order(:id).last
  %w[failed reversed].each do |outcome|
    S.attempt(step, "A1 PayoutReconciler #{outcome} payout_acc_stale") do
      PayoutReconciler.call(payout: payout.reload, actor: S.admin, status: outcome, provider_payout_id: payout.provider_payout_id,
        evidence: S.evidence(Time.current, conflict_audit_id: conflict.id, reason: "Generic bank confirmation")).reload
    end
  end
  S.attempt(step, "A1 PayoutCreator.call acc_stale same key") do
    PayoutCreator.call(settlement: payout.settlement, actor: S.admin, idempotency_key: "a2-acc_stale", amount_cents: 1000).id
  end
  # Raw downgrades from the A1 process (A1 code after a rollback writes
  # these columns straight to the row).
  { "pending" => { status: Payout.statuses[:pending] },
    "failed" => { status: Payout.statuses[:failed], failure_code: "reconciled_failure" },
    "paid" => { status: Payout.statuses[:paid], paid_at: Time.current, failure_code: nil },
    "reversed" => { status: Payout.statuses[:reversed], failure_code: nil },
    "transfer identifier" => { provider_payout_id: "OTHER-STALE" } }.each do |label, columns|
    S.attempt(step, "A1 raw SQL #{label} payout_acc_stale") do
      Payout.transaction do
        Payout.where(id: payout.id).update_all(columns.merge(updated_at: Time.current))
        ActiveRecord::Base.connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
        raise ActiveRecord::Rollback
      end
      "accepted, rolled back"
    end
  end
  payout.reload
  Rehearsal.outcome!(step, action: "acc_stale after A1", value: { status: payout.status, failure_code: payout.failure_code,
    provider_payout_id: payout.provider_payout_id })

when "n_acc_stale_return"
  payout = S.find(Payout, "payout_acc_stale")
  conflict = AuditLog.where(auditable: payout, action: "payout.provider_result_conflict").order(:id).last
  S.attempt(step, "A2 PayoutReconciler accepted_transfer payout_acc_stale") do
    PayoutReconciler.call(payout: payout.reload, actor: S.admin, status: "accepted_transfer",
      provider_payout_id: payout.provider_payout_id, evidence: S.evidence(Time.current, conflict_audit_id: conflict.id)).reload
  end
  # 4706251665: the marker is only this release's observation; the bank's
  # own transfer time (finance's evidence) lies between the submission
  # request and it, and the return came back before the observation.
  observed = payout.reload.provider_accepted_at
  submitted = AuditLog.where(auditable: payout, action: "payout.submission_requested").minimum(:occurred_at)
  bank_sent = submitted + ((observed - submitted) / 2)
  returned_at = bank_sent + ((observed - bank_sent) / 2)
  returned = { conflict_audit_id: conflict.id, return_reference: "RET A2 STALE 1", returned_amount_cents: payout.disbursement_cents,
    returned_at: returned_at.utc.iso8601(6) }
  S.attempt(step, "A2 reversed payout_acc_stale without the bank's transfer time") do
    PayoutReconciler.call(payout: payout.reload, actor: S.admin, status: "reversed", provider_payout_id: payout.provider_payout_id,
      evidence: S.evidence(Time.current, **returned)).reload
  end
  S.attempt(step, "A2 reversed payout_acc_stale with the bank's transfer time") do
    PayoutReconciler.call(payout: payout.reload, actor: S.admin, status: "reversed", provider_payout_id: payout.provider_payout_id,
      evidence: S.evidence(Time.current, **returned, transfer_sent_at: bank_sent.utc.iso8601(6))).reload
  end
  proof = PayoutReturnProof.find_by(payout_id: payout.id)
  Rehearsal.outcome!(step, action: "acc_stale after the verified return", value: { status: payout.reload.status,
    observed: observed.utc.iso8601(6), bank_sent: bank_sent.utc.iso8601(6), returned_at: returned_at.utc.iso8601(6),
    proof_kind: proof&.kind, proof_sent_at: proof&.sent_at&.utc&.iso8601(6),
    canonical_digest: proof&.return_reference_digest == Digest::SHA256.hexdigest("RETA2STALE1"),
    acceptance_recorded: payout.accepted_transfer_recorded_at.present? })

# ---- A2 recheck finding 2 (8132fe22): acceptances shown only by audit ----
when "n_eo"
  # The only way such a state exists: a direct write (no release records a
  # paid refusal without its marker). acc_eo: in flight with the provider's
  # reference and conflict, committing the organization's whole balance (as
  # the reviewer's fixture did). acc_eo_hist: the audit lands on such a
  # payout already recorded failed. acc_ctl: an ordinary $10.00 in flight.
  record_conflict = lambda do |payout|
    AuditLogger.record!(action: "payout.provider_result_conflict", auditable: payout.reload, actor: S.admin,
      organization: payout.organization, event: payout.event, source: "provider", outcome: "unknown",
      metadata: { conflict_reason: PayoutCreator::PAID_REFUSED_REASON, provider_paid_at: 5.minutes.ago.utc.iso8601(6) })
  end
  %w[acc_eo acc_eo_hist acc_ctl].each do |key|
    event = S.find(Event, key)
    payout = S.submitted(event, key, key == "acc_ctl" ? 1000 : nil)
    S.save!("#{key}_available_with_payout" => OrganizationPayoutBalance.available_cents(event.organization))
    case key
    when "acc_eo"
      Payout.where(id: payout.id).update_all(provider_payout_id: "BANK-EO-#{payout.id}", failure_code: "provider_result_conflict",
        failure_message: "Provider reported payment after a fence")
      record_conflict.call(payout)
    when "acc_eo_hist"
      PayoutReconciler.call(payout: payout.reload, actor: S.admin, status: "failed", provider_payout_id: payout.provider_payout_id,
        evidence: S.evidence(Time.current, reason: "Finance never sent the transfer"))
      record_conflict.call(payout)
    end
    payout.reload
    Rehearsal.outcome!(step, action: "#{key} prepared", value: { status: payout.status, failure_code: payout.failure_code,
      provider_payout_id: payout.provider_payout_id, marker: payout.provider_accepted_at.present?,
      evidence_only: PayoutCreator.evidence_only_acceptance?(payout),
      available_cents: OrganizationPayoutBalance.available_cents(event.organization) })
  end

when "o_eo_a1"
  raise "A1's outcomes run in the previous release" if S.new_release?

  conflict_of = ->(payout) { AuditLog.where(auditable_type: "Payout", auditable_id: payout.id, action: "payout.provider_result_conflict").order(:id).last }
  payout = S.find(Payout, "payout_acc_eo")
  # The reviewer's reproduction: A1's reconciler records it failed (its
  # generic outcome, with the conflict acknowledged), then reversed.
  %w[failed reversed].each do |outcome|
    S.attempt(step, "A1 PayoutReconciler #{outcome} payout_acc_eo") do
      PayoutReconciler.call(payout: payout.reload, actor: S.admin, status: outcome, provider_payout_id: payout.provider_payout_id,
        evidence: S.evidence(Time.current, conflict_audit_id: conflict_of.call(payout).id, reason: "Generic bank confirmation")).reload
    end
  end
  { "pending" => { status: Payout.statuses[:pending] },
    "failed" => { status: Payout.statuses[:failed], failure_code: "reconciled_failure" },
    "paid" => { status: Payout.statuses[:paid], paid_at: Time.current, failure_code: nil },
    "reversed" => { status: Payout.statuses[:reversed], failure_code: nil },
    "transfer identifier" => { provider_payout_id: "OTHER-EO" } }.each do |label, columns|
    S.attempt(step, "A1 raw SQL #{label} payout_acc_eo") do
      Payout.transaction do
        Payout.where(id: payout.id).update_all(columns.merge(updated_at: Time.current))
        ActiveRecord::Base.connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
        raise ActiveRecord::Rollback
      end
      "accepted, rolled back"
    end
  end
  S.attempt(step, "A1 raw SQL delete payout_acc_eo") do
    Payout.transaction do
      Payout.where(id: payout.id).delete_all
      raise ActiveRecord::Rollback
    end
    "accepted, rolled back"
  end
  # Fresh keys from A1 (its reserve and submission).
  %w[acc_eo acc_eo_hist acc_ctl].each do |key|
    event = S.find(Event, key)
    S.attempt(step, "A1 PayoutCreator.call #{key} fresh key for $10.00") do
      settlement = Settlements::Finalizer.call(event: event, actor: S.admin)
      PayoutCreator.call(settlement: settlement, actor: S.admin, idempotency_key: "a2-#{key}-a1-fresh", amount_cents: 1000)
    end
  end
  # The control: A1's ordinary failed outcome on a payout with no acceptance.
  control = S.find(Payout, "payout_acc_ctl")
  S.attempt(step, "A1 PayoutReconciler failed payout_acc_ctl") do
    PayoutReconciler.call(payout: control.reload, actor: S.admin, status: "failed", provider_payout_id: control.provider_payout_id,
      evidence: S.evidence(Time.current, reason: "Finance never sent the transfer")).reload
  end
  payout.reload
  Rehearsal.outcome!(step, action: "acc_eo after A1", value: { status: payout.status, failure_code: payout.failure_code,
    provider_payout_id: payout.provider_payout_id,
    available_cents: OrganizationPayoutBalance.available_cents(payout.organization) })

when "n_eo_after"
  payout = S.find(Payout, "payout_acc_eo")
  conflict = AuditLog.where(auditable: payout, action: "payout.provider_result_conflict").order(:id).last
  %w[accepted_transfer failed paid].each do |outcome|
    S.attempt(step, "A2 PayoutReconciler #{outcome} payout_acc_eo") do
      PayoutReconciler.call(payout: payout.reload, actor: S.admin, status: outcome, provider_payout_id: payout.provider_payout_id,
        evidence: S.evidence(Time.current, conflict_audit_id: conflict.id)).reload
    end
  end
  %w[acc_eo acc_eo_hist acc_ctl].each do |key|
    event = S.find(Event, key)
    S.attempt(step, "A2 PayoutCreator.call #{key} fresh key for $10.00") do
      settlement = Settlements::Finalizer.call(event: event, actor: S.admin)
      PayoutCreator.call(settlement: settlement, actor: S.admin, idempotency_key: "a2-#{key}-a2-fresh", amount_cents: 1000)
    end
  end
  state = %w[acc_eo acc_eo_hist acc_ctl].to_h do |key|
    event = S.find(Event, key)
    [key, { payouts: event.payouts.order(:id).map { |p| [p.idempotency_key, p.status] },
      available_cents: OrganizationPayoutBalance.available_cents(event.organization) }]
  end
  Rehearsal.outcome!(step, action: "evidence-only state", value: state.merge("acc_eo_status" => payout.reload.status,
    "acc_eo_identifier" => payout.provider_payout_id))

# ---- A2 recheck of bca5f904: audit-only acceptance at submission ----
when "o_sub_reserve"
  raise "A1 reserves in the previous release" if S.new_release?

  reserve = lambda do |key, name|
    settlement = Settlements::Finalizer.call(event: S.find(Event, key), actor: S.admin)
    PayoutCreator.new(settlement: settlement, actor: S.admin, idempotency_key: "a1-#{name}", amount_cents: 1000)
      .send(:reserve!).first.tap { |payout| S.save!("payout_#{name}" => payout.id) }
  end
  S.attempt(step, "A1 reserve sub_eo") { reserve.call("sub_eo", "sub_eo") }
  S.attempt(step, "A1 reserve sub_lock") { reserve.call("sub_lock", "sub_lock") }
  # sub_org: an ordinary A1 payout, recorded failed by A1, then a reservation.
  first = S.attempt(step, "A1 PayoutCreator.call sub_org first") do
    settlement = Settlements::Finalizer.call(event: S.find(Event, "sub_org"), actor: S.admin)
    PayoutCreator.call(settlement: settlement, actor: S.admin, idempotency_key: "a1-sub_org_first", amount_cents: 1000)
      .tap { |payout| S.save!("payout_sub_org_first" => payout.id) }
  end
  S.attempt(step, "A1 PayoutReconciler failed sub_org first") do
    PayoutReconciler.call(payout: first.reload, actor: S.admin, status: "failed", provider_payout_id: first.provider_payout_id,
      evidence: S.evidence(Time.current, reason: "Finance never sent the transfer")).reload
  end
  S.attempt(step, "A1 reserve sub_org") { reserve.call("sub_org", "sub_org") }

when "n_sub_evidence"
  # The synthetic evidence (no released writer records it): a paid-refusal
  # audit on sub_eo's pending reservation and on sub_org's failed payout.
  { "payout_sub_eo" => "sub_eo", "payout_sub_org_first" => "sub_org" }.each do |payout_key, label|
    payout = S.find(Payout, payout_key)
    AuditLogger.record!(action: "payout.provider_result_conflict", auditable: payout, actor: S.admin,
      organization: payout.organization, event: payout.event, source: "provider", outcome: "unknown",
      metadata: { conflict_reason: PayoutCreator::PAID_REFUSED_REASON, provider_paid_at: 5.minutes.ago.utc.iso8601(6) })
    Rehearsal.outcome!(step, action: "#{label} evidence", value: { payout_status: payout.reload.status,
      evidence_only: PayoutCreator.evidence_only_acceptance?(payout),
      organization_uncommitted: PayoutCreator.uncommitted_evidence_only_acceptance?(payout.organization) })
  end

when "o_sub_a1", "n_sub_a2"
  release = S.new_release? ? "A2" : "A1"
  %w[sub_eo sub_org].each do |key|
    payout = S.find(Payout, "payout_#{key}")
    S.attempt(step, "#{release} submit_payout! #{key}") do
      PayoutCreator.new(settlement: payout.settlement, actor: S.admin, idempotency_key: payout.idempotency_key)
        .send(:submit_payout!, payout.reload)
      "submitted"
    end
    S.attempt(step, "#{release} PayoutCreator.call #{key} same key") do
      PayoutCreator.call(settlement: payout.settlement, actor: S.admin, idempotency_key: payout.idempotency_key)
    end
    payout.reload
    Rehearsal.outcome!(step, action: "#{release} #{key} after", value: { status: payout.status,
      authorizations: AuditLog.where(auditable: payout, action: "payout.submission_requested").count })
  end

when "n_sub_lock_hold"
  # Holds sub_lock's event exactly as the database's payout fences lock it
  # (FOR NO KEY UPDATE) and, in the same transaction, records the evidence;
  # paused before its commit while A1's submission waits on the event.
  payout = S.find(Payout, "payout_sub_lock")
  ActiveRecord::Base.transaction do
    Event.where(id: payout.event_id).lock("FOR NO KEY UPDATE").pick(:id)
    AuditLogger.record!(action: "payout.provider_result_conflict", auditable: payout, actor: S.admin,
      organization: payout.organization, event: payout.event, source: "provider", outcome: "unknown",
      metadata: { conflict_reason: PayoutCreator::PAID_REFUSED_REASON, provider_paid_at: 5.minutes.ago.utc.iso8601(6) })
    Rehearsal.pause("sub_lock_evidence")
  end
  Rehearsal.outcome!(step, action: "sub_lock evidence committed", value: { status: payout.reload.status })

when "o_sub_lock_submit"
  raise "A1 submits in the previous release" if S.new_release?

  payout = S.find(Payout, "payout_sub_lock")
  Rehearsal.mark("sub_lock_submit")
  S.attempt(step, "A1 submit_payout! sub_lock (waits on the event)") do
    PayoutCreator.new(settlement: payout.settlement, actor: S.admin, idempotency_key: payout.idempotency_key)
      .send(:submit_payout!, payout.reload)
    "submitted"
  end
  Rehearsal.outcome!(step, action: "A1 sub_lock after", value: { status: payout.reload.status,
    authorizations: AuditLog.where(auditable: payout, action: "payout.submission_requested").count })

# ---- A2 recheck of bca5f904: audit-only acceptance through retention ----
when "n_ret_prepare"
  # ret_eo / ret_eo2: A2's ordinary $10.00, recorded failed, then written
  # reversed (the reviewer's synthetic reversed payout), then an expired
  # paid-refusal audit. ret_ctl: the same with an expired ordinary conflict.
  keys = ENV.fetch("RET_KEYS").split(",")
  expired = Time.zone.local(Time.current.year - 8, 6, 1)
  keys.each do |key|
    event = S.find(Event, key)
    payout = S.submitted(event, key, 1000)
    PayoutReconciler.call(payout: payout.reload, actor: S.admin, status: "failed", provider_payout_id: payout.provider_payout_id,
      evidence: S.evidence(Time.current, reason: "Finance never sent the transfer"))
    Payout.where(id: payout.id).update_all(status: Payout.statuses[:reversed], updated_at: Time.current)
    reason = key == "ret_ctl" ? "provider_result_after_hold" : PayoutCreator::PAID_REFUSED_REASON
    audit = AuditLog.create!(action: "payout.provider_result_conflict", auditable: payout, organization: event.organization,
      event: event, actor_user: S.admin, source: "provider", outcome: "unknown", occurred_at: expired, created_at: expired,
      metadata: { conflict_reason: reason, provider_payout_id: "BANK-RET-#{payout.id}", refusal: "Synthetic fixture" })
    S.save!("#{key}_audit" => audit.id)
    # The control reserves only after retention: an in-flight payout keeps
    # its organization's audit trail protected (RetentionGuard).
    next Rehearsal.outcome!(step, action: "#{key} prepared", value: { status: payout.reload.status, metadata: audit.reload.metadata }) if key == "ret_ctl"

    S.attempt(step, "A2 PayoutCreator.call #{key} fresh key before retention") do
      settlement = Settlements::Finalizer.call(event: event, actor: S.admin)
      PayoutCreator.call(settlement: settlement, actor: S.admin, idempotency_key: "a2-#{key}-pre", amount_cents: 1000)
    end
    Rehearsal.outcome!(step, action: "#{key} prepared", value: { status: payout.reload.status, metadata: audit.reload.metadata,
      available_cents: OrganizationPayoutBalance.available_cents(event.organization) })
  end

when "x_ret_job"
  # The scheduled retention job of this process's release, destructive
  # (DATA_RETENTION_DESTRUCTIVE_ENABLED=true from the driver).
  SiteSetting.instance.update_columns(retention_purge_enabled: true)
  release = S.new_release? ? "A2" : "A1"
  counts = S.attempt(step, "#{release} DataRetentionPurgeJob (destructive)") do
    raise "destructive retention not enabled" if DataRetention.dry_run?

    DataRetentionPurgeJob.perform_now.to_h.slice("audit_logs")
  end
  SiteSetting.instance.update_columns(retention_purge_enabled: false)
  audits = %w[ret_eo ret_eo2 ret_ctl].filter_map { |key| S.state["#{key}_audit"] && [key, AuditLog.find(S.state["#{key}_audit"])] }
  Rehearsal.outcome!(step, action: "#{release} audits after the job", value: audits.to_h do |key, audit|
    [key, { metadata: audit.metadata, anonymized: audit.retention_anonymized_at.present? }]
  end.merge("counts" => counts))

when "x_ret_after"
  release = S.new_release? ? "A2" : "A1"
  %w[ret_eo ret_eo2 ret_ctl].each do |key|
    event = S.find(Event, key)
    if S.new_release?
      # A rebound payout account changes nothing.
      S.attempt(step, "A2 rebind #{key} payout account") do
        S.approved_bank_account!(event.organization, actor: User.find(S.state.fetch("#{key}_owner")), admin: S.admin,
          last_four: "24#{%w[ret_eo ret_eo2 ret_ctl].index(key)}8").id
      end
    end
    S.attempt(step, "#{release} PayoutCreator.call #{key} fresh key after retention") do
      settlement = Settlements::Finalizer.call(event: event, actor: S.admin)
      PayoutCreator.call(settlement: settlement, actor: S.admin, idempotency_key: "#{release.downcase}-#{key}-post", amount_cents: 1000)
    end
  end
  Rehearsal.outcome!(step, action: "#{release} retention state", value: %w[ret_eo ret_eo2 ret_ctl].to_h do |key|
    event = S.find(Event, key)
    [key, { payouts: event.payouts.order(:id).map { |p| [p.idempotency_key, p.status] },
      metadata: AuditLog.find(S.state.fetch("#{key}_audit")).metadata }]
  end)

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

  # CodeRabbit 4704013214: the P4 episode start across A1 and this release.
  opened = find_outcome.call("old", "o_p4_episode", "p4 opened by A1")&.fetch("value").to_h
  start = opened["block_start"]
  check.call("P4 episode: A1's over-return opened after the anchor with its proof checked and failed by the database",
    opened["created_at"] && opened["created_at"] > S.state.fetch("p4_anchor") && opened["proof_checked_at"] &&
      opened["hold_started_at"] == opened["proof_checked_at"])
  check.call("P4 episode: the hold starts at the opening (#{start})", start && start == [opened["created_at"], opened["hold_started_at"]].min)
  check.call("P4 episode: a newer pending refund keeps the start",
    find_outcome.call("old", "o_p4_episode", "p4 newer pending refund")&.dig("value", "block_start") == start)
  posted = find_outcome.call("old", "o_p4_episode", "p4 first refund posted")&.fetch("value").to_h
  check.call("P4 episode: the first refund posting (by A1) while the newer one is pending keeps the start",
    posted["first_posted"] == true && posted["block_start"] == start)
  check.call("P4 episode: A1 cannot record paid", refused.call("old", "o_p4_episode",
    "PayoutReconciler paid payout_p4_pre (A1 paid before the opening)"))
  fence = find_outcome.call("new", "n_p4_paid", "p4 database fence")&.fetch("value").to_h
  check.call("P4 episode: database fence accepts a bank time 1 µs before the start, refuses after the opening and at it",
    fence["cutoff"] == start && fence["pre_before"] == "accepted" && fence["at_between"].to_s.include?("before the hold") &&
      fence["post_at_cutoff"].to_s.include?("before the hold"))
  check.call("P4 episode: after the newer refund posts, a linked debit keeps the same start",
    find_outcome.call("new", "n_p4_paid", "p4 after the newer refund posted")&.fetch("value") == { "block_start" => start, "pending_refunds" => 0 })
  check.call("P4 episode: reconciler refuses the transfer at the start and after the opening", refused.call("new", "n_p4_paid",
    "PayoutReconciler paid payout_p4_post (transfer at the cutoff)", /sent before the hold/) &&
    refused.call("new", "n_p4_paid", "PayoutReconciler paid payout_p4_at (transfer after the opening)", /sent before the hold/))
  pre = Payout.find(id.call("payout_p4_pre"))
  check.call("P4 episode: reconciler records the transfer 1 µs before the start with custody",
    ok.call("new", "n_p4_paid", "PayoutReconciler paid payout_p4_pre (transfer just before the cutoff)") && pre.status_paid? &&
      pre.paid_at.utc.iso8601(6) == (Time.iso8601(start) - 0.000001).utc.iso8601(6) &&
      PayoutCustodyDetermination.exists?(payout_id: pre.id, basis: "recorded_at_paid"))

  # A2 recheck finding 1 (7664e143): A1's generic reversal during the overlap.
  rev_paid = find_outcome.call("new", "n_rev_paid", "rev paid")&.fetch("value").to_h
  before = S.state.fetch("rev_available_before")
  check.call("reversal: the $10 payout was paid from an A2 version with the capture's $0 line (available #{before})",
    rev_paid["version_reader"] == "nfc-a2" && rev_paid["version_restated_at"].nil? &&
      ok.call("new", "n_rev_paid", "PayoutReconciler paid payout_rev_paid (A2 paid on a version with the $0 line)"))
  # CodeRabbit 4705527099: that version holds the classified capture's line
  # exactly once, and it contributes $0.
  check.call("reversal: the funded version has the classified capture's line exactly once, at $0",
    rev_paid["captured_payment_ids"].to_a.size == 1 &&
      rev_paid["capture_lines"] == [{ "amount_cents" => 0, "payment_ids" => rev_paid["captured_payment_ids"] }])
  check.call("reversal: A1's generic reversal is refused by the database at commit",
    refused.call("old", "o_rev_a1_reverse", "A1 PayoutReconciler reversed payout_rev_paid (generic confirmation)",
      /Payout reversal fence: payout #{id.call('payout_rev_paid')}/))
  after_a1 = find_outcome.call("new", "n_rev_after", "rev after the A1 attempt")&.fetch("value").to_h
  check.call("reversal: after A1's attempt the payout is still paid and available stays #{before}",
    after_a1 == { "status" => "paid", "available_cents" => before } &&
      find_outcome.call("old", "o_rev_a1_reverse", "rev after A1 reversal")&.dig("value", "status") == "paid")
  race = find_outcome.call("new", "n_rev_reserve_race", "rev race waited")&.fetch("value").to_h
  # CodeRabbit 4705527122: the overlap is shown by the database, not a
  # timer. The driver saw the candidate's backend (its marker's pid) in
  # pg_blocking_pids blocked by A1's paused reversal (its pid) before it
  # released A1; the candidate's timer started at its own marker.
  blocking = File.read(File.join(Rehearsal::DIR, "rev_reserve_blocking.txt")).strip rescue ""
  waiter = File.read(File.join(Rehearsal::DIR, "rev_reserve.reached")).strip rescue ""
  holder = File.read(File.join(Rehearsal::DIR, "reversal_audit_holder.pid")).strip rescue ""
  blocked = blocking.match(/\Awaiter=(\d+) blocked_by=([\d,]+) /)
  check.call("reversal: a fresh A2 payout for #{before + 1000} during A1's open reversal waited on A1's locks " \
      "(pg_blocking_pids: #{blocking}) and was refused",
    blocked && blocked[1] == waiter && holder.match?(/\A\d+\z/) && blocked[2].split(",").include?(holder) &&
      race["seconds"].to_f.positive? && refused.call("new", "n_rev_reserve_race",
        "PayoutCreator.call rev for #{before + 1000} (would need the released $10)", /available balance/))
  check.call("reversal: the same fresh payout after A1's attempt is refused", refused.call("new", "n_rev_after",
    "PayoutCreator.call rev for #{before + 1000} after the A1 attempt", /available balance/))
  check.call("reversal: A2's generic reversal is refused", refused.call("new", "n_rev_after",
    "A2 PayoutReconciler reversed payout_rev_paid (generic confirmation)", /return evidence/))
  ["no audit", "generic audit", "return key without the exact return", "return of the wrong amount",
    "exact audit without the durable proof"].each do |label|
    check.call("reversal: raw SQL (#{label}) refused at commit", refused.call("new", "n_rev_after", "raw SQL reversal (#{label})",
      /Payout reversal fence/))
  end
  exact_raw = find_outcome.call("new", "n_rev_after", "raw SQL reversal (exact return in the same transaction)")
  check.call("reversal: raw SQL with the exact return in the same transaction passes the fence",
    exact_raw&.fetch("result") == "ok" && exact_raw["value"] == "accepted, rolled back")
  check.call("reversal: still paid and #{before} available after every refused writer",
    find_outcome.call("new", "n_rev_after", "rev after the refused writers")&.fetch("value") == { "status" => "paid", "available_cents" => before })
  returned = find_outcome.call("new", "n_rev_after", "rev after the verified return")&.fetch("value").to_h
  check.call("reversal: the bank's exact return through A2 reverses it and releases exactly $10 (#{before} -> #{before + 1000})",
    ok.call("new", "n_rev_after", "A2 PayoutReconciler reversed payout_rev_paid (bank's exact return)") &&
      returned == { "status" => "reversed", "available_cents" => before + 1000 } &&
      AuditLog.where(auditable_type: "Payout", auditable_id: id.call("payout_rev_paid"), action: "payout.reconciled")
        .where("after_data->>'status' = 'reversed'").sole.metadata.key?("verified_return") &&
      PayoutReturnProof.where(payout_id: id.call("payout_rev_paid"), kind: "verified_return").exists?)
  check.call("reversal: the released amount can then be reserved", ok.call("new", "n_rev_after",
    "reserve rev for #{before + 1000} after the verified return"))
  rev_event = S.find(Event, "rev").id
  check.call("gateway: one submission on the reversal event (the paid $10)",
    calls.count { |c| Payout.find_by(id: c["payout_id"])&.event_id == rev_event } == 1)

  # A2 recheck finding 1 (758485ae): A1 on accepted transfers, ordinary events.
  %w[acc_fail acc_rev].each do |key|
    outcome = key == "acc_fail" ? "failed" : "reversed"
    accepted = find_outcome.call("new", "n_acc_held", "#{key} accepted")&.fetch("value").to_h
    payout_id = id.call("payout_#{key}")
    check.call("accepted #{key}: the $10.00 paid result while held is an accepted transfer on an ordinary event",
      accepted["status"] == "held" && accepted["held_from"] == "processing" && accepted["failure_code"] == "provider_result_conflict" &&
        accepted["provider_payout_id"] == "BANK-ACC-#{payout_id}" && accepted["provider_accepted_at"] && accepted["classified"] == false)
    before = accepted["available_before"]
    %w[before_ack after_ack].each do |phase|
      check.call("accepted #{key}: A1's #{outcome} (#{phase}) refused by the database",
        refused.call("old", "o_acc_a1", "A1 PayoutReconciler #{outcome} payout_#{key} (#{phase})",
          /(Accepted transfer|Payout reversal) fence: payout #{payout_id}/))
      check.call("accepted #{key}: A1's hold release (#{phase}) refused",
        refused.call("old", "o_acc_a1", "A1 PayoutHoldRelease payout_#{key} (#{phase})", /conflict/))
      after = find_outcome.call("old", "o_acc_a1", "#{key} after A1 #{phase}")&.fetch("value").to_h
      check.call("accepted #{key}: after A1 (#{phase}) still held under its conflict, identity kept, balance not released",
        after["status"] == "held" && after["failure_code"] == "provider_result_conflict" &&
          after["provider_payout_id"] == "BANK-ACC-#{payout_id}" && after["available_cents"].to_i < before)
    end
    %w[n_acc_ack n_acc_return].each do |name|
      check.call("accepted #{key}: a fresh key for $10.00 is refused at #{name} (shortfall)",
        refused.call("new", name, "PayoutCreator.call #{key} fresh key for $10.00 (#{name})", /available balance|must be positive|exceeds/))
    end
    check.call("accepted #{key}: A2 records the acceptance", ok.call("new", "n_acc_ack", "A2 PayoutReconciler accepted_transfer payout_#{key}") &&
      find_outcome.call("new", "n_acc_ack", "#{key} after n_acc_ack")&.dig("value", "acceptance_recorded") == true)
    returned = find_outcome.call("new", "n_acc_return", "#{key} after n_acc_return")&.fetch("value").to_h
    check.call("accepted #{key}: the bank's exact return through A2 reverses it with its accepted-transfer proof",
      ok.call("new", "n_acc_return", "A2 PayoutReconciler reversed payout_#{key} (bank's exact return)") &&
        returned["status"] == "reversed" && returned["proof"] == { "kind" => "accepted_transfer_return", "returned_amount_cents" => 1000 })
    check.call("accepted #{key}: the released amount (#{before}) can then be reserved once",
      ok.call("new", "n_acc_return", "reserve #{key} for #{before} after the verified return"))
    event_id = id.call(key)
    check.call("gateway: one submission on the #{key} event (the accepted $10.00)",
      calls.count { |c| Payout.find_by(id: c["payout_id"])&.event_id == event_id } == 1)
  end

  # CodeRabbit a292e277: the pending acceptance after a stale cutoff.
  stale = find_outcome.call("new", "n_acc_stale", "acc_stale accepted")&.fetch("value").to_h
  stale_id = id.call("payout_acc_stale")
  check.call("acc_stale: the submission came after the hold's cutoff (both fences refuse it)",
    stale["cutoff"].present? && stale["submitted_at"].present? && Time.iso8601(stale["cutoff"]) < Time.iso8601(stale["submitted_at"]))
  check.call("acc_stale: the provider's paid result committed as an accepted transfer on the pending row",
    stale["status"] == "processing" && stale["failure_code"] == "provider_result_conflict" &&
      stale["provider_payout_id"] == "BANK-STALE-#{stale_id}" && stale["provider_accepted_at"].present? &&
      stale["refusal"].to_s.match?(/Repayment fence: payout #{stale_id} needs verified transfer evidence/))
  check.call("acc_stale: the marker is recorded as this release's observation, never as the provider's time",
    stale["basis"] == "locally_observed" && stale["conflict_basis"] == "locally_observed" && stale["provider_paid_at_claimed"] == false)
  check.call("acc_stale: the same key returns the payout (A2) without a new submission",
    find_outcome.call("new", "n_acc_stale", "PayoutCreator.call acc_stale same key")&.fetch("value") == stale_id)
  check.call("acc_stale: a fresh key for $10.00 is refused",
    refused.call("new", "n_acc_stale", "PayoutCreator.call acc_stale fresh key for $10.00"))
  check.call("acc_stale: one update stamping the acknowledgement and reversing is refused",
    refused.call("new", "n_acc_stale", "raw SQL stamp and reverse in one update (exact proof)", /Accepted transfer fence: payout #{stale_id}/))
  check.call("acc_stale: an acknowledgement stamp outside the reconciler is refused",
    refused.call("new", "n_acc_stale", "raw SQL acknowledgement stamp outside the reconciler",
      /only from the current release's reconciler/))
  %w[failed reversed].each do |outcome|
    check.call("acc_stale: A1's #{outcome} refused by the database",
      refused.call("old", "o_acc_stale_a1", "A1 PayoutReconciler #{outcome} payout_acc_stale", /(Accepted transfer|Payout reversal) fence: payout #{stale_id}/))
  end
  check.call("acc_stale: A1's same key returns the payout without a new submission",
    find_outcome.call("old", "o_acc_stale_a1", "A1 PayoutCreator.call acc_stale same key")&.fetch("value") == stale_id)
  ["pending", "failed", "paid", "reversed", "transfer identifier"].each do |label|
    check.call("acc_stale: A1-process raw SQL #{label} refused",
      refused.call("old", "o_acc_stale_a1", "A1 raw SQL #{label} payout_acc_stale", /Accepted transfer fence: payout #{stale_id}/))
  end
  after_stale_a1 = find_outcome.call("old", "o_acc_stale_a1", "acc_stale after A1")&.fetch("value").to_h
  check.call("acc_stale: after A1 still processing under its conflict with its identity",
    after_stale_a1 == { "status" => "processing", "failure_code" => "provider_result_conflict", "provider_payout_id" => "BANK-STALE-#{stale_id}" })
  stale_return = find_outcome.call("new", "n_acc_stale_return", "acc_stale after the verified return")&.fetch("value").to_h
  check.call("acc_stale: A2 records the acceptance", ok.call("new", "n_acc_stale_return", "A2 PayoutReconciler accepted_transfer payout_acc_stale") &&
    stale_return["acceptance_recorded"] == true)
  check.call("acc_stale: a return before the observation is refused without the bank's transfer time",
    refused.call("new", "n_acc_stale_return", "A2 reversed payout_acc_stale without the bank's transfer time", /after the provider accepted/))
  check.call("acc_stale: with the bank's earlier transfer time the exact return reverses it, proof sent at that time",
    ok.call("new", "n_acc_stale_return", "A2 reversed payout_acc_stale with the bank's transfer time") &&
      stale_return["status"] == "reversed" && stale_return["proof_kind"] == "accepted_transfer_return" &&
      stale_return["proof_sent_at"] == stale_return["bank_sent"] &&
      Time.iso8601(stale_return["returned_at"]) < Time.iso8601(stale_return["observed"]))
  check.call("acc_stale: the return reference is stored by its canonical digest (spacing removed)", stale_return["canonical_digest"] == true)
  stale_event = id.call("acc_stale")
  check.call("gateway: one submission on the acc_stale event",
    calls.count { |c| Payout.find_by(id: c["payout_id"])&.event_id == stale_event } == 1)

  # A2 recheck finding 2 (8132fe22): acceptances shown only by their audit.
  eo_id = id.call("payout_acc_eo")
  prepared = %w[acc_eo acc_eo_hist acc_ctl].to_h { |key| [key, find_outcome.call("new", "n_eo", "#{key} prepared")&.fetch("value").to_h] }
  check.call("acc_eo: the synthetic acceptance is in flight, evidence-only, with no marker",
    prepared["acc_eo"].slice("status", "failure_code", "marker", "evidence_only") ==
      { "status" => "processing", "failure_code" => "provider_result_conflict", "marker" => false, "evidence_only" => true })
  check.call("acc_eo_hist: the recognized conflict sits on a failed payout",
    prepared["acc_eo_hist"].slice("status", "evidence_only") == { "status" => "failed", "evidence_only" => true })
  %w[failed reversed].each do |outcome|
    check.call("acc_eo: A1's reconciler #{outcome} refused",
      refused.call("old", "o_eo_a1", "A1 PayoutReconciler #{outcome} payout_acc_eo", /fence|Cannot|cannot|transition|reversed/))
  end
  check.call("acc_eo: A1's reconciler failed refused by the database (the reviewer's reproduction)",
    refused.call("old", "o_eo_a1", "A1 PayoutReconciler failed payout_acc_eo",
      /Accepted transfer fence: payout #{eo_id} has a provider acceptance recorded only in its audit trail/))
  ["pending", "failed", "paid", "reversed", "transfer identifier", "delete"].each do |label|
    check.call("acc_eo: A1-process raw SQL #{label} refused",
      refused.call("old", "o_eo_a1", "A1 raw SQL #{label} payout_acc_eo", /payout #{eo_id} has a provider acceptance recorded only in its audit trail/))
  end
  after_eo = find_outcome.call("old", "o_eo_a1", "acc_eo after A1")&.fetch("value").to_h
  check.call("acc_eo: after A1 still processing under its conflict with its identity, balance not released",
    after_eo.slice("status", "failure_code", "provider_payout_id") ==
      { "status" => "processing", "failure_code" => "provider_result_conflict", "provider_payout_id" => "BANK-EO-#{eo_id}" } &&
      after_eo["available_cents"] == prepared["acc_eo"]["available_cents"])
  check.call("acc_eo: A1's fresh key for $10.00 is refused",
    refused.call("old", "o_eo_a1", "A1 PayoutCreator.call acc_eo fresh key for $10.00"))
  check.call("acc_eo_hist: A1's fresh key for $10.00 is refused by the database",
    refused.call("old", "o_eo_a1", "A1 PayoutCreator.call acc_eo_hist fresh key for $10.00",
      /this organization has a provider acceptance recorded only in its audit trail/))
  check.call("acc_ctl: A1's ordinary failed outcome and a fresh key on the control are allowed",
    ok.call("old", "o_eo_a1", "A1 PayoutReconciler failed payout_acc_ctl") &&
      ok.call("old", "o_eo_a1", "A1 PayoutCreator.call acc_ctl fresh key for $10.00"))
  %w[accepted_transfer failed paid].each do |outcome|
    check.call("acc_eo: A2's #{outcome} refused (escalate)",
      refused.call("new", "n_eo_after", "A2 PayoutReconciler #{outcome} payout_acc_eo", /audit trail, without the durable acceptance marker/))
  end
  check.call("acc_eo: A2's fresh key for $10.00 is refused",
    refused.call("new", "n_eo_after", "A2 PayoutCreator.call acc_eo fresh key for $10.00"))
  check.call("acc_eo_hist: A2's fresh key for $10.00 is refused (no reservation for the organization)",
    refused.call("new", "n_eo_after", "A2 PayoutCreator.call acc_eo_hist fresh key for $10.00", /no longer committed/))
  check.call("acc_ctl: A2's fresh key on the control is allowed",
    ok.call("new", "n_eo_after", "A2 PayoutCreator.call acc_ctl fresh key for $10.00"))
  eo_state = find_outcome.call("new", "n_eo_after", "evidence-only state")&.fetch("value").to_h
  check.call("acc_eo and acc_eo_hist: no payout beyond the prepared one; acc_eo still processing with its identity",
    eo_state.dig("acc_eo", "payouts") == [["a2-acc_eo", "processing"]] && eo_state.dig("acc_eo_hist", "payouts") == [["a2-acc_eo_hist", "failed"]] &&
      eo_state["acc_eo_status"] == "processing" && eo_state["acc_eo_identifier"] == "BANK-EO-#{eo_id}")
  check.call("gateway: one submission each on acc_eo and acc_eo_hist, three on the control",
    %w[acc_eo acc_eo_hist].all? { |key| calls.count { |c| Payout.find_by(id: c["payout_id"])&.event_id == id.call(key) } == 1 } &&
      calls.count { |c| Payout.find_by(id: c["payout_id"])&.event_id == id.call("acc_ctl") } == 3)

  # A2 recheck of bca5f904, finding 1: the submission authorization.
  check.call("sub: A1 reserved sub_eo, sub_lock and sub_org before the evidence (sub_org's first payout failed)",
    %w[sub_eo sub_lock sub_org].all? { |key| ok.call("old", "o_sub_reserve", "A1 reserve #{key}") } &&
      ok.call("old", "o_sub_reserve", "A1 PayoutReconciler failed sub_org first"))
  sub_eo_id = id.call("payout_sub_eo")
  check.call("sub_eo: A1's authorization of its own audit-only acceptance refused by the database before the gateway",
    refused.call("old", "o_sub_a1", "A1 submit_payout! sub_eo",
      /Accepted transfer fence: payout #{sub_eo_id} has a recorded provider acceptance; it is never submitted again/))
  check.call("sub_org: A1's authorization refused while the organization's failed payout has an audit-only acceptance",
    refused.call("old", "o_sub_a1", "A1 submit_payout! sub_org",
      /this organization has a provider acceptance recorded only in its audit trail that is no longer committed; no payout is submitted/))
  check.call("sub: A1's same-key replays return without a submission",
    %w[sub_eo sub_org].all? { |key| ok.call("old", "o_sub_a1", "A1 PayoutCreator.call #{key} same key") })
  check.call("sub_eo: A2 refuses the submission (already accepted)",
    refused.call("new", "n_sub_a2", "A2 submit_payout! sub_eo", /provider acceptance is already recorded/))
  check.call("sub_org: A2 refuses the submission (organization's uncommitted acceptance)",
    refused.call("new", "n_sub_a2", "A2 submit_payout! sub_org", /No payout is submitted until finance approves/))
  check.call("sub_eo and sub_org: still pending, no authorization written",
    %w[sub_eo sub_org].all? do |key|
      %w[old new].all? do |role|
        row = find_outcome.call(role, role == "old" ? "o_sub_a1" : "n_sub_a2", "#{role == 'old' ? 'A1' : 'A2'} #{key} after")
        row&.dig("value") == { "status" => "pending", "authorizations" => 0 }
      end
    end)
  lock_after = find_outcome.call("old", "o_sub_lock_submit", "A1 sub_lock after")&.fetch("value")
  check.call("sub_lock: A1's submission waited on the event lock held by the evidence's transaction, then was refused",
    File.read(File.join(Rehearsal::DIR, "sub_lock_blocking.txt")).match?(/blocked_by=\d+/) &&
      refused.call("old", "o_sub_lock_submit", "A1 submit_payout! sub_lock (waits on the event)",
        /payout #{id.call('payout_sub_lock')} has a recorded provider acceptance/) &&
      lock_after == { "status" => "pending", "authorizations" => 0 })
  check.call("gateway: no submission on sub_eo or sub_lock; sub_org only its first (failed) payout",
    %w[sub_eo sub_lock].all? { |key| calls.none? { |c| Payout.find_by(id: c["payout_id"])&.event_id == id.call(key) } } &&
      calls.select { |c| Payout.find_by(id: c["payout_id"])&.event_id == id.call("sub_org") }.map { |c| c["payout_id"] } ==
        [id.call("payout_sub_org_first")])

  # A2 recheck of bca5f904, finding 2: retention.
  %w[ret_eo ret_eo2].each do |key|
    check.call("#{key}: before retention a fresh reservation is refused",
      refused.call("new", "n_ret_prepare", "A2 PayoutCreator.call #{key} fresh key before retention", /no longer committed/))
  end
  a1_job = find_outcome.call("old", "x_ret_job", "A1 audits after the job")&.fetch("value").to_h
  a2_job = find_outcome.call("new", "x_ret_job", "A2 audits after the job")&.fetch("value").to_h
  kept = { "conflict_reason" => FinancialIntegrity::PAYOUT_PAID_REFUSED_REASON }
  check.call("retention: A1's scheduled job anonymized ret_eo's paid-refusal audit and kept only its conflict reason",
    ok.call("old", "x_ret_job", "A1 DataRetentionPurgeJob (destructive)") && a1_job["ret_eo"] == { "metadata" => kept, "anonymized" => true })
  check.call("retention: A1's job fully redacted the control's ordinary conflict audit",
    a1_job["ret_ctl"] == { "metadata" => {}, "anonymized" => true })
  check.call("retention: A2's scheduled job anonymized ret_eo2's paid-refusal audit and kept only its conflict reason",
    ok.call("new", "x_ret_job", "A2 DataRetentionPurgeJob (destructive)") && a2_job["ret_eo2"] == { "metadata" => kept, "anonymized" => true })
  %w[ret_eo ret_eo2].each do |key|
    check.call("#{key}: after retention and a rebound account, A2's fresh $10.00 is refused",
      ok.call("new", "x_ret_after", "A2 rebind #{key} payout account") &&
        refused.call("new", "x_ret_after", "A2 PayoutCreator.call #{key} fresh key after retention", /no longer committed/))
    check.call("#{key}: after retention, A1's fresh $10.00 is refused by the database",
      refused.call("old", "x_ret_after", "A1 PayoutCreator.call #{key} fresh key after retention",
        /this organization has a provider acceptance recorded only in its audit trail/))
  end
  check.call("ret_ctl: after retention A2 and A1 fresh keys are allowed",
    ok.call("new", "x_ret_after", "A2 PayoutCreator.call ret_ctl fresh key after retention") &&
      ok.call("old", "x_ret_after", "A1 PayoutCreator.call ret_ctl fresh key after retention"))
  check.call("gateway: one submission each on ret_eo and ret_eo2; three on the control",
    %w[ret_eo ret_eo2].all? { |key| calls.count { |c| Payout.find_by(id: c["payout_id"])&.event_id == id.call(key) } == 1 } &&
      calls.count { |c| Payout.find_by(id: c["payout_id"])&.event_id == id.call("ret_ctl") } == 3)

  # A2 recheck finding 3 (8132fe22): the runbook's first preflight, before
  # the migration on A1's schema, against the one shared database.
  parse = lambda do |name|
    File.readlines(File.join(Rehearsal::DIR, name)).map { |line| line.strip.split("\t").to_h { |pair| pair.split("=", 2) } }
  end
  pre = parse.call("preflight_pre_migration.txt")
  post = parse.call("preflight_before.txt")
  section = ->(rows, name) { rows.select { |row| row["section"] == name } }
  check.call("pre-migration preflight: one read-only repeatable-read snapshot on the A1 schema",
    section.call(pre, "snapshot").sole.slice("isolation", "read_only") == { "isolation" => "repeatable_read", "read_only" => "on" } &&
      section.call(pre, "schema").sole["state"] == "pre_a2")
  check.call("pre-migration preflight: the guard gate fails as expected, naming A2's absent guards",
    section.call(pre, "guards").sole["gate_guards"] == "FAIL" &&
      section.call(pre, "guards").sole["failing_guards"].split(",").include?("payouts_audited_acceptance_guard") &&
      section.call(pre, "guards").sole["a2_payout_entry_cutover"] == "missing")
  check.call("pre-migration preflight: zero undisposed (PASS) and zero evidence-only acceptances (PASS)",
    section.call(pre, "undisposed").sole["gate_zero_undisposed"] == "PASS" &&
      section.call(pre, "accepted").sole["gate_evidence_only_zero"] == "PASS")
  in_flight = ->(rows) { section.call(rows, "payout").to_h { |row| [row["payout_id"], row.slice("status", "submitted")] } }
  check.call("pre-migration preflight: every in-flight payout on an affected event, not current, with its submission and action",
    in_flight.call(pre).any? && in_flight.call(pre) == in_flight.call(post) &&
      section.call(pre, "payout").all? { |row| row["current"] == "false" && row["restated_at"] == "after_migration" &&
        row["action"] == (row["submitted"] == "true" ? "record paid only with transfer evidence before the restatement (its time after the migration); else fail and reissue" :
          "not sent: fail and reissue on a new version") })
  check.call("pre-migration preflight: events need finalizing, A2 figures after the migration",
    section.call(pre, "event").any? && section.call(pre, "event").all? { |row| row["needs_finalizing"] == "yes" &&
      row["current_payable_cents"] == "after_migration" && row["over_committed"] == "after_migration" } &&
      section.call(pre, "event").map { |row| row["event_id"] } == section.call(post, "event").map { |row| row["event_id"] })
  check.call("post-migration preflight: A2 schema, every guard (the audited-acceptance guard included) inspected and passing",
    section.call(post, "schema").sole == { "section" => "schema", "state" => "a2", "missing" => "none" } &&
      section.call(post, "guards").sole.values_at("gate_guards", "failing_guards", "payouts_audited_acceptance_guard",
        "payouts_audited_acceptance_guard_on_insert", "hafapass_payout_acceptance_audited") == ["PASS", "none", "true", "true", "true"] &&
      section.call(post, "event").none? { |row| row["current_payable_cents"] == "after_migration" })

  File.write(File.join(Rehearsal::DIR, "assertions.txt"), results.join("\n") + "\n")
  puts results
end
