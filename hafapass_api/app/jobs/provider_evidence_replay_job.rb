# frozen_string_literal: true

# Replays stored refund and dispute notices that arrived before their payment
# was bound or its capture recorded (StripeWebhookProcessor.replay!, design
# §7.2). Enqueued after commit when a payment gains its provider intent ID or
# is first captured, whichever happens first. Lookups are local only.
class ProviderEvidenceReplayJob < ApplicationJob
  queue_as :default

  def perform(payment_id)
    payment = Payment.find_by(id: payment_id)
    return unless payment

    StripeWebhookProcessor.replayable_receipts(payment).find_each do |receipt|
      StripeWebhookProcessor.replay!(receipt, payment: payment)
    end
  end
end
