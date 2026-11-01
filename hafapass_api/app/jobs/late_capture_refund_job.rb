# frozen_string_literal: true

# Automatically refunds a card payment that succeeded after its order was
# released (see Commerce::LateCaptureRefund). OrderLifecycle enqueues it when
# it records a late_payment_success_* reconciliation exception.
#
# Retrying is safe: every attempt uses the same refund idempotency key. If the
# refund still cannot be sent, the exception stays open in the refund
# reconciliation queue for an administrator.
class LateCaptureRefundJob < ApplicationJob
  queue_as :default

  retry_on Commerce::RefundCreator::RefundError, wait: 5.minutes, attempts: 3 do |job, error|
    Sentry.capture_message("Automatic late-capture refund failed; finance review required",
      level: :error, fingerprint: ["late-capture-refund-failed"],
      extra: { payment_id: job.arguments.first, error: error.message })
  end

  def perform(payment_id)
    payment = Payment.find_by(id: payment_id)
    return unless payment && Commerce::LateCaptureRefund.open_issue?(payment)
    return unless payment.provider == "stripe" && %w[test live].include?(payment.provider_environment)

    if executions == 1
      Sentry.capture_message("Card payment succeeded after its order was released; refunding automatically",
        level: :warning, fingerprint: ["late-capture-detected"],
        extra: { payment_id: payment.id, order_id: payment.order_id, amount_cents: payment.amount_cents })
    end
    Commerce::LateCaptureRefund.call(payment: payment)
  end
end
