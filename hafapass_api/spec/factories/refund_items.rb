FactoryBot.define do
  factory :refund_item do
    association :refund
    order_item { association :order_item, order: refund.order }
    amount_cents { 500 }
    organizer_proceeds_cents { amount_cents }
    fee_cents { 0 }
    tax_cents { 0 }
    quantity { 0 }
  end
end
