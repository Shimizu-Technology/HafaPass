# frozen_string_literal: true

module Commerce
  class RefundSafety
    # These exceptions mean captured or returned money cannot yet be trusted.
    # Delivery and other nonfinancial exceptions do not block refund attempts.
    FINANCIAL_CODES = %w[
      payment_amount_mismatch payment_currency_mismatch payment_not_found
      late_payment_success_after_inventory_release late_payment_success_after_hold_expiry
      provider_payment_cancel_failed card_present_result_unknown
      refund_operation_not_found refund_operation_mismatch refund_terminal_status_conflict
      refunded_payment_not_found refund_missing_order_item_ledger provider_refund_total_decreased
      refund_aggregate_requires_reconciliation
    ].freeze

    def self.finance_review_required?(order)
      return false unless order

      relevant = ReconciliationException.open.where(code: FINANCIAL_CODES)
      relevant.where(order_id: order.id).or(relevant.where(payment_id: order.payments.select(:id))).exists?
    end
  end
end
