# frozen_string_literal: true

# Run periodically as well as the per-payment retry job. The database row is
# the durable recovery source if a queue entry is lost or retries exhaust.
class SweepPendingStripeFeesJob < ApplicationJob
  def perform
    Payment.where(provider: "stripe", status: [:succeeded, :partially_refunded, :refunded])
      .left_joins(:stripe_fee_evidence).where(stripe_fee_evidences: { id: nil }).find_each do |payment|
      next unless StripeProcessingFees.external_capture?(payment)

      StripeFeeEvidence.create!(payment: payment, context_digest: StripeProcessingFees.context_digest(payment), next_attempt_at: Time.current)
    rescue ActiveRecord::RecordNotUnique
      # Another sweep or capture transaction claimed this payment.
    end
    StripeFeeEvidence.status_pending.where("next_attempt_at IS NULL OR next_attempt_at <= ?", Time.current)
      .find_each { |evidence| StripeProcessingFeeJob.perform_later(evidence.payment_id) }
  end
end
