FactoryBot.define do
  factory :refund do
    association :order
    payment { association :payment, :succeeded, order: order }
    provider { "stripe" }
    sequence(:provider_refund_id) { |n| "re_test_#{n}" }
    sequence(:idempotency_key) { |n| "refund-test-#{n}" }
    amount_cents { 1000 }
    currency { order.currency }
    status { :succeeded }
    succeeded_at { Time.current }
  end
end
