# frozen_string_literal: true

# Re-evaluates a classified never-fulfilled capture after a transition that
# was recorded outside the order lock (a provider rejection or an unknown
# result recorded after the HTTP call, or a reservation the gate cancelled).
# It takes the refund prefix (organization -> event -> order) and runs the
# idempotent evaluator (docs/design/never-fulfilled-captures.md §7.1).
class NeverFulfilledResolutionJob < ApplicationJob
  queue_as :default

  def perform(payment_id, trigger = "after_commit")
    capture = UnfulfilledCapture.find_by(payment_id: payment_id)
    return unless capture

    order = capture.order
    Order.transaction do
      order.event.organization.lock!("FOR NO KEY UPDATE")
      order.event.lock!
      order.lock!
      Commerce::NeverFulfilledResolution.evaluate!(capture, trigger: trigger)
    end
  end
end
