# frozen_string_literal: true

module Commerce
  # The repayments A1-R1 left waiting (A1-R1 review, R2 activation). R1's
  # LateCaptureRefundJob ends quietly with repayment_inactive, and changing
  # SUBMITTER_ACTIVE creates no new work, so after R2 is live home base runs
  # the rake task once to enqueue each waiting capture's job. It reads only;
  # the job reserves under the order lock and the gate rechecks everything.
  # In R1 (submitter inactive) it only counts, whatever is asked.
  class RepaymentBacklog
    Entry = Struct.new(:payment_id, :order_id, :capture_scope, :owed_cents, :wait_reason, keyword_init: true)
    Report = Struct.new(:entries, :enqueued, keyword_init: true)

    def self.call(enqueue: false)
      entries = waiting_captures.map do |capture|
        availability = BuyerRepayment.availability(capture)
        Entry.new(payment_id: capture.payment_id, order_id: capture.order_id, capture_scope: capture.capture_scope,
          owed_cents: availability.owed_cents, wait_reason: availability.wait_reason)
      end
      owed = entries.select { |entry| entry.owed_cents.positive? }
      enqueued = 0
      if enqueue && BuyerRepayment.submitter_active?
        owed.each { |entry| LateCaptureRefundJob.perform_later(entry.payment_id) }
        enqueued = owed.length
      end
      Report.new(entries: entries, enqueued: enqueued)
    end

    # Classified captures with an open exception the repayment resolves.
    def self.waiting_captures
      codes = NeverFulfilledResolution.resolvable_codes(UnfulfilledCapture.new(capture_scope: "payment"))
      UnfulfilledCapture.where(payment_id: ReconciliationException.open.where(code: codes).select(:payment_id))
        .includes(:payment, :order).order(:id)
    end
  end
end
