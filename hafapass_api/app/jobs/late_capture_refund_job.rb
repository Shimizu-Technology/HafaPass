# frozen_string_literal: true

# Returns a never-fulfilled capture to its buyer (Commerce::LateCaptureRefund).
# OrderLifecycle enqueues it when it records a late capture, and the evaluator
# (Commerce::NeverFulfilledResolution) enqueues it whenever money is owed and
# available.
#
# Retrying is safe: a retry continues the payment's open repayment operation
# with that operation's key, and a new operation is only reserved after the
# earlier ones are verified. A wait (the A1-R1 inactive submitter, a pending
# refund, an open dispute, unrecorded provider evidence) ends the job quietly;
# the evaluator enqueues it again when the wait clears. If the refund still
# cannot be sent, the exception stays open in the refund reconciliation queue.
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
      Sentry.capture_message("Card payment succeeded after its order was released; returning it to the buyer",
        level: :warning, fingerprint: ["late-capture-detected"],
        extra: { payment_id: payment.id, order_id: payment.order_id, amount_cents: payment.amount_cents,
          submitter_active: Commerce::BuyerRepayment.submitter_active? })
    end
    Commerce::LateCaptureRefund.call(payment: payment)
  rescue Commerce::BuyerRepayment::Waiting, Commerce::LateCaptureRefund::NotApplicable => e
    Rails.logger.info("Late-capture repayment for payment #{payment_id} waits: #{e.message}")
    # An older release's refund on this payment is settled by lookup, never resent.
    Commerce::RepaymentAdjudication.enqueue_for!(payment) if payment && e.is_a?(Commerce::BuyerRepayment::Waiting)
    nil
  end
end
