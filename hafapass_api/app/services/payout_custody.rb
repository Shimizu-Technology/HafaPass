# frozen_string_literal: true

# R2-2: frozen per-payout Stripe custody (docs/design/never-fulfilled-captures.md
# §8.6, §8.10.5, P12).
#
# A payout row belongs in the BPT detail CSV's organizer_payouts only when the
# payout funded money HåfaPass held as Stripe custody. The pre-A2 reader asked
# whether the event had *any current* agent order, so a February Stripe
# capture pulled a January Clover-only payout into a regenerated January
# export. A live anti-join on classification would instead drop a January row
# when a later backfill classifies a capture.
#
# The answer is decided once and frozen in payout_custody_determinations:
#   - new payouts: when the payout is recorded paid (Payout after_update, in
#     the paid-recording transaction, under the organization -> event ->
#     payout locks PayoutReconciler and PayoutCreator already hold; it only
#     reads and inserts, and takes no new row lock);
#   - history: derived once by `payout_custody:derive` (DRY_RUN=1 default).
#
# Rule. Each line the payout funded (PayoutLineAllocator over the payout's own
# finalized settlement version) is
#   - stripe:  its order has a live USD Stripe agent capture that is not
#              classified never-fulfilled and was recorded at or before the
#              version's finalization: capture_recorded_at (database
#              stamped), or for a pre-A1 capture (NULL) either a finalization
#              after the a1_capture_recording cutover (the capture predates
#              the cutover) or the order's own order.completed audit naming
#              that payment at or before finalization;
#   - none:    its order has no such capture recorded by then (Clover, cash,
#              free, or a Stripe capture recorded after finalization);
#   - unknown: the version is not finalized, the order is classified
#              order-scope, or a capture's time cannot be shown either way.
# Any unknown line makes the payout ambiguous; otherwise any stripe line makes
# it stripe_custody, else non_custodial. A later capture, classification,
# backfill, audit redaction or paid_at edit cannot change the row.
#
# Ambiguous payouts, and payouts with no determination yet (paid by an older
# release during the overlap, or history before the derive task runs), use the
# documented conservative rule: the pre-A2 inclusion test (a live USD Stripe
# agent capture on the event), bounded to captures recorded by the payout's
# paid recording time (redaction-safe paid audit, else paid_at). It is stable:
# a capture recorded later carries a later database time, and a NULL capture
# time means the capture predates A1. For an ambiguous row the result is
# frozen as conservative_inclusion, pending an explicit finance correction.
class PayoutCustody
  ORDER_STATUSES = Order.statuses.values_at("completed", "partially_refunded", "refunded", "expired", "cancelled").freeze
  CAPTURED_STATUSES = Payment.statuses.values_at("succeeded", "partially_refunded", "refunded").freeze

  # Earliest paid recording audit, surviving DataRetention.anonymize!
  # (action, auditable_id and created_at), as in CpaMonthlyReport.
  PAID_AUDIT_JOIN_SQL = <<~SQL.squish.freeze
    LEFT JOIN LATERAL (
      SELECT a.id, a.created_at
      FROM audit_logs a
      WHERE a.auditable_type = 'Payout'
        AND a.auditable_id = payouts.id
        AND (
          a.action = 'payout.paid'
          OR (a.action = 'payout.reconciled' AND a.after_data->>'status' = 'paid')
          OR (a.action = 'payout.reconciled' AND COALESCE(a.after_data->>'status', '') = '')
        )
      ORDER BY a.id ASC
      LIMIT 1
    ) paid_audit ON true
  SQL
  PAID_RECORDED_AT_SQL = "COALESCE(paid_audit.created_at, payouts.paid_at)"

  LIVE_AGENT_CAPTURE_SQL = <<~SQL.squish.freeze
    cp.provider = 'stripe' AND cp.currency = 'usd' AND cp.status IN (#{CAPTURED_STATUSES.join(', ')})
    AND (cp.provider_environment = 'live' OR (cp.provider_environment IS NULL
      AND cp.provider_payload->>'livemode' IS DISTINCT FROM 'false'
      AND cp.provider_payload->>'simulated' IS DISTINCT FROM 'true'))
    AND LEFT(COALESCE(cp.provider_payment_id, ''), 4) <> 'sim_'
    AND cp.provider_payload->>'simulated' IS DISTINCT FROM 'true'
    AND cp.provider_payload->>'livemode' IS DISTINCT FROM 'false'
  SQL

  # Correlated on payouts and paid_audit.
  CONSERVATIVE_INCLUSION_SQL = <<~SQL.squish.freeze
    EXISTS (
      SELECT 1 FROM payments cp
      INNER JOIN orders co ON co.id = cp.order_id
      WHERE co.event_id = payouts.event_id AND co.currency = 'usd' AND co.status IN (#{ORDER_STATUSES.join(', ')})
        AND #{LIVE_AGENT_CAPTURE_SQL}
        AND (cp.capture_recorded_at <= #{PAID_RECORDED_AT_SQL}
          OR (cp.capture_recorded_at IS NULL AND cp.created_at <= #{PAID_RECORDED_AT_SQL}))
    )
  SQL

  DETERMINATION_JOIN_SQL = "LEFT JOIN payout_custody_determinations pcd ON pcd.payout_id = payouts.id"
  BPT_INCLUSION_SQL = <<~SQL.squish.freeze
    (pcd.determination = 'stripe_custody'
      OR (pcd.determination = 'ambiguous' AND pcd.conservative_inclusion)
      OR (pcd.id IS NULL AND #{CONSERVATIVE_INCLUSION_SQL}))
  SQL

  class << self
    # The payouts of `scope` the BPT detail CSV reports (frozen custody).
    def bpt_payouts(scope)
      Payout.where(id: scope.joins(PAID_AUDIT_JOIN_SQL).joins(DETERMINATION_JOIN_SQL).where(BPT_INCLUSION_SQL).select(:id))
    end

    # Paid payouts in `scope` with no frozen determination (current-at-read alert).
    def undetermined(scope)
      scope.where.not(id: PayoutCustodyDetermination.select(:payout_id))
    end

    PAID_BASIS = FinancialIntegrity::CUSTODY_PAID_BASIS
    DERIVED_BASIS = FinancialIntegrity::CUSTODY_DERIVED_BASIS

    # Writes the payout's determination once and returns it. Safe to call
    # again; ON CONFLICT keeps the first row. A paid-recording row is written
    # by Payout before_update, in the transaction that records paid and
    # before the status write (the database requires both). Its conservative
    # bound is the database clock of that recording, not the confirmed
    # transfer time an admin enters.
    def record!(payout, basis:, authorized_by: nil)
      existing = PayoutCustodyDetermination.find_by(payout_id: payout.id)
      return existing if existing

      attributes = if basis == PAID_BASIS
        determine(payout, bound_at: database_now)
      else
        determine(payout).tap { |row| row[:evidence][:authorized_by] = authorized_by.to_s }
      end
      insert = -> {
        PayoutCustodyDetermination.insert_all([attributes.merge(payout_id: payout.id, basis: basis)],
          unique_by: :payout_id, record_timestamps: false)
      }
      basis == DERIVED_BASIS ? FinancialIntegrity.with_evidence(:custody_derivation, payout.id, &insert) : insert.call
      PayoutCustodyDetermination.find_by!(payout_id: payout.id)
    end

    # History: one derived_history row per paid or reversed payout that has
    # none and was recorded paid before the A2 payout entry cutover (after
    # it, paid needs the row in its own transaction, so none can be missing).
    # DRY_RUN reports what it would write and writes nothing; a write needs
    # the authorizing person or ticket, recorded in each row's evidence.
    def derive_history!(dry_run: true, payout_ids: nil, authorized_by: nil)
      raise ArgumentError, "a derivation write needs AUTHORIZED_BY" if !dry_run && authorized_by.to_s.strip.empty?

      cutover = FinancialCutover.recorded_at(FinancialIntegrity::PAYOUT_ENTRY_CUTOVER)
      scope = Payout.where(status: %i[paid reversed]).where.not(paid_at: nil)
      scope = scope.where(id: payout_ids) if payout_ids
      recorded = scope.joins(PAID_AUDIT_JOIN_SQL).pluck(:id, Arel.sql(PAID_RECORDED_AT_SQL)).to_h
      undetermined(scope).order(:id).map do |payout|
        attributes = determine(payout)
        row = { payout_id: payout.id, determination: attributes[:determination],
          conservative_inclusion: attributes[:conservative_inclusion] }
        if cutover && recorded[payout.id] && recorded[payout.id] > cutover
          next row.merge(skipped: "paid_after_payout_entry_cutover")
        end

        Payout.transaction { record!(payout, basis: DERIVED_BASIS, authorized_by: authorized_by) } unless dry_run
        row
      end
    end

    def determine(payout, bound_at: nil)
      settlement = payout.settlement
      # The database's own finalization time (settlements_finalization_stamp)
      # when the version has one; older versions keep their recorded time.
      finalized_at = if settlement.status_finalized?
        settlement.try(:finalized_recorded_at) || settlement.finalized_at
      end
      funded = PayoutLineAllocator.amounts_for(payout).select { |_item_id, cents| cents.positive? }
      lines = line_custody(funded, finalized_at)
      determination = if lines.any? { |line| line[:custody] == "unknown" }
        "ambiguous"
      elsif lines.any? { |line| line[:custody] == "stripe" }
        "stripe_custody"
      else
        "non_custodial"
      end
      {
        settlement_id: settlement.id,
        determination: determination,
        funded_order_item_ids: funded.keys.sort,
        qualifying_payment_ids: lines.flat_map { |line| line[:payment_ids] }.uniq.sort,
        conservative_inclusion: conservative_inclusion?(payout, bound_at: bound_at),
        evidence: {
          rule: "frozen_payout_custody_v1",
          settlement_version: settlement.version,
          settlement_finalized_at: finalized_at&.utc&.iso8601(6),
          settlement_finalized_bound: settlement.try(:finalized_recorded_at) ? "finalized_recorded_at" : "finalized_at",
          settlement_reader: settlement.try(:finalized_reader),
          conservative_bound_at: bound_at&.utc&.iso8601(6),
          a1_capture_cutover_at: capture_cutover&.utc&.iso8601(6),
          lines: lines.map { |line| line.except(:payment_ids).merge(payment_ids: line[:payment_ids]) }
        }
      }
    end

    # The conservative rule, bounded by the paid recording (the paid audit,
    # else paid_at) or, for a row written with the recording, its database
    # clock.
    def conservative_inclusion?(payout, bound_at: nil)
      return Payout.where(id: payout.id).joins(PAID_AUDIT_JOIN_SQL).where(CONSERVATIVE_INCLUSION_SQL).exists? unless bound_at

      bounded = CONSERVATIVE_INCLUSION_SQL.gsub(PAID_RECORDED_AT_SQL, "CAST(:bound_at AS timestamp)")
      Payout.where(id: payout.id).where(bounded, bound_at: bound_at.utc).exists?
    end

    private

    def database_now
      ActiveRecord::Type::DateTime.new.cast(Payout.connection.select_value("SELECT timezone('UTC', clock_timestamp())"))
    end

    def capture_cutover
      FinancialCutover.recorded_at("a1_capture_recording")
    end

    def line_custody(funded, finalized_at)
      return [] if funded.empty?

      item_orders = OrderItem.where(id: funded.keys).pluck(:id, :order_id).to_h
      order_ids = item_orders.values.uniq
      classified = UnfulfilledCapture.where(order_id: order_ids, capture_scope: "order").distinct.pluck(:order_id).to_set
      captures = Payment.live_agent_capture.where(order_id: order_ids)
        .where.not(id: UnfulfilledCapture.select(:payment_id))
        .pluck(:id, :order_id, :capture_recorded_at).group_by { |_id, order_id, _at| order_id }
      completions = completion_audits(order_ids)
      cutover = capture_cutover

      funded.keys.sort.map do |item_id|
        order_id = item_orders[item_id]
        line = { order_item_id: item_id, order_id: order_id, funded_cents: funded[item_id], payment_ids: [] }
        next line.merge(custody: "unknown", reason: "settlement_not_finalized") if finalized_at.nil?
        next line.merge(custody: "unknown", reason: "order_classified_never_fulfilled") if classified.include?(order_id)

        timings = Array(captures[order_id]).map do |payment_id, _order_id, recorded_at|
          [payment_id, capture_timing(payment_id, recorded_at, finalized_at, cutover, completions[order_id])]
        end
        qualifying = timings.select { |_id, timing| timing.first == :before }
        if qualifying.any?
          line.merge(custody: "stripe", reason: qualifying.map { |_id, timing| timing.last }.uniq.join(","),
            payment_ids: qualifying.map(&:first).sort)
        elsif timings.any? { |_id, timing| timing.first == :unknown }
          line.merge(custody: "unknown", reason: "pre_a1_capture_time_unproven")
        else
          line.merge(custody: "none", reason: timings.empty? ? "no_stripe_agent_capture" : "captured_after_finalization")
        end
      end
    end

    # [:before | :after | :unknown, evidence]
    def capture_timing(payment_id, recorded_at, finalized_at, cutover, completions)
      if recorded_at
        recorded_at <= finalized_at ? [:before, "capture_recorded_at"] : [:after, "capture_recorded_at"]
      elsif cutover && cutover <= finalized_at
        [:before, "pre_a1_capture_before_cutover"]
      elsif Array(completions).any? { |audit_payment_id, created_at| audit_payment_id == payment_id && created_at <= finalized_at }
        [:before, "completion_audit"]
      else
        [:unknown, "pre_a1_capture_time_unproven"]
      end
    end

    # { order_id => [[payment_id, created_at], ...] } from order.completed audits.
    def completion_audits(order_ids)
      AuditLog.where(auditable_type: "Order", auditable_id: order_ids, action: "order.completed")
        .pluck(:auditable_id, Arel.sql("metadata->>'payment_id'"), :created_at)
        .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(order_id, payment_id, created_at), result|
          result[order_id] << [payment_id.to_i, created_at] if payment_id.present?
        end
    end
  end
end
