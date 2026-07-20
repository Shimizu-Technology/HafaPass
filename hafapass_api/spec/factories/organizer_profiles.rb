FactoryBot.define do
  factory :organizer_profile do
    association :user, :organizer
    business_name { "Island Nights Promotions" }
    business_description { "Premier nightlife events on Guam" }
    logo_url { "https://example.com/logo.png" }
    stripe_account_id { nil }
    is_ambros_partner { false }

    trait :verified do
      verification_status { :verified }
      verified_at { Time.current }
      policy_accepted_at { Time.current }
    end

    trait :payout_ready do
      verified
      payout_ready { true }
    end
  end
end
