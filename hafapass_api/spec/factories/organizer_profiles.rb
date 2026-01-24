FactoryBot.define do
  factory :organizer_profile do
    association :user, :organizer
    business_name { "Island Nights Promotions" }
    business_description { "Premier nightlife events on Guam" }
    logo_url { "https://example.com/logo.png" }
    stripe_account_id { nil }
    is_ambros_partner { false }
  end
end
