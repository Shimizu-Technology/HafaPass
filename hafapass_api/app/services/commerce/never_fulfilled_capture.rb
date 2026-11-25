# frozen_string_literal: true

module Commerce
  # The one definition of a "never-fulfilled capture" that every money reader
  # shares: the CPA monthly export, Settlements::Calculator and, through the
  # calculator, the payout statement, organizer finance summary and payout
  # creation.
  #
  # A never-fulfilled capture is a card payment that succeeded after HåfaPass
  # had already released its order (the hold expired, the inventory was
  # released, or every pass night was cancelled first). Commerce::OrderLifecycle
  # records the payment's success and a late-capture reconciliation exception
  # for that same payment in one transaction, issues no tickets and enqueues
  # LateCaptureRefundJob. The buyer is owed the whole payment back.
  #
  # Durable evidence, all of it on 7-year financial records:
  #   - the order has no completed_at (legacy completed orders with a null
  #     completed_at have no late-capture exception, so they stay fulfilled);
  #   - a captured payment on the order (succeeded, partially refunded or
  #     refunded);
  #   - a late-capture exception linked to that same payment and order, recorded
  #     within EVIDENCE_WINDOW of the payment's recording time.
  #
  # The classification depends only on the payment row and its own exception,
  # never on the month being reported or on when the exception's row happened
  # to be stamped. A capture at 23:59:59 whose exception is stamped 00:00:00
  # the next day is never-fulfilled in both months, so the roll-forward holds.
  module NeverFulfilledCapture
    CODES = LateCaptureRefund::CODES

    # OrderLifecycle writes the exception in the same transaction as the
    # capture, milliseconds apart (lock waits and retries included). The window
    # keeps a closed month stable: an exception created later by hand cannot
    # reclassify a capture that months already booked.
    EVIDENCE_WINDOW_SECONDS = 3_600

    # Who bears actual Stripe processing on a never-fulfilled capture.
    # NEEDS LEON/CPA CONFIRMATION. Working rule: HåfaPass bears it, because the
    # organizer never received the sale. The CPA export books it in
    # stripe_processing_costs_informational only, and Settlements::Calculator
    # charges the organizer nothing for it. Setting this to true charges the
    # organizer's share again in both readers (the CPA export through
    # organizer_processing_deducted, the calculator through processing_split),
    # and changes source digests for events with such processing.
    ORGANIZER_BEARS_PROCESSING = false

    # P5 and P9 (design §1). Snapshotted onto each classification row, so a
    # later change is prospective. P9's CPA sign-off is recorded against
    # NeverFulfilledClassification::POLICY_VERSION.
    DISPUTE_FEE_BEARER = :platform
    ALLOCATION_POLICY = :item_record

    CAPTURED_PAYMENT_STATUSES = %w[succeeded partially_refunded refunded].freeze

    module_function

    # The capture's recording time, the same expression the CPA and BPT
    # exports use to place a never-fulfilled capture in a month.
    def recorded_at_sql(table)
      "GREATEST(COALESCE(#{table}.succeeded_at, #{table}.created_at), #{table}.created_at)"
    end

    # SQL condition on an orders row (aliased `orders_table`) that is true for
    # a never-fulfilled capture. `payment_sql` narrows which payments count as
    # the qualifying capture (written against the alias `nf_pay`, for example
    # the CPA export's live USD Stripe capture test). `recorded_before` limits
    # the evidence to captures recorded before a time (a report's month end).
    def order_sql(orders_table: "orders", payment_sql: nil, recorded_before: nil)
      recorded_at = recorded_at_sql("nf_pay")
      conditions = [
        "nf_pay.order_id = #{orders_table}.id",
        "nf_pay.status IN (:statuses)",
        "nf_re.code IN (:codes)",
        "nf_re.created_at <= #{recorded_at} + make_interval(secs => :window)"
      ]
      conditions << "(#{payment_sql})" if payment_sql
      conditions << "#{recorded_at} < :recorded_before" if recorded_before
      ActiveRecord::Base.sanitize_sql_array([
        "(#{orders_table}.completed_at IS NULL AND EXISTS (SELECT 1 FROM payments nf_pay " \
        "INNER JOIN reconciliation_exceptions nf_re ON nf_re.payment_id = nf_pay.id AND nf_re.order_id = nf_pay.order_id " \
        "WHERE #{conditions.join(' AND ')}))",
        {
          statuses: Payment.statuses.values_at(*CAPTURED_PAYMENT_STATUSES),
          codes: CODES,
          window: EVIDENCE_WINDOW_SECONDS,
          recorded_before: recorded_before
        }
      ])
    end

    # The never-fulfilled orders among `order_ids`, as a Set.
    def order_ids_among(order_ids)
      ids = Array(order_ids)
      return Set.new if ids.empty?

      Set.new(Order.where(id: ids).where(order_sql).pluck(:id))
    end

    def organizer_bears_processing?
      ORGANIZER_BEARS_PROCESSING
    end

    # The design's writer entry point (§4.3). Readers in this module are
    # unchanged until A2.
    def classify!(**)
      NeverFulfilledClassification.classify!(**)
    end
  end
end
