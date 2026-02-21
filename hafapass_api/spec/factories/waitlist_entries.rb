FactoryBot.define do
  factory :waitlist_entry do
    association :event
    sequence(:email) { |n| "waitlist#{n}@example.com" }
    name { "Waitlist Person" }
    quantity { 1 }
    status { :waiting }

    trait :with_ticket_type do
      association :ticket_type
    end

    trait :notified do
      status { :notified }
      notified_at { Time.current }
      expires_at { 24.hours.from_now }
    end

    trait :expired do
      status { :expired }
      notified_at { 2.days.ago }
      expires_at { 1.day.ago }
    end

    trait :converted do
      status { :converted }
    end

    trait :cancelled do
      status { :cancelled }
    end
  end
end
