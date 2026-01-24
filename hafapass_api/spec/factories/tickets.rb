FactoryBot.define do
  factory :ticket do
    association :order
    association :ticket_type
    event { order.event }
    qr_code { nil }
    status { :issued }
    attendee_name { nil }
    attendee_email { nil }
    checked_in_at { nil }

    trait :checked_in do
      status { :checked_in }
      checked_in_at { Time.current }
    end

    trait :cancelled do
      status { :cancelled }
    end

    trait :transferred do
      status { :transferred }
    end
  end
end
