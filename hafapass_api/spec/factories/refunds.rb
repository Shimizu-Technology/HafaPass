FactoryBot.define do
  factory :refund do
    association :order
    # The order's own capture when it has one (the payment that owns the sale;
    # a refund on a fresh second capture would not), else a new one.
    payment do
      order.payments.where(status: Payment::CAPTURED_STATUSES).order(:id).first ||
        association(:payment, :succeeded, order: order)
    end
    provider { "stripe" }
    sequence(:provider_refund_id) { |n| "re_test_#{n}" }
    sequence(:idempotency_key) { |n| "refund-test-#{n}" }
    amount_cents { 1000 }
    currency { order.currency }
    status { :succeeded }
    succeeded_at { Time.current }
  end
end
