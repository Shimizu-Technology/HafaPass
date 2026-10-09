# frozen_string_literal: true

module Commerce
  class RefundOutcome
    def self.call(order:, idempotency_key:)
      refund = order&.refunds&.find_by(idempotency_key: idempotency_key)
      {
        reconciliation_required: refund&.pending? || false,
        refund_id: refund&.id,
        refund_status: refund&.status
      }.compact
    end
  end
end
