FactoryBot.define do
  factory :event do
    association :organizer_profile
    sequence(:title) { |n| "Beach Party #{n}" }
    description { "An amazing event on Guam's beaches" }
    short_description { "Beach party vibes" }
    venue_name { "Tumon Bay Beach" }
    venue_address { "123 Pale San Vitores Rd" }
    venue_city { "Tumon" }
    starts_at { 7.days.from_now }
    ends_at { 7.days.from_now + 4.hours }
    doors_open_at { 7.days.from_now - 30.minutes }
    timezone { "Pacific/Guam" }
    status { :draft }
    category { :nightlife }
    age_restriction { :all_ages }
    max_capacity { 500 }
    is_featured { false }

    trait :published do
      status { :published }
      published_at { Time.current }
    end

    trait :cancelled do
      status { :cancelled }
    end

    trait :completed do
      status { :completed }
      starts_at { 7.days.ago }
      ends_at { 7.days.ago + 4.hours }
    end

    trait :upcoming do
      starts_at { 7.days.from_now }
    end

    trait :past do
      starts_at { 7.days.ago }
      ends_at { 7.days.ago + 4.hours }
    end

    trait :featured do
      is_featured { true }
    end
  end
end
