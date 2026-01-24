FactoryBot.define do
  factory :order do
    user { nil }
    event { nil }
    status { 1 }
    subtotal_cents { 1 }
    service_fee_cents { 1 }
    total_cents { 1 }
    buyer_email { "MyString" }
    buyer_name { "MyString" }
    buyer_phone { "MyString" }
    stripe_payment_intent_id { "MyString" }
    completed_at { "2026-01-24 15:41:00" }
  end
end
