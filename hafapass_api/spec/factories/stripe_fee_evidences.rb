FactoryBot.define do
  factory :stripe_fee_evidence do
    association :payment, factory: [:payment, :succeeded]
    context_digest { StripeProcessingFees.context_digest(payment) }
    status { :pending }

    trait :verified do
      status { :verified }
      fee_component { association :fee_component, order: payment.order, kind: "processing", estimated: false, amount_cents: 100, provider_reference: provider_balance_transaction_id }
      sequence(:provider_charge_id) { |n| "ch_verified_fixture_#{n}" }
      sequence(:provider_balance_transaction_id) { |n| "txn_verified_fixture_#{n}" }
      evidence_digest { "f" * 64 }
      currency { payment.currency }
      amount_cents { payment.amount_cents }
      fee_cents { fee_component.amount_cents }
      net_cents { amount_cents - fee_cents }
      verified_at { Time.current }
    end
  end
end
