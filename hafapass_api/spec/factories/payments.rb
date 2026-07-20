FactoryBot.define do
  factory :payment do
    association :order, factory: [:order, :pending]
    provider { "stripe" }
    sequence(:provider_payment_id) { |n| "pi_test_#{n}" }
    sequence(:idempotency_key) { |n| "payment-test-#{n}" }
    amount_cents { order.total_cents }
    currency { order.currency }
    status { :pending }

    trait :succeeded do
      status { :succeeded }
      succeeded_at { Time.current }
    end
  end
end
