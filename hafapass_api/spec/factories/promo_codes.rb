FactoryBot.define do
  factory :promo_code do
    association :event
    sequence(:code) { |n| "PROMO#{n}" }
    discount_type { "percentage" }
    discount_value { 10 }
    max_uses { 100 }
    current_uses { 0 }
    active { true }
  end
end
