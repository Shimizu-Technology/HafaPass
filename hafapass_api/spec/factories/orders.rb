FactoryBot.define do
  factory :order do
    association :event
    user { nil }
    status { :completed }
    subtotal_cents { 5000 }
    service_fee_cents { 250 }
    total_cents { 5250 }
    buyer_email { "buyer@example.com" }
    buyer_name { "Jane Smith" }
    buyer_phone { "671-555-0200" }
    stripe_payment_intent_id { nil }
    completed_at { Time.current }

    trait :pending do
      status { :pending }
      completed_at { nil }
    end

    trait :refunded do
      status { :refunded }
    end

    trait :cancelled do
      status { :cancelled }
    end

    trait :with_user do
      association :user
    end
  end
end
