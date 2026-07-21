FactoryBot.define do
  factory :catalog_item do
    association :event
    sequence(:name) { |n| "Event add-on #{n}" }
    kind { :add_on }
    price_cents { 1000 }
    inventory_quantity { 50 }

    trait :donation do
      kind { :donation }
      price_cents { 500 }
      minimum_price_cents { 500 }
      inventory_quantity { nil }
    end
  end

  factory :registration_question do
    association :event
    sequence(:prompt) { |n| "Registration question #{n}" }
    kind { :short_text }
    required { true }
  end

  factory :event_waiver do
    association :event
    sequence(:title) { |n| "Event waiver #{n}" }
    body { "I understand and accept the event rules." }
    sequence(:version) { |n| "1.#{n}" }
    required { true }
  end

  factory :promoter do
    association :event
    sequence(:name) { |n| "Promoter #{n}" }
    sequence(:code) { |n| "PROMO_#{n}" }
    commission_bps { 1000 }
  end

  factory :waitlist_offer do
    association :waitlist_entry
    event { waitlist_entry.event }
    ticket_type { waitlist_entry.ticket_type || association(:ticket_type, event: event) }
    quantity { waitlist_entry.quantity }
    unit_price_cents { ticket_type.price_cents }
    expires_at { 30.minutes.from_now }
  end

  factory :ticket_transfer do
    association :ticket
    recipient_email { "recipient@example.com" }
    expires_at { 7.days.from_now }
  end

  factory :communication_campaign do
    association :event
    created_by_user { event.organizer_profile.user }
    name { "Door reminder" }
    subject { "Doors open soon" }
    body { "Bring your HafaPass ticket." }
    segment { { "type" => "all_attendees" } }
  end
end
