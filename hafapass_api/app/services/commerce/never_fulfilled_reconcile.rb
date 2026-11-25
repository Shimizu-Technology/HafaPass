# frozen_string_literal: true

module Commerce
  # Classifies historical never-fulfilled captures and posts their returned
  # money, only from positive lifecycle provenance
  # (docs/design/never-fulfilled-captures.md §4.5, A1 tranche 3).
  #
  # Idempotent. A dry run (the default) only reads and reports. A write
  # re-reads each payment under organization -> event -> order -> payment
  # (the refund and dispute prefix, docs/LOCKING.md) and writes only when the
  # locked assessment still says so. It inserts append-only classification,
  # posting and exception rows through the guarded writers; it never updates or
  # deletes a historical row and makes no network call.
  #
  # Nothing schedules it. The release plan uses dry-run counts and an
  # authorized run (§10.5); per-payment after-commit calls are a tranche 4
  # hook (call_for_payment).
  #
  # Dispositions:
  #   classify      positive provenance and positively matched movements
  #   post          already classified; post unposted movements with evidence
  #   ambiguous     any proof missing or ambiguous -> never_fulfilled_backfill_ambiguous
  #   restatement   the event has a finalized settlement or a reserved, sent or
  #                 paid payout -> never_fulfilled_backfill_restatement; nothing else written
  #   held          finance already has an ambiguity or restatement item for it
  #   reconciled    nothing to do
  class NeverFulfilledReconcile
    AMBIGUOUS_CODE = "never_fulfilled_backfill_ambiguous"
    RESTATEMENT_CODE = "never_fulfilled_backfill_restatement"
    FINANCE_CODES = [AMBIGUOUS_CODE, RESTATEMENT_CODE].freeze
    # OrderLifecycle writes the late-capture exception in the capture's own
    # transaction; anything further apart is not lifecycle evidence.
    EVIDENCE_WINDOW = 5.seconds
    CAPTURED_STATUSES = %w[succeeded partially_refunded refunded].freeze
    MONEY_MOVED_PAYOUT_STATUSES = %w[pending processing paid held].freeze
    RELEASE_ACTIONS = %w[order.expired order.cancelled].freeze

    Assessment = Struct.new(:payment_id, :order_id, :disposition, :reason, :capture_attributes, :backfills,
      :movement_count, :details, keyword_init: true)
    Report = Struct.new(:dry_run, :assessments, keyword_init: true) do
      def counts
        assessments.group_by(&:disposition).transform_values(&:count)
      end

      def reasons
        assessments.reject { |item| item.reason.nil? }.group_by(&:reason).transform_values(&:count)
      end
    end

    def self.call(dry_run: true, payment_ids: nil)
      ids = payment_ids ? Array(payment_ids).map(&:to_i) : candidate_payment_ids
      assessments = ids.sort.filter_map do |id|
        payment = Payment.find_by(id: id)
        new(payment).run!(dry_run: dry_run) if payment
      end
      Report.new(dry_run: dry_run, assessments: assessments)
    end

    def self.call_for_payment(payment, dry_run: true)
      new(payment).run!(dry_run: dry_run)
    end

    # Captured Stripe payments with a late-capture exception and no
    # classification, plus classified payments with an unposted movement.
    def self.candidate_payment_ids
      unclassified = ReconciliationException.where(code: LateCaptureRefund::CODES).where.not(payment_id: nil)
        .where.not(payment_id: UnfulfilledCapture.select(:payment_id)).distinct.pluck(:payment_id)
      unposted = unposted_movement_payment_ids
      (unclassified + unposted).uniq
    end

    def self.unposted_movement_payment_ids
      classified = UnfulfilledCapture.select(:payment_id)
      refunds = Refund.succeeded.where(payment_id: classified)
        .where.not(id: BuyerReturnPosting.where(kind: "refund").select(:source_id)).distinct.pluck(:payment_id)
      losses = Dispute.lost.where(payment_id: classified).where("amount_cents > 0")
        .where.not(id: BuyerReturnPosting.where(kind: "dispute_loss").select(:source_id)).distinct.pluck(:payment_id)
      reversals = Dispute.lost.where(payment_id: classified).where.not(loss_reversed_at: nil)
        .where.not(id: BuyerReturnPosting.where(kind: "dispute_loss_reversal").select(:source_id)).distinct.pluck(:payment_id)
      (refunds + losses + reversals).uniq
    end

    def initialize(payment)
      @payment = payment
    end

    def run!(dry_run:)
      assessment = assess
      return assessment if dry_run || %w[held reconciled].include?(assessment.disposition)

      write!
    end

    private

    attr_reader :payment

    def order
      payment.order
    end

    # Re-reads under the locks and writes what the locked assessment says.
    def write!
      Order.transaction do
        order.event.organization.lock!("FOR NO KEY UPDATE")
        order.event.lock!
        order.lock!
        payment.lock!
        assessment = assess
        case assessment.disposition
        when "classify"
          capture = classify_backfill!(assessment)
          BuyerReturnPostings.record_recorded_movements!(capture, backfills: assessment.backfills)
          resolve_superseded_quarantine!(capture)
        when "post"
          capture = UnfulfilledCapture.find_by!(payment_id: payment.id)
          BuyerReturnPostings.record_recorded_movements!(capture, backfills: assessment.backfills)
          resolve_superseded_quarantine!(capture)
        when "ambiguous", "restatement"
          open_finance_item!(assessment)
        end
        assessment
      end
    end

    def assess
      result = ->(disposition, reason = nil, **extra) do
        Assessment.new(payment_id: payment.id, order_id: payment.order_id, disposition: disposition, reason: reason,
          movement_count: 0, backfills: {}, details: {}, **extra)
      end
      capture = UnfulfilledCapture.find_by(payment_id: payment.id)
      return assess_classified(capture, result) if capture
      # An ordinary payment is never a candidate: no lifecycle late-capture record.
      unless ReconciliationException.exists?(payment: payment, code: LateCaptureRefund::CODES)
        return result.call("reconciled", "not_a_candidate")
      end
      return result.call("held", "finance_item_exists") if ReconciliationException.exists?(payment: payment, code: FINANCE_CODES)
      return result.call("reconciled", "not_a_stripe_capture") unless NeverFulfilledClassification.applicable?(payment)

      problem, evidence = provenance
      return result.call("ambiguous", problem) if problem

      movements, backfills, movement_problem = matched_movements(evidence[:capture_evidence_at])
      return result.call("ambiguous", movement_problem, movement_count: movements.length) if movement_problem

      restated = restatement_details
      return result.call("restatement", "published_results", details: restated) if restated

      components = NeverFulfilledClassification.order_components(order, payment)
      return result.call("ambiguous", components) if components.is_a?(String)

      result.call("classify", nil, capture_attributes: capture_attributes(evidence, components), backfills: backfills,
        movement_count: movements.length, details: evidence.slice(:exception_id, :release_audit_id))
    end

    def assess_classified(capture, result)
      posted = capture.buyer_return_postings.pluck(:kind, :source_type, :source_id).to_set
      unposted = BuyerReturnPostings.recorded_movements(payment.id)
        .reject { |movement| posted.include?([movement.kind, movement.source.class.name, movement.source.id]) }
      return result.call("reconciled") if unposted.empty?

      movements, backfills, problem = matched_movements(capture.capture_recorded_at, only: unposted)
      return result.call("ambiguous", problem, movement_count: movements.length) if problem

      result.call("post", nil, backfills: backfills, movement_count: movements.length)
    end

    # Points 1-5 of design §4.5. Returns [problem, evidence].
    def provenance
      return ["payment_not_captured"] unless CAPTURED_STATUSES.include?(payment.status)
      return ["order_amount_mismatch"] unless payment.amount_cents == order.total_cents &&
        payment.currency.to_s.casecmp?(order.currency.to_s)

      others = order.payments.where(status: CAPTURED_STATUSES).where.not(id: payment.id)
        .where.not(id: UnfulfilledCapture.where(order_id: order.id, capture_scope: "order").select(:payment_id))
      return ["ownership_ambiguous"] if others.exists?

      exception = ReconciliationException.where(order: order, payment: payment, code: LateCaptureRefund::CODES).order(:id).first
      return ["late_capture_exception_missing"] unless exception

      receipt = exception.webhook_event
      refund_key = Refund.find_by(idempotency_key: LateCaptureRefund.idempotency_key(payment))
      return ["late_capture_refund_on_another_payment"] if refund_key && refund_key.payment_id != payment.id

      capture_at = if receipt
        object = receipt.payload.to_h.dig("data", "object").to_h
        unless receipt.event_type == "payment_intent.succeeded" && object["id"] == payment.provider_payment_id
          return ["receipt_names_another_payment"]
        end
        receipt.created_at
      elsif refund_key
        return ["late_capture_refund_before_exception"] if refund_key.created_at < exception.created_at

        exception.created_at
      else
        # A late-capture exception with neither lifecycle artifact is not
        # positive evidence, whoever entered it.
        return ["no_lifecycle_evidence"]
      end

      recorded = payment.capture_recorded_at
      if recorded
        return ["exception_outside_capture_window"] if (exception.created_at - recorded).abs > EVIDENCE_WINDOW

        capture_at = recorded
      else
        return ["exception_outside_capture_window"] unless exception.created_at.between?(capture_at, capture_at + EVIDENCE_WINDOW)

        cutover = cutover_at("a1_capture_recording")
        return ["capture_cutover_missing"] unless cutover
        return ["capture_evidence_after_cutover"] if [capture_at, exception.created_at].max > cutover
      end

      release = release_audit(exception)
      return ["release_audit_missing"] unless release

      fulfilment = fulfilment_problem
      return [fulfilment] if fulfilment

      [nil, { exception: exception, receipt: receipt, refund_key: refund_key, release_audit_id: release.id,
              exception_id: exception.id, capture_evidence_at: capture_at }]
    end

    def release_audit(exception)
      scope = AuditLog.where(auditable_type: "Order", auditable_id: order.id, action: RELEASE_ACTIONS)
        .where("created_at <= ?", exception.created_at)
      if exception.code == "pass_all_included_nights_cancelled"
        scope = scope.where("metadata ->> 'reason' = ?", "pass_all_included_nights_cancelled")
      end
      scope.order(:id).first
    end

    def fulfilment_problem
      return "order_fulfilled" if order.pending? || order.completed? || order.completed_at.present? ||
        order.fulfilled_by_payment_id.present? ||
        AuditLog.exists?(action: "order.completed", deduplication_key: "order:#{order.id}:completed")
      return "active_tickets" if order.tickets.where.not(status: :cancelled).exists?
      return "consumed_inventory" if order.inventory_holds.consumed.exists? || order.catalog_item_holds.consumed.exists?
      return "promo_finalized" if order.promo_redemption&.finalized?
      return "commission_earned" if order.promoter_commission_entries.earned.exists?
      return "linked_adjustment" if BalanceAdjustment.where(order_id: order.id).exists?

      nil
    end

    # Every succeeded refund and lost dispute on the payment, positively
    # matched; anything on this order that names no payment is ambiguous.
    # Returns [movements, backfills, problem].
    def matched_movements(capture_at, only: nil)
      return [[], {}, "unattributed_movement"] if order.refunds.succeeded.where(payment_id: nil).exists? ||
        order.disputes.lost.where(payment_id: nil).exists?

      movements = only || BuyerReturnPostings.recorded_movements(payment.id)
      backfills = {}
      movements.each do |movement|
        source = movement.source
        provider_id = source.is_a?(Refund) ? source.provider_refund_id : source.provider_dispute_id
        return [movements, {}, "movement_without_provider_id"] if provider_id.blank?
        return [movements, {}, "movement_amount_exceeds_capture"] if movement.gross_cents.abs > payment.amount_cents
        return [movements, {}, "movement_currency_mismatch"] unless source.currency.to_s.casecmp?(payment.currency.to_s)
        next if movement.recorded_at

        evidence = movement_evidence(movement)
        return [movements, {}, "movement_recording_time_unknown"] unless evidence
        return [movements, {}, "movement_before_capture"] if evidence[:recorded_at] < capture_at

        backfills[[movement.kind, source.class.name, source.id]] = evidence
      end
      [movements, backfills, nil]
    end

    # A pre-A1 movement's recording time: its earliest success or loss audit,
    # created no later than the A1 return cutover. Frozen on the posting.
    def movement_evidence(movement)
      cutover = cutover_at("a1_return_recording")
      return unless cutover

      action = movement.kind == "refund" ? "refund.succeeded" : "dispute.lost"
      audit = AuditLog.where(auditable_type: movement.source.class.name, auditable_id: movement.source.id, action: action)
        .where("created_at <= ?", cutover).order(:created_at, :id).first
      return unless audit

      { recorded_at: audit.created_at, evidence: { "recording_audit_id" => audit.id, "recording_audit_action" => action } }
    end

    def restatement_details
      settlements = Settlement.where(event_id: order.event_id).status_finalized.pluck(:id)
      payouts = Payout.where(event_id: order.event_id, status: MONEY_MOVED_PAYOUT_STATUSES).pluck(:id)
      return if settlements.empty? && payouts.empty?

      { settlement_ids: settlements, payout_ids: payouts, event_id: order.event_id }
    end

    def capture_attributes(evidence, components)
      exception = evidence[:exception]
      provenance = {
        "source" => "reconcile", "reconciliation_exception_id" => exception.id,
        "release_audit_id" => evidence[:release_audit_id],
        "webhook_event_id" => evidence[:receipt]&.id, "late_capture_refund_id" => evidence[:refund_key]&.id,
        "capture_evidence_at" => evidence[:capture_evidence_at].utc.iso8601(6),
        "capture_recording" => payment.capture_recorded_at ? "database" : "backfill"
      }.compact
      { order: order, payment: payment, capture_scope: "order", code: exception.code,
        captured_cents: payment.amount_cents, currency: payment.currency, **components,
        capture_recorded_at: payment.capture_recorded_at || evidence[:capture_evidence_at],
        processing_bearer: NeverFulfilledCapture.organizer_bears_processing? ? "organizer" : "platform",
        dispute_fee_bearer: NeverFulfilledCapture::DISPUTE_FEE_BEARER.to_s,
        allocation_policy: NeverFulfilledCapture::ALLOCATION_POLICY.to_s,
        policy_version: NeverFulfilledClassification::POLICY_VERSION, provenance: "backfill",
        provenance_evidence: provenance }
    end

    def classify_backfill!(assessment)
      capture = UnfulfilledCapture.create!(assessment.capture_attributes)
      AuditLogger.record!(action: "never_fulfilled_capture.classified", auditable: capture,
        organization: order.event.organization, event: order.event, outcome: "succeeded",
        deduplication_key: "unfulfilled_capture:#{capture.id}:classified",
        metadata: { order_id: order.id, payment_id: payment.id, capture_scope: "order", code: capture.code,
          captured_cents: capture.captured_cents, provenance: "backfill",
          reconciliation_exception_id: capture.provenance_evidence["reconciliation_exception_id"] })
      capture
    end

    # Quarantines the lifecycle or a posting opened only because evidence was
    # missing then (capture recorded before A1, movement recording time
    # unknown) are superseded once that evidence is posted.
    def resolve_superseded_quarantine!(capture)
      posted = capture.buyer_return_postings.pluck(:kind, :source_type, :source_id).map { |kind, type, id| [kind, type, id.to_s] }.to_set
      ReconciliationException.open.where(payment: payment).find_each do |issue|
        superseded = case issue.code
        when NeverFulfilledClassification::QUARANTINE_CODE
          issue.details.to_h["reason"] == "capture_recorded_before_a1"
        when BuyerReturnPostings::QUARANTINE_CODE
          details = issue.details.to_h
          details["reason"] == "recording_time_unknown" &&
            posted.include?([details["kind"], details["source_type"], details["source_id"].to_s])
        end
        next unless superseded

        issue.resolve!
        AuditLogger.record!(action: "reconciliation_exception.resolved", auditable: issue,
          organization: order.event.organization, event: order.event, outcome: "succeeded",
          deduplication_key: "reconciliation_exception:#{issue.id}:resolved",
          after_data: { status: "resolved" },
          metadata: { code: issue.code, order_id: order.id, payment_id: payment.id,
            note: "Superseded by never-fulfilled reconcile with positive evidence (capture #{capture.id})" })
      end
    end

    def open_finance_item!(assessment)
      ReconciliationException.find_by(payment: payment, code: FINANCE_CODES) ||
        ReconciliationException.create!(order: order, payment: payment,
          code: assessment.disposition == "restatement" ? RESTATEMENT_CODE : AMBIGUOUS_CODE,
          details: { reason: assessment.reason, movement_count: assessment.movement_count }.merge(assessment.details.to_h))
    end

    def cutover_at(key)
      FinancialCutover.recorded_at(key)
    end
  end
end
