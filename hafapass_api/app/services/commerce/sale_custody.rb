# frozen_string_literal: true

module Commerce
  # Which capture puts an ordinary sale in custody, and when (A2 review
  # finding 4, 17324039). CpaMonthlyReport and TaxReports (BPT detail, the
  # monthly view and the annual organizer view) share these rules, so the
  # same order is collected, and its refunds recognized, in the same Guam
  # month by every reader.
  #
  #   qualifying  the order's recorded fulfilling payment when it has one
  #               (a Stripe second capture never qualifies a Clover sale),
  #               else any capture on it; never a payment-scope classified
  #               capture (that money is the buyer's, read from
  #               ClassifiedPaymentFinance).
  #   recorded    a capture's recording time: payments.created_at on a
  #               completed order (a later backfill enters in its own
  #               month), else GREATEST(success, creation).
  #   booked      an order's custody booking: GREATEST(completion, first
  #               qualifying capture's creation) on a completed order, else
  #               GREATEST(first qualifying capture's recording, its
  #               creation). A return is recognized no earlier (§5.3).
  module SaleCustody
    module_function

    # Code-built SQL (table aliases only, no input).
    def qualifying_sql(payments = "payments", orders = "orders")
      "((#{orders}.fulfilled_by_payment_id IS NULL OR #{payments}.id = #{orders}.fulfilled_by_payment_id) " \
        "AND NOT EXISTS (SELECT 1 FROM never_fulfilled_captures sale_custody_nfc " \
        "WHERE sale_custody_nfc.payment_id = #{payments}.id AND sale_custody_nfc.capture_scope = 'payment'))"
    end

    def capture_recorded_at_sql(payments = "payments", orders = "orders")
      "(CASE WHEN #{orders}.completed_at IS NOT NULL THEN #{payments}.created_at " \
        "ELSE GREATEST(COALESCE(#{payments}.succeeded_at, #{payments}.created_at), #{payments}.created_at) END)"
    end

    # Correlated on `orders` and a capture join exposing
    # first_capture_created_at and first_capture_recorded_at.
    def booked_at_sql(captures = "agent_cap", orders = "orders")
      "(CASE WHEN #{orders}.completed_at IS NOT NULL THEN GREATEST(#{orders}.completed_at, #{captures}.first_capture_created_at) " \
        "ELSE GREATEST(COALESCE(#{captures}.first_capture_recorded_at, #{orders}.created_at), " \
        "#{captures}.first_capture_created_at) END)"
    end

    # The per-order first qualifying capture times of `captures` (a Payment
    # relation), for INNER JOIN as `name`.
    def capture_times_join_sql(captures, name)
      times = captures.joins("INNER JOIN orders sale_custody_orders ON sale_custody_orders.id = payments.order_id")
        .where(qualifying_sql("payments", "sale_custody_orders"))
        .group("payments.order_id")
        .select("payments.order_id, MIN(payments.created_at) AS first_capture_created_at, " \
          "MIN(GREATEST(COALESCE(payments.succeeded_at, payments.created_at), payments.created_at)) AS first_capture_recorded_at")
      "INNER JOIN (#{times.to_sql}) #{name} ON #{name}.order_id = orders.id"
    end
  end
end
