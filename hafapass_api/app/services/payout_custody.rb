# frozen_string_literal: true

require "csv"

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
# Funded lines are the payout's saved allocations (payout_line_allocations,
# written when it was reserved) when it has them, else the same calculation
# over its frozen version. A payout that funded no sale line, or that funded
# more than its lines, is ambiguous, never non_custodial by default. A line's
# qualifying payment is the order's recorded fulfilling payment when there is
# one (a Stripe second capture on a Clover sale never qualifies it), else any
# unclassified live agent capture on the order, and its time is its
# database-stamped capture_recorded_at or, before A1 stamped it, a bound
# proved by the A1 cutover or the order's completion audit; a payment's
# created_at is never capture evidence.
#
# Payouts with no determination yet (paid by an older release during the
# overlap, or history before the derive task runs) use the documented
# conservative rule at read, and are alerted: the pre-A2 inclusion test (a
# live USD Stripe agent capture on the event), bounded to captures recorded
# by the payout's paid recording time (redaction-safe paid audit, else
# paid_at). A capture with no recording stamp predates A1; it is bounded by
# the A1 cutover, else by its own success time, and only a row with neither
# keeps the pre-A2 inclusion. It is stable: a later capture carries a later
# database time.
#
# Ambiguous history is frozen only from an authorized published baseline
# (the payout's row as the published export reported it) or an explicit
# finance disposition, passed to the derive task; without one the payout is
# left undetermined (alerted), never frozen on a guess. A new payout that is
# ambiguous at its paid recording freezes the conservative rule at that
# recording's database time and stays alerted.
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
          OR (cp.capture_recorded_at IS NULL AND (
            (SELECT fc.recorded_at FROM financial_cutovers fc WHERE fc.key = 'a1_capture_recording') <= #{PAID_RECORDED_AT_SQL}
            OR cp.succeeded_at <= #{PAID_RECORDED_AT_SQL}
            OR cp.succeeded_at IS NULL)))
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
    # The authorization kept in a historical determination: a finance ticket
    # reference (FIN-2026-11-001), never a person.
    AUTHORIZATION_REFERENCE = /\A[A-Z]{2,10}-[A-Z0-9][A-Z0-9-]{0,40}\z/
    DERIVED_BASIS = FinancialIntegrity::CUSTODY_DERIVED_BASIS

    # Writes the payout's determination once and returns it. Safe to call
    # again; ON CONFLICT keeps the first row. A paid-recording row is written
    # by Payout before_update, in the transaction that records paid and
    # before the status write (the database requires both). Its conservative
    # bound is the database clock of that recording, not the confirmed
    # transfer time an admin enters.
    def record!(payout, basis:, authorized_by: nil, published: nil)
      existing = PayoutCustodyDetermination.find_by(payout_id: payout.id)
      return existing if existing

      attributes = if basis == PAID_BASIS
        determine(payout, bound_at: database_now)
      else
        determine(payout).tap do |row|
          # A structured finance reference, never a person's name
          # (CodeRabbit 4703321661): the row is immutable and classified as
          # holding no personal data (config/data_retention.yml).
          reference = authorized_by.to_s.strip
          raise ArgumentError, "a historical determination needs a finance ticket reference" unless reference.match?(AUTHORIZATION_REFERENCE)

          row[:evidence][:authorized_by] = reference
          if row[:determination] == "ambiguous"
            raise ArgumentError, "an ambiguous historical payout needs its published baseline" unless published

            # BPT keeps the payout's published row (design §8.6), as supplied.
            row[:conservative_inclusion] = published.fetch(:included)
            row[:evidence][:published_baseline] = { included: published.fetch(:included), source: published.fetch(:source) }
          end
        end
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
    # `published` ({ payout_id => { included:, source: } }) is the authorized
    # published baseline or finance disposition for ambiguous payouts; an
    # ambiguous payout without one is reported and left undetermined.
    def derive_history!(dry_run: true, payout_ids: nil, authorized_by: nil, published: {})
      raise ArgumentError, "a derivation write needs AUTHORIZED_BY" if !dry_run && authorized_by.to_s.strip.empty?
      if !dry_run && !authorized_by.to_s.strip.match?(AUTHORIZATION_REFERENCE)
        raise ArgumentError, "AUTHORIZED_BY must be a finance ticket reference such as FIN-2026-11-001, never a name"
      end

      cutover = FinancialCutover.recorded_at(FinancialIntegrity::PAYOUT_ENTRY_CUTOVER)
      scope = Payout.where(status: %i[paid reversed]).where.not(paid_at: nil)
      scope = scope.where(id: payout_ids) if payout_ids
      recorded = scope.joins(PAID_AUDIT_JOIN_SQL).pluck(:id, Arel.sql(PAID_RECORDED_AT_SQL)).to_h
      undetermined(scope).order(:id).map do |payout|
        attributes = determine(payout)
        baseline = published[payout.id]
        row = { payout_id: payout.id, determination: attributes[:determination],
          conservative_inclusion: attributes[:determination] == "ambiguous" ? baseline&.fetch(:included) : attributes[:conservative_inclusion] }
        if cutover && recorded[payout.id] && recorded[payout.id] > cutover
          next row.merge(skipped: "paid_after_payout_entry_cutover")
        end
        next row.merge(skipped: "needs_published_baseline") if attributes[:determination] == "ambiguous" && baseline.nil?

        next row if dry_run

        # Report what was saved (CodeRabbit 4703321638): another derivation
        # may have frozen the row first, or the evidence moved since the
        # preview above.
        saved = Payout.transaction { record!(payout, basis: DERIVED_BASIS, authorized_by: authorized_by, published: baseline) }
        { payout_id: payout.id, determination: saved.determination, conservative_inclusion: saved.conservative_inclusion }
      end
    end

    # { payout_id => { included:, source: } } from a finance CSV with columns
    # payout_id, included (true/false) and source (the published export or
    # disposition it comes from). Every row is required to be complete.
    def published_baseline(csv_text)
      CSV.parse(csv_text, headers: true).each_with_object({}) do |row, baseline|
        id = row["payout_id"].to_s.strip
        included = row["included"].to_s.strip.downcase
        source = row["source"].to_s.strip
        unless id.match?(/\A[1-9]\d*\z/) && %w[true false].include?(included) && source.present?
          raise ArgumentError, "each baseline row needs payout_id, included (true or false) and source"
        end
        raise ArgumentError, "payout #{id} appears twice in the baseline" if baseline.key?(id.to_i)

        baseline[id.to_i] = { included: included == "true", source: source }
      end
    end

    def determine(payout, bound_at: nil)
      settlement = payout.settlement
      # The database's own finalization time (settlements_finalization_stamp)
      # when the version has one; older versions keep their recorded time.
      finalized_at = if settlement.status_finalized?
        settlement.try(:finalized_recorded_at) || settlement.finalized_at
      end
      saved = payout.payout_line_allocations.pluck(:order_item_id, :amount_cents)
      funded = (saved.any? ? saved.to_h : PayoutLineAllocator.amounts_for(payout)).select { |_item_id, cents| cents.positive? }
      lines = line_custody(funded, finalized_at)
      unfunded = [payout.amount_cents - funded.values.sum, 0].max
      determination = if lines.any? { |line| line[:custody] == "unknown" }
        "ambiguous"
      elsif lines.any? { |line| line[:custody] == "stripe" }
        "stripe_custody"
      elsif unfunded.positive?
        # Nothing shows what funded the rest (no sale line, or more than the
        # lines): never assumed to be non-custodial.
        "ambiguous"
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
          rule: "frozen_payout_custody_v2",
          funding_source: saved.any? ? "saved_allocations" : "reconstructed_from_version",
          unfunded_cents: unfunded,
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
      fulfilling = Order.where(id: order_ids).pluck(:id, :fulfilled_by_payment_id).to_h
      captures = Payment.live_agent_capture.where(order_id: order_ids)
        .where.not(id: UnfulfilledCapture.select(:payment_id))
        .pluck(:id, :order_id, :capture_recorded_at).group_by { |_id, order_id, _at| order_id }
      # The exact fulfilling payment, when the order records one.
      other_captures = captures.transform_values { |rows| rows.map(&:first) }
      captures = captures.to_h do |order_id, rows|
        [order_id, fulfilling[order_id] ? rows.select { |id, _order_id, _at| id == fulfilling[order_id] } : rows]
      end
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
          reason = if timings.any?
            "captured_after_finalization"
          elsif Array(other_captures[order_id]).any?
            "fulfilled_by_another_payment"
          else
            "no_stripe_agent_capture"
          end
          line.merge(custody: "none", reason: reason)
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
