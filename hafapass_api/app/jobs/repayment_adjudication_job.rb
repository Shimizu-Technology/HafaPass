# frozen_string_literal: true

# Settles a legacy outbound refund on a fenced payment once its in-flight
# bound has passed (Commerce::RepaymentAdjudication). Lookups only; it never
# sends a refund. Enqueued by LateCaptureRefundJob when a repayment waits on
# such a refund, and by the admin "Refund buyer" action.
class RepaymentAdjudicationJob < ApplicationJob
  queue_as :default

  def perform(refund_id)
    refund = Refund.find_by(id: refund_id)
    return unless refund&.pending?

    result = Commerce::RepaymentAdjudication.call(refund)
    return unless result.outcome == "in_flight"

    self.class.set(wait_until: Time.current + Commerce::BuyerRepayment.in_flight_bound).perform_later(refund_id)
  rescue StripeService::AmbiguousRefund, StripeService::PaymentError, Stripe::StripeError => e
    Sentry.capture_message("Legacy refund on a never-fulfilled payment needs finance review",
      level: :error, fingerprint: ["repayment-adjudication-failed"], extra: { refund_id: refund_id, error: e.message })
  end
end
