FactoryBot.define do
  factory :ticket_type do
    event { nil }
    name { "MyString" }
    description { "MyText" }
    price_cents { 1 }
    quantity_available { 1 }
    quantity_sold { 1 }
    max_per_order { 1 }
    sales_start_at { "2026-01-24 15:35:43" }
    sales_end_at { "2026-01-24 15:35:43" }
    sort_order { 1 }
  end
end
