FactoryBot.define do
  factory :reconciliation_exception do
    order { nil }
    payment { nil }
    webhook_event { nil }
    code { "manual_review" }
    status { :open }
    details { {} }
  end
end
