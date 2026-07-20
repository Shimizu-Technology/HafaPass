FactoryBot.define do
  factory :inventory_hold do
    association :order, factory: [:order, :pending]
    order_item { association :order_item, order: order }
    event { order.event }
    ticket_type { order_item.ticket_type }
    pricing_tier { order_item.pricing_tier }
    quantity { order_item.quantity }
    status { :active }
    expires_at { 10.minutes.from_now }
  end
end
