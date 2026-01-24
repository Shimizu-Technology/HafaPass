FactoryBot.define do
  factory :user do
    sequence(:clerk_id) { |n| "clerk_#{n}" }
    sequence(:email) { |n| "user#{n}@example.com" }
    first_name { "John" }
    last_name { "Doe" }
    phone { "671-555-0100" }
    role { :attendee }

    trait :organizer do
      role { :organizer }
    end

    trait :admin do
      role { :admin }
    end
  end
end
