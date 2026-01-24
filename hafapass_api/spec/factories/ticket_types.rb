FactoryBot.define do
  factory :ticket_type do
    association :event
    name { "General Admission" }
    description { "Standard entry ticket" }
    price_cents { 2500 }
    quantity_available { 100 }
    quantity_sold { 0 }
    max_per_order { 10 }
    sort_order { 0 }

    trait :vip do
      name { "VIP" }
      description { "VIP access with perks" }
      price_cents { 7500 }
      quantity_available { 20 }
      max_per_order { 4 }
      sort_order { 1 }
    end

    trait :sold_out do
      quantity_available { 10 }
      quantity_sold { 10 }
    end

    trait :free do
      name { "Free Entry" }
      price_cents { 0 }
    end
  end
end
