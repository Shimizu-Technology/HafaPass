FactoryBot.define do
  factory :fee_component do
    association :order
    order_item { nil }
    kind { "platform" }
    amount_cents { 250 }
    currency { order.currency }
    estimated { true }
    metadata { {} }
  end
end
