# frozen_string_literal: true

# Stripe notice types whose stored payload StripeWebhookProcessor.replay!
# can apply once their payment is bound or captured (design §7.2). Kept out
# of the processor so the audit-action inventory does not read event types
# as audit actions.
module StripeReplayableEvents
  TYPES = %w[refund.created refund.updated refund.failed charge.refund.updated charge.refunded
    charge.dispute.created charge.dispute.updated charge.dispute.closed].freeze
end
