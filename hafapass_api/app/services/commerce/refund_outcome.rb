# frozen_string_literal: true

module Commerce
  class RefundOutcome
    def self.call(order:, idempotency_key:)
      refund = order&.refunds&.find_by(idempotency_key: idempotency_key)
      finance_review = RefundSafety.finance_review_required?(order)
      {
        reconciliation_required: finance_review || refund&.pending? || false,
        finance_review_required: finance_review,
        refund_id: refund&.id,
        refund_status: refund&.status
      }.compact
    end
  end
end
