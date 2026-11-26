# frozen_string_literal: true

module Commerce
  # How the organizer-side operational readers treat classified
  # (never-fulfilled) payments (docs/design/never-fulfilled-captures.md §8.2,
  # §8.3, §8.7, §8.10.9). It uses the same classification rules as the CPA
  # and BPT readers (Commerce::ClassifiedPaymentFinance): by table, never by
  # the late-capture exception window.
  #
  #   - An order-scope classified order is not a sale. Its items, fees,
  #     refunds, losses and processing never reach organizer proceeds, sales
  #     totals or custody (Order.excluding_never_fulfilled).
  #   - A payment-scope capture (payment B on an order payment A fulfilled)
  #     is isolated: A's sale stays, and B's refunds, losses and processing
  #     never act on it (Refund/Dispute.on_sale, excluding_isolated_payments).
  #   - Each classified capture shows on the statement as one $0 line,
  #     "Payment received, order unfulfilled", with metadata fixed at
  #     classification. Its live return status (BuyerReturnLedger) is shown
  #     next to it and never enters the approval digest.
  #   - Actual processing attributed to a classified capture follows the
  #     capture's snapshotted processing_bearer. Platform-borne processing is
  #     a HåfaPass cost and never appears in organizer figures.
  #   - A cash balance adjustment linked to classified money (order_id on an
  #     order-scope classified order, dispute_id on a classified payment's
  #     dispute, or the reversal of one) is not an organizer debit or credit.
  #     It stays on the statement at $0 and is alerted to finance. Reserve
  #     holds and releases are organizer controls, so they stay as booked.
  module ClassifiedOrganizerView
    INFO_DESCRIPTION = "Payment received, order unfulfilled"
    INFO_ADJUSTMENT_KIND = "never_fulfilled_capture"
    LINKED_ADJUSTMENT_ALERT = "classified_linked_adjustment"
    # Organizer controls: they hold or release the organizer's own money and
    # never book a platform amount, so a link to classified money leaves them
    # as booked.
    CONTROL_ADJUSTMENT_KINDS = %w[reserve_hold reserve_release].freeze

    RETURN_STATUSES = {
      "owed" => "Owed to the buyer",
      "partly_returned" => "Partly returned; the rest is owed to the buyer",
      "being_returned" => "Being returned to the buyer",
      "confirming" => "Return to the buyer being confirmed",
      "returned" => "Returned to the buyer"
    }.freeze

    module_function

    # True for a balance_adjustments row linked to classified money, itself
    # or through the adjustment it reverses (code-built SQL, no input).
    def linked_adjustment_sql(table = "balance_adjustments")
      "(#{own_link_sql(table)} OR EXISTS (SELECT 1 FROM balance_adjustments nfa_original " \
        "WHERE nfa_original.id = #{table}.reversal_of_id AND #{own_link_sql("nfa_original")}))"
    end

    # The linked adjustments that move cash (every kind except the controls).
    def linked_cash_adjustment_sql(table = "balance_adjustments")
      "(#{table}.kind NOT IN (#{CONTROL_ADJUSTMENT_KINDS.map { |kind| "'#{kind}'" }.join(", ")}) " \
        "AND #{linked_adjustment_sql(table)})"
    end

    def own_link_sql(table)
      "(#{ClassifiedPaymentFinance.classified_order_sql("#{table}.order_id")} OR EXISTS (SELECT 1 FROM disputes " \
        "nfa_dispute WHERE nfa_dispute.id = #{table}.dispute_id AND " \
        "#{ClassifiedPaymentFinance.classified_movement_sql("nfa_dispute")}))"
    end

    LINKED_CASH_ADJUSTMENT_SQL = linked_cash_adjustment_sql.freeze

    def linked_cash_adjustments(relation = BalanceAdjustment.all)
      relation.where(LINKED_CASH_ADJUSTMENT_SQL)
    end

    def organizer_adjustments(relation = BalanceAdjustment.all)
      relation.where("NOT #{LINKED_CASH_ADJUSTMENT_SQL}")
    end

    # Refunds and disputes on classified money (either scope) are platform
    # money: never an organizer debit, only a hold through their exceptions.
    def classified_refunds(relation = Refund.all)
      relation.where(ClassifiedPaymentFinance::CLASSIFIED_REFUND_SQL)
    end

    def classified_disputes(relation = Dispute.all)
      relation.where(ClassifiedPaymentFinance::CLASSIFIED_DISPUTE_SQL)
    end

    def organizer_refunds(relation = Refund.all)
      relation.where("NOT #{ClassifiedPaymentFinance::CLASSIFIED_REFUND_SQL}")
    end

    def organizer_disputes(relation = Dispute.all)
      relation.where("NOT #{ClassifiedPaymentFinance::CLASSIFIED_DISPUTE_SQL}")
    end

    # Fee components the classified projection owns (processing on an
    # order-scope classified order, or any component whose fee evidence names
    # a classified payment). Never organizer sales or fees.
    def organizer_fee_components(relation = FeeComponent.all)
      relation.where("NOT #{ClassifiedPaymentFinance::CLASSIFIED_COMPONENT_SQL}")
    end

    # Bearer for a processing component the classified captures own. An
    # unattributed component on an order-scope order (more than one capture
    # it could belong to) takes the organizer bearer if any capture on that
    # order has it, so an organizer-borne cost is never dropped; otherwise
    # HåfaPass bears it.
    def processing_bearer(row, captures_by_order)
      return row[:capture].processing_bearer if row[:capture]

      bearers = captures_by_order.fetch(row[:order_id], []).map(&:processing_bearer)
      bearers.include?("organizer") ? "organizer" : "platform"
    end

    # Live return status for the captures behind one $0 line. Read from
    # A1's ledger, never stored, never digested. "confirming" covers every
    # fact the ledger cannot settle yet: an unknown repayment operation, a
    # recorded movement with no posting, or a posting held for correction.
    # It never claims money was returned before a recognized posting says so.
    def return_status(captures)
      captures = Array(captures)
      ledgers = captures.map { |capture| BuyerReturnLedger.for(capture) }
      captured = ledgers.sum(&:captured_cents)
      owed = ledgers.sum(&:owed_cents)
      payment_ids = captures.map(&:payment_id)
      in_flight = Refund.pending.where(payment_id: payment_ids).sum(:amount_cents) +
        Dispute.open.where(payment_id: payment_ids).sum(:amount_cents)
      unknown = RepaymentOperation.where(never_fulfilled_capture_id: captures.map(&:id), state: "unknown").exists? ||
        BuyerReturnPosting.where(never_fulfilled_capture_id: captures.map(&:id))
          .where.not(recognition_state: "recognized").exists? ||
        NeverFulfilledReconcile.unposted_movement_payment_ids.intersect?(payment_ids)
      key = if unknown
        "confirming"
      elsif owed <= 0
        "returned"
      elsif in_flight.positive?
        "being_returned"
      elsif owed < captured
        "partly_returned"
      else
        "owed"
      end
      { status: key, label: RETURN_STATUSES.fetch(key), captured_cents: captured, owed_cents: [owed, 0].max,
        returned_cents: captured - owed, in_flight_cents: in_flight }
    end
  end
end
