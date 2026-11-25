# frozen_string_literal: true

# Replays or closes the sale effects held for an order's provider refunds and
# lost disputes once ownership or classification is decided
# (Commerce::SaleEffectHold). Takes organization -> event -> order itself.
class SaleEffectHoldJob < ApplicationJob
  queue_as :default

  def perform(order_id)
    order = Order.find_by(id: order_id)
    Commerce::SaleEffectHold.release!(order) if order
  end
end
