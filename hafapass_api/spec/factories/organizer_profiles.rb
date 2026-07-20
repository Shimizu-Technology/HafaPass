FactoryBot.define do
  factory :organizer_profile do
    association :user, :organizer
    association :organization
    business_name { "Island Nights Promotions" }
    business_description { "Premier nightlife events on Guam" }
    logo_url { "https://example.com/logo.png" }
    stripe_account_id { nil }
    is_ambros_partner { false }

    after(:create) do |profile|
      OrganizationMembership.find_or_create_by!(organization: profile.organization, user: profile.user) do |membership|
        membership.role = :owner
        membership.status = :active
        membership.accepted_at = Time.current
      end
    end

    trait :verified do
      verification_status { :verified }
      verified_at { Time.current }
      policy_accepted_at { Time.current }
      policy_version { PolicyRegistry.organizer_agreement[:version] }
      policy_digest { PolicyRegistry.organizer_agreement[:digest] }
    end

    trait :payout_ready do
      verified
      payout_ready { true }

      after(:create) do |profile|
        create(:connected_account, organization: profile.organization, provider: "legacy_manual")
      end
    end
  end
end
