FactoryBot.define do
  factory :pricing_tier do
    association :ticket_type
    name { "Early Bird" }
    price_cents { 2000 }
    tier_type { :quantity_based }
    quantity_limit { 50 }
    quantity_sold { 0 }
    position { 0 }

    trait :time_based do
      tier_type { :time_based }
      quantity_limit { nil }
      starts_at { 1.day.ago }
      ends_at { 1.week.from_now }
    end

    trait :expired do
      tier_type { :time_based }
      quantity_limit { nil }
      starts_at { 2.weeks.ago }
      ends_at { 1.week.ago }
    end

    trait :sold_out do
      quantity_limit { 10 }
      quantity_sold { 10 }
    end
  end
end
