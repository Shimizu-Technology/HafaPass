FactoryBot.define do
  factory :order_item do
    association :order
    ticket_type { association :ticket_type, event: order.event }
    pricing_tier { nil }
    name { ticket_type.name }
    tier_name { nil }
    unit_price_cents { 2500 }
    quantity { 1 }
    subtotal_cents { unit_price_cents * quantity }
    discount_cents { 0 }
    fee_cents { 125 }
    tax_cents { 0 }
    organizer_proceeds_cents { subtotal_cents - discount_cents }
    currency { "usd" }
  end
end
