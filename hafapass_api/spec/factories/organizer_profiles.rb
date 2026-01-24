FactoryBot.define do
  factory :organizer_profile do
    user { nil }
    business_name { "MyString" }
    business_description { "MyText" }
    logo_url { "MyString" }
    stripe_account_id { "MyString" }
    is_ambros_partner { false }
  end
end
