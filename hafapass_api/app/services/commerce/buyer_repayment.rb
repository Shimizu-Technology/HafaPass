# frozen_string_literal: true

module Commerce
  # The one workflow that sends money back for a never-fulfilled capture
  # (docs/design/never-fulfilled-captures.md §6, A1 tranche 4).
  #
  # Every outbound refund of a *fenced* payment (a classified capture, or a
  # payment with a late-capture, second-capture, ambiguous-ownership or
  # classification-quarantine exception; the same predicate as the database
  # fence, hafapass_fenced_payment) goes through a RepaymentOperation:
  #
  #   reserve!  under organization -> event -> order (RefundCreator#reserve_refund!):
  #             a retry returns the open operation; otherwise a new operation
  #             is reserved for at most "available" (§6.1) with its own key.
  #   gate!     under the same locks at RefundCreator's last local gate, just
  #             before submission_requested is persisted: recomputes
  #             "available" excluding the operation itself and moves it to
  #             submitting (compare-and-set), so only one transaction sends.
  #
  # Locks: the order prefix is the caller's; operations are rank 3 rows locked
  # after the order and the refund (docs/LOCKING.md). No network call here.
  #
  # Activation (§10.1, §10.5): A1-R1 ships SUBMITTER_ACTIVE = false. R1
  # reserves nothing and never passes the gate for a fenced payment; it can
  # only look up and record existing operations (RepaymentAdjudication).
  # A1-R2 is a reviewed code release that changes this constant to true and
  # nothing else; it is never a setting, environment variable or runtime flip.
  class BuyerRepayment
    SUBMITTER_ACTIVE = false

    # Orphan provider evidence that may describe this payment (§7.2).
    ORPHAN_CODES = %w[refund_operation_not_found refunded_payment_not_found disputed_payment_not_found].freeze
    AGGREGATE_GAP_CODE = "refund_aggregate_requires_reconciliation"
    # Stripe refuses refunds on a disputed charge (§6.4).
    DISPUTED_REFUND_CODES = %w[charge_disputed refund_disputed_payment].freeze
    WAIT_MESSAGES = {
      "repayment_inactive" => "Automatic repayment of this payment starts with the next release; nothing was sent",
      "classification_pending" => "This payment is held for finance review before it can be returned",
      "finance_review" => "Refund needs finance review; contact support before submitting another request",
      "evidence_unreplayed" => "Stripe reported a refund or dispute for this payment that is not recorded yet",
      "refund_unknown" => "An earlier refund's result is unknown; reconcile it before sending more",
      "refund_pending" => "An earlier refund is still pending",
      "dispute_open" => "A payment dispute is open; wait for its outcome",
      "disputed_refund_unreconciled" => "Stripe refused a refund because of a dispute; wait until that dispute is recorded",
      "nothing_owed" => "Nothing is owed on this payment",
      "amount_exceeds_available" => "Refund amount exceeds what is still owed on this payment",
      "organizer_not_permitted" => "HåfaPass returns this payment to the buyer"
    }.freeze

    AUDIT_ACTIONS = {
      "reserved" => "repayment_operation.reserved",
      "submission_requested" => "repayment_operation.submission_requested",
      "succeeded" => "repayment_operation.succeeded",
      "failed_terminal" => "repayment_operation.failed_terminal",
      "unknown" => "repayment_operation.unknown",
      "adopted" => "repayment_operation.adopted"
    }.freeze

    class Waiting < RefundCreator::RefundError
      attr_reader :reason

      def initialize(reason, message = nil)
        @reason = reason
        super(message || WAIT_MESSAGES.fetch(reason))
      end
    end

    Availability = Struct.new(:owed_cents, :in_flight_cents, :available_cents, :wait_reason, keyword_init: true) do
      def waiting?
        wait_reason.present?
      end
    end

    class << self
      def submitter_active?
        SUBMITTER_ACTIVE
      end

      # Same predicate as the database fence, evaluated by the database.
      def fenced_payment?(payment)
        id = payment.respond_to?(:id) ? payment.id : payment
        return false if id.blank?

        ActiveRecord::Base.connection.select_value(
          ActiveRecord::Base.sanitize_sql_array(["SELECT hafapass_fenced_payment(?)", id])
        ) == true
      end

      # The bound after which a send that started at last_submitted_at can no
      # longer reach Stripe (§10.5): the platform-account check plus the POST,
      # each (1 + max_network_retries) attempts of open + read timeout, the
      # retry backoff, plus a 10-minute margin for process shutdown.
      def in_flight_bound
        attempts = Stripe.max_network_retries.to_i + 1
        per_call = attempts * (Stripe.open_timeout.to_f + Stripe.read_timeout.to_f) +
          Stripe.max_network_retries.to_i * Stripe::StripeConfiguration.new.max_network_retry_delay.to_f
        (2 * per_call).ceil.seconds + 10.minutes
      end

      # Owed, in flight and available for one classified capture (§6.1).
      # Caller holds the order lock. excluding_refund: the operation's own
      # refund at its gate (§6.3).
      def availability(capture, excluding_refund: nil)
        ledger = BuyerReturnLedger.for(capture)
        payment = capture.payment
        pending = payment.refunds.pending
        pending = pending.where.not(id: excluding_refund.id) if excluding_refund
        open_disputes = Dispute.open.where(payment_id: payment.id)
        in_flight = pending.sum(:amount_cents) + open_disputes.sum(:amount_cents)
        owed = ledger.owed_cents
        reason = wait_reason(capture, pending, open_disputes, excluding_refund)
        reason ||= "nothing_owed" unless owed - in_flight > 0
        Availability.new(owed_cents: owed, in_flight_cents: in_flight,
          available_cents: reason ? 0 : owed - in_flight, wait_reason: reason)
      end

      # Durable, evaluated under the locks: provider evidence for this payment
      # that is not recorded yet (§7.2).
      def unreplayed_evidence?(payment)
        exceptions = ReconciliationException.open
        return true if exceptions.where(payment_id: payment.id, code: ORPHAN_CODES + [AGGREGATE_GAP_CODE]).exists?
        return false if payment.provider_payment_id.blank?

        exceptions.where(payment_id: nil, code: ORPHAN_CODES).joins(:webhook_event)
          .where("webhook_events.payload -> 'data' -> 'object' ->> 'payment_intent' = ?", payment.provider_payment_id)
          .exists?
      end

      # Called by RefundCreator#reserve_refund! for an outbound refund of a
      # fenced payment, inside its organization -> event -> order transaction.
      # The refund an earlier request with this caller key reserved, if any.
      def request_refund(request_key)
        return if request_key.blank?

        RepaymentOperation.where("evidence ->> 'request_key' = ?", request_key).order(:id).last&.refund
      end

      def reserve!(order:, payment:, source:, requested_by: nil, amount_cents: nil, reason: nil,
        organizer_initiated: false, request_key: nil)
        raise Waiting, "organizer_not_permitted" if organizer_initiated

        capture = UnfulfilledCapture.find_by(payment_id: payment.id, order_id: order.id)
        raise Waiting, "classification_pending" unless capture

        RepaymentAdjudication.adopt_legacy!(capture)
        operations = capture.repayment_operations.in_sequence.lock.to_a
        current = operations.find(&:open?)
        # A retry of an existing operation is never a new operation.
        return current.refund if current
        raise Waiting, "repayment_inactive" unless submitter_active?

        available = availability(capture)
        raise Waiting, available.wait_reason if available.waiting?

        amount = amount_cents || available.available_cents
        raise Waiting, "amount_exceeds_available" if amount > available.available_cents

        sequence = operations.length + 1
        operation = capture.repayment_operations.create!(payment: payment, sequence: sequence, amount_cents: amount,
          currency: capture.currency, idempotency_key: RepaymentOperation.key_for(payment.id, sequence),
          source: source, evidence: { available_cents: available.available_cents, owed_cents: available.owed_cents,
            request_key: request_key }.compact)
        refund = order.refunds.create!(payment: payment, requested_by: requested_by, provider: payment.provider,
          idempotency_key: operation.idempotency_key, amount_cents: amount, currency: capture.currency,
          status: :pending, reason: reason || LateCaptureRefund::REASON, repayment_operation: operation,
          provider_payload: { repayment_operation_sequence: sequence })
        operation.update!(refund: refund)
        audit!(operation, "reserved", actor: requested_by,
          metadata: { owed_cents: available.owed_cents, available_cents: available.available_cents })
        refund
      end

      # The last local gate for a fenced payment's refund, under the order and
      # refund locks, before submission_requested is persisted. Returns true
      # when this transaction is the operation's one sender, false when there
      # is nothing to send (terminal, or a reservation it cancelled), and
      # raises Waiting when a send must wait without changing anything.
      def gate!(refund, replayable:)
        operation = refund.repayment_operation&.lock!
        raise RefundCreator::RefundError, "Repayment fence: this refund belongs to no repayment operation" unless operation
        return false if operation.terminal?
        raise Waiting, "repayment_inactive" unless submitter_active?

        capture = operation.unfulfilled_capture
        available = availability(capture, excluding_refund: refund)
        if operation.state == "reserved"
          # Never sent, so cancelling it is a verified terminal outcome; the
          # evaluator reserves a fresh operation once something is available.
          if available.waiting? || operation.amount_cents > available.available_cents
            cancel_reservation!(operation, refund, available)
            return false
          end
        else
          # A retry of a send that may still be in flight waits for the bound,
          # so there is one sender at a time; outside Stripe's replay window
          # an unknown operation goes to finance (RefundCreator).
          unless replayable && operation.last_submitted_at && operation.last_submitted_at <= in_flight_bound.ago
            raise Waiting, "refund_unknown"
          end
          raise Waiting, available.wait_reason if available.waiting? && available.wait_reason != "nothing_owed"
        end
        operation.update!(state: "submitting", submission_count: operation.submission_count + 1,
          last_submitted_at: Time.current)
        audit!(operation, "submission_requested", metadata: { submission: operation.submission_count })
        true
      end

      # Keeps the operation in step with its refund. Called after every write
      # of the refund's status, under the refund lock.
      def record_outcome!(refund)
        operation = refund.repayment_operation
        return unless operation

        operation.lock!
        return if operation.terminal?

        target = if refund.succeeded?
          "succeeded"
        elsif refund.failed? || refund.cancelled?
          "failed_terminal"
        end
        return unless target

        unsent = operation.state == "reserved"
        operation.update!(state: target, terminal_reason: refund.failure_code)
        audit!(operation, target, metadata: { refund_status: refund.status, failure_code: refund.failure_code,
          recorded_without_submission: unsent })
      end

      def record_unknown!(refund)
        operation = refund.repayment_operation
        return unless operation

        operation.lock!
        return unless operation.state == "submitting"

        operation.update!(state: "unknown")
        audit!(operation, "unknown", metadata: { failure_code: refund.failure_code })
      end

      def audit!(operation, action, actor: nil, metadata: {})
        capture = operation.unfulfilled_capture
        AuditLogger.record!(action: AUDIT_ACTIONS.fetch(action), auditable: operation, actor: actor,
          organization: capture.order.event.organization, event: capture.order.event,
          outcome: %w[failed_terminal unknown].include?(action) ? "failed" : "succeeded",
          deduplication_key: "repayment_operation:#{operation.id}:#{action}:#{operation.submission_count}",
          after_data: operation.attributes.slice("state", "submission_count", "refund_id"),
          metadata: { payment_id: operation.payment_id, sequence: operation.sequence,
            amount_cents: operation.amount_cents, idempotency_key: operation.idempotency_key }.merge(metadata))
      end

      private

      def wait_reason(capture, pending, open_disputes, excluding_refund)
        payment = capture.payment
        return "finance_review" if finance_review?(capture)
        return "evidence_unreplayed" if unreplayed_evidence?(payment)

        others = capture.repayment_operations.open_states
        others = others.where.not(refund_id: excluding_refund.id) if excluding_refund
        return "refund_unknown" if others.where(state: "unknown").exists? ||
          pending.where(failure_code: %w[provider_result_unknown provider_result_mismatch]).exists?
        return "refund_pending" if others.exists? || pending.exists?
        return "dispute_open" if open_disputes.exists?
        return "disputed_refund_unreconciled" if disputed_refund_unreconciled?(payment)

        nil
      end

      def finance_review?(capture)
        except = LateCaptureRefund::CODES + RefundCreator::LATE_CAPTURE_COMPANION_CODES + ORPHAN_CODES + [AGGREGATE_GAP_CODE]
        if capture.payment_scope?
          ReconciliationException.open.where(payment_id: capture.payment_id,
            code: RefundSafety::FINANCIAL_CODES - except).exists?
        else
          RefundSafety.finance_review_required?(capture.order, except_codes: [],
            except_payment_codes: { capture.payment_id => except })
        end
      end

      # A refund Stripe refused for a dispute waits until that charge's dispute
      # is recorded and reconciled (closed), never on a timer (§6.3, §6.4).
      def disputed_refund_unreconciled?(payment)
        refused = payment.refunds.failed.where("provider_payload ->> 'provider_error_code' IN (?)", DISPUTED_REFUND_CODES)
          .order(:id).last
        return false unless refused

        !Dispute.where(payment_id: payment.id).where.not(status: :open).exists?
      end

      def cancel_reservation!(operation, refund, available)
        operation.update!(state: "failed_terminal", terminal_reason: "superseded_before_submission")
        refund.update!(status: :cancelled, failed_at: Time.current, failure_code: "repayment_superseded",
          failure_message: WAIT_MESSAGES.fetch(available.wait_reason || "amount_exceeds_available"))
        audit!(operation, "failed_terminal", metadata: { reason: available.wait_reason || "amount_exceeds_available",
          available_cents: available.available_cents })
      end
    end
  end
end
