# frozen_string_literal: true

module Commerce
  # The one evaluator for a classified never-fulfilled capture
  # (docs/design/never-fulfilled-captures.md §7.1, A1 tranche 4). Idempotent.
  #
  # It runs inside the caller's transaction with the order locked
  # (organization -> event -> order, or the lifecycle's event context ->
  # order -> payment) after every relevant transition: classification, a
  # refund's outcome, a dispute's outcome or loss reversal, an inbound
  # provider refund and evidence replay. It makes no network call; an enqueued
  # repayment runs after commit.
  #
  #   owed 0, nothing in flight  -> resolve the capture's open exceptions, audited
  #   owed > 0 after a resolution -> open never_fulfilled_repayment_reopened
  #   owed > 0, available > 0     -> enqueue LateCaptureRefundJob (A1-R2 only)
  #   owed > 0, available 0       -> record the wait reason on the exception
  #   excess on a posting         -> one never_fulfilled_buyer_overpaid per posting (P4: alert and
  #                                  audit; never holds organizer payouts or finalization)
  class NeverFulfilledResolution
    OVERPAID_CODE = "never_fulfilled_buyer_overpaid"
    REOPENED_CODE = "never_fulfilled_repayment_reopened"
    Result = Struct.new(:state, :availability, keyword_init: true)

    def self.evaluate!(capture, trigger:, actor: nil)
      new(capture, trigger: trigger, actor: actor).evaluate!
    end

    def self.evaluate_payment!(payment_id, trigger:, actor: nil)
      capture = UnfulfilledCapture.find_by(payment_id: payment_id)
      evaluate!(capture, trigger: trigger, actor: actor) if capture
    end

    # Exceptions this capture's repayment closes.
    def self.resolvable_codes(capture)
      codes = LateCaptureRefund::CODES + RefundCreator::LATE_CAPTURE_COMPANION_CODES + [REOPENED_CODE]
      capture.payment_scope? ? codes + [NeverFulfilledClassification::SECOND_CAPTURE_CODE] : codes
    end

    # Whether a note-only manual resolution is allowed: only when the
    # evaluator itself would resolve (§7.1).
    def self.resolvable_now?(capture)
      availability = BuyerRepayment.availability(capture)
      availability.owed_cents.zero? && settled?(capture, availability)
    end

    def self.settled?(capture, availability)
      availability.in_flight_cents.zero? && capture.repayment_operations.open_states.none? &&
        !BuyerRepayment.unreplayed_evidence?(capture.payment)
    end

    def initialize(capture, trigger:, actor:)
      @capture = capture
      @trigger = trigger.to_s
      @actor = actor
    end

    def evaluate!
      record_overpaid!
      availability = BuyerRepayment.availability(capture)
      open_issues = ReconciliationException.open.where(payment_id: capture.payment_id,
        code: self.class.resolvable_codes(capture)).order(:id).to_a

      if availability.owed_cents.zero? && self.class.settled?(capture, availability)
        open_issues.each { |issue| resolve!(issue, availability) }
        return Result.new(state: open_issues.any? ? "resolved" : "settled", availability: availability)
      end

      open_issues << reopen! if availability.owed_cents.positive? && open_issues.empty? && previously_resolved?
      if availability.available_cents.positive? && BuyerRepayment.submitter_active?
        # The lifecycle enqueues the job with the late capture it records.
        LateCaptureRefundJob.perform_later(capture.payment_id) unless trigger == "classification"
        return Result.new(state: "enqueued", availability: availability)
      end

      reason = availability.wait_reason || "repayment_inactive"
      open_issues.compact.each { |issue| record_wait!(issue, availability, reason) }
      Result.new(state: "waiting", availability: availability)
    end

    private

    attr_reader :capture, :trigger, :actor

    def ledger
      @ledger ||= BuyerReturnLedger.for(capture)
    end

    def previously_resolved?
      ReconciliationException.resolved.where(payment_id: capture.payment_id,
        code: self.class.resolvable_codes(capture)).exists?
    end

    def resolve!(issue, availability)
      issue.resolve!
      postings = ledger.postings
      refunds = postings.select { |posting| posting.source_type == "Refund" }
      losses = postings.select { |posting| posting.kind == "dispute_loss" }
      reason = "Repaid: refunds #{dollars(refunds.sum(&:gross_cents))}, lost disputes #{dollars(losses.sum(&:gross_cents))}"
      audit!("reconciliation_exception.resolved", issue, dedupe: "reconciliation_exception:#{issue.id}:resolved",
        after_data: { status: "resolved" },
        metadata: { code: issue.code, order_id: capture.order_id, payment_id: capture.payment_id,
          note: reason, trigger: trigger, posting_ids: postings.map(&:id),
          refund_ids: refunds.map(&:source_id), dispute_ids: losses.map(&:source_id),
          gross_cents: ledger.gross_returned_cents, applied_cents: ledger.applied_cents,
          excess_cents: ledger.excess_cents, pending: "none", owed_cents: availability.owed_cents })
    end

    def reopen!
      previous = ReconciliationException.resolved.where(payment_id: capture.payment_id,
        code: self.class.resolvable_codes(capture)).order(:id).last
      issue = ReconciliationException.create!(order: capture.order, payment: capture.payment, code: REOPENED_CODE,
        details: { previous_exception_id: previous&.id, owed_cents: ledger.owed_cents, trigger: trigger })
      audit!("reconciliation_exception.reopened", issue, dedupe: "reconciliation_exception:#{issue.id}:reopened",
        metadata: { code: REOPENED_CODE, previous_exception_id: previous&.id, payment_id: capture.payment_id,
          owed_cents: ledger.owed_cents, trigger: trigger })
      issue
    end

    def record_wait!(issue, availability, reason)
      details = issue.details.is_a?(Hash) ? issue.details : {}
      wait = { "wait_reason" => reason, "owed_cents" => availability.owed_cents,
        "in_flight_cents" => availability.in_flight_cents }
      return if details.slice(*wait.keys) == wait

      issue.update!(details: details.merge(wait))
    end

    # One exception per posting that carries excess, listing its movement.
    def record_overpaid!
      ledger.postings.select { |posting| posting.excess_cents.positive? }.each do |posting|
        next if ReconciliationException.where(payment_id: capture.payment_id, code: OVERPAID_CODE)
          .where("details ->> 'posting_id' = ?", posting.id.to_s).exists?

        issue = ReconciliationException.create!(order: capture.order, payment: capture.payment, code: OVERPAID_CODE,
          actual_amount_cents: posting.excess_cents, actual_currency: capture.currency,
          details: { capture_id: capture.id, posting_id: posting.id, source_type: posting.source_type,
            source_id: posting.source_id, kind: posting.kind, gross_cents: posting.gross_cents,
            excess_cents: posting.excess_cents, platform_only: true })
        audit!("never_fulfilled_capture.buyer_overpaid", issue, dedupe: "never_fulfilled_overpaid:#{posting.id}",
          metadata: { payment_id: capture.payment_id, posting_id: posting.id, excess_cents: posting.excess_cents,
            total_excess_cents: ledger.excess_cents })
        Sentry.capture_message("Buyer was repaid more than a never-fulfilled capture; finance review required",
          level: :warning, fingerprint: ["never-fulfilled-buyer-overpaid"],
          extra: { payment_id: capture.payment_id, posting_id: posting.id, excess_cents: posting.excess_cents })
      end
    end

    def audit!(action, issue, dedupe:, metadata:, after_data: {})
      AuditLogger.record!(action: action, auditable: issue, actor: actor,
        organization: capture.order.event.organization, event: capture.order.event, outcome: "succeeded",
        deduplication_key: dedupe, after_data: after_data, metadata: metadata)
    end

    def dollars(cents)
      format("$%<dollars>d.%<cents>02d", dollars: cents / 100, cents: cents % 100)
    end
  end
end
