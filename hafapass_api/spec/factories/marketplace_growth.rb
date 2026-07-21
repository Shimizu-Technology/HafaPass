FactoryBot.define do
  factory :venue do
    sequence(:name) { |n| "Guam Venue #{n}" }
    sequence(:slug) { |n| "guam-venue-#{n}" }
    address { "123 Marine Corps Drive" }
    village { "Hagåtña" }
    description { "A trusted Guam event venue." }
    verified { true }
    active { true }
  end

  factory :marketplace_collection do
    association :created_by_user, factory: :user
    sequence(:title) { |n| "Island Picks #{n}" }
    sequence(:slug) { |n| "island-picks-#{n}" }
    description { "Curated events for Guam." }
    status { :published }
  end

  factory :distribution_partner do
    sequence(:name) { |n| "Guam Hotel #{n}" }
    sequence(:slug) { |n| "guam-hotel-#{n}" }
    kind { :hotel }
    active { true }
  end

  factory :distribution_link do
    association :distribution_partner
    association :event
    association :created_by_user, factory: :user
    campaign { "summer-concierge" }
    active { true }
  end

  factory :event_reminder do
    association :user
    association :event
    remind_at { 1.day.from_now }
    status { :pending }
  end
end
