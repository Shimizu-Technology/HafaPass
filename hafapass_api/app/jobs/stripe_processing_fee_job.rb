# frozen_string_literal: true

class StripeProcessingFeeJob < ApplicationJob
  retry_on StripeProcessingFees::RetryableError, wait: :polynomially_longer, attempts: 12

  def perform(payment_id)
    payment = Payment.find_by(id: payment_id)
    StripeProcessingFees.call(payment: payment) if payment
  end
end
