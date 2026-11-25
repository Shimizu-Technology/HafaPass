# frozen_string_literal: true

module Commerce
  # Settles an outbound refund on a fenced payment that the repayment
  # workflow did not send: a reservation or a request an older release made
  # before the A1-R1 fence (docs/design/never-fulfilled-captures.md §10.5
  # item 4, M-06, M-07). It never sends a refund. It only looks the request
  # up at Stripe by its own idempotency key and records what it finds:
  #
  #   found                      -> recorded through RefundCreator's normal finalization
  #   never past the gate        -> cancelled (the fence refuses its gate, so it cannot send)
  #   past the gate, absent, and
  #   older than the in-flight bound -> cancelled as provider_request_absent
  #   past the gate, absent, newer   -> left in flight (it may still land)
  #
  # The legacy first-operation key ("late-capture:payment:<id>") is adopted as
  # repayment operation 1, so a later top-up is operation 2 with its own key.
  #
  # Locks: the Stripe lookup runs before any lock; recording takes the refund
  # prefix organization -> event -> order -> refund -> operation.
  class RepaymentAdjudication
    Result = Struct.new(:refund, :outcome, keyword_init: true)

    # Pending outbound refunds on the payment that no new operation sent:
    # legacy rows, including the adopted first operation.
    def self.candidates(payment)
      legacy = Refund.where(repayment_operation_id: nil)
        .or(Refund.where(repayment_operation_id: RepaymentOperation.where(adopted: true).select(:id)))
      payment.refunds.pending.where(provider_refund_id: nil).merge(legacy)
        .where.not("idempotency_key LIKE 'provider:stripe:refund:%'").order(:id)
    end

    # Enqueues each candidate for when its in-flight bound has passed.
    def self.enqueue_for!(payment)
      candidates(payment).find_each do |refund|
        due = new(refund, Time.current).send(:due_at)
        RepaymentAdjudicationJob.set(wait_until: [due, Time.current].max).perform_later(refund.id)
      end
    end

    def self.call(refund, now: Time.current)
      new(refund, now).call
    end

    # Adopts a legacy refund that used the first operation's key, whatever
    # its state. Caller holds the order lock.
    def self.adopt_legacy!(capture)
      return if capture.repayment_operations.exists?

      refund = capture.payment.refunds.find_by(idempotency_key: RepaymentOperation.key_for(capture.payment_id, 1))
      return unless refund

      refund.lock!
      state = if refund.succeeded? then "succeeded"
      elsif refund.failed? || refund.cancelled? then "failed_terminal"
      elsif refund.provider_refund_id.present? || refund.failure_code.present? then "unknown"
      else "reserved"
      end
      operation = capture.repayment_operations.create!(payment: capture.payment, sequence: 1,
        amount_cents: refund.amount_cents, currency: refund.currency, idempotency_key: refund.idempotency_key,
        source: "adoption", adopted: true, refund: refund, state: state,
        submission_count: state == "reserved" ? 0 : 1,
        evidence: { refund_status: refund.status, failure_code: refund.failure_code })
      refund.update!(repayment_operation: operation)
      BuyerRepayment.audit!(operation, "adopted", metadata: { refund_id: refund.id, state: state })
      operation
    end

    def initialize(refund, now)
      @refund = refund
      @now = now
    end

    def call
      payment = refund.payment
      raise RefundCreator::RefundError, "Only a fenced Stripe payment's refund is adjudicated" unless
        payment&.provider == "stripe" && BuyerRepayment.fenced_payment?(payment)
      return Result.new(refund: refund, outcome: "not_pending") unless refund.pending? && refund.provider_refund_id.blank?

      past_gate = refund.failure_code.present?
      provider = lookup(payment) if past_gate
      lock! do
        refund.reload
        next Result.new(refund: refund, outcome: "not_pending") unless refund.pending? && refund.provider_refund_id.blank?

        capture = UnfulfilledCapture.find_by(payment_id: payment.id)
        self.class.adopt_legacy!(capture) if capture
        if provider
          RefundCreator.reconcile_refund!(refund: refund, provider_refund: provider)
          next Result.new(refund: refund.reload, outcome: "recorded")
        end
        if past_gate && submitted_at > BuyerRepayment.in_flight_bound.ago(now)
          next Result.new(refund: refund, outcome: "in_flight")
        end

        code = past_gate ? "provider_request_absent" : "fenced_reservation_unsent"
        refund.update!(status: :cancelled, failed_at: now, failure_code: code,
          failure_message: past_gate ? "Stripe has no refund for this request after the in-flight bound" :
            "Reserved before the repayment fence and never submitted")
        AuditLogger.record!(action: "refund.failed", auditable: refund, organization: payment.order.event.organization,
          event: payment.order.event, outcome: "failed", source: "provider",
          deduplication_key: "refund:#{refund.id}:adjudicated:#{code}",
          after_data: refund.attributes.slice("status", "provider_refund_id", "failure_code"),
          metadata: { order_id: refund.order_id, payment_id: payment.id, amount_cents: refund.amount_cents,
            currency: refund.currency, provider_observation: {}, manual_record: false, adjudication: code,
            submitted_at: submitted_at&.iso8601, in_flight_bound_seconds: BuyerRepayment.in_flight_bound.to_i })
        NeverFulfilledResolution.evaluate!(capture, trigger: "adjudication") if capture
        Result.new(refund: refund, outcome: code)
      end
    end

    private

    attr_reader :refund, :now

    def lookup(payment)
      StripeService.find_refund(payment.provider_payment_id, idempotency_key: refund.idempotency_key, payment: payment)
    end

    def due_at
      refund.failure_code.present? ? submitted_at + BuyerRepayment.in_flight_bound : Time.current
    end

    # When the last local gate let it go: its submission audit, else the
    # row's last write (old code writes both in the gate transaction).
    def submitted_at
      @submitted_at ||= AuditLog.where(action: "refund.submission_requested", auditable_type: "Refund",
        auditable_id: refund.id).maximum(:occurred_at) || refund.updated_at
    end

    def lock!(&)
      order = refund.order
      Order.transaction do
        order.event.organization.lock!("FOR NO KEY UPDATE")
        order.event.lock!
        order.lock!
        refund.lock!
        yield
      end
    end
  end
end
