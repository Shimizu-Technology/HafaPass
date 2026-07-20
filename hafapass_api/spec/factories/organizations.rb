FactoryBot.define do
  factory :organization do
    sequence(:name) { |n| "Island Events #{n}" }
    timezone { "Pacific/Guam" }
    currency { "usd" }
    status { :active }
  end

  factory :organization_membership do
    association :organization
    association :user
    role { :owner }
    status { :active }
    accepted_at { Time.current }
  end

  factory :event_staff_assignment do
    association :organization
    association :event
    association :user
    role { :scanner }
    status { :active }

    after(:build) do |assignment|
      assignment.organization = assignment.event.organization if assignment.event
    end
  end

  factory :connected_account do
    association :organization
    provider { "paypal" }
    sequence(:provider_account_id) { |n| "merchant_#{n}" }
    status { :ready }
    charges_enabled { true }
    payouts_enabled { true }
    details_submitted { true }
    requirements_due { [] }
    country { "GU" }
    currency { "usd" }
  end

  factory :balance_adjustment do
    association :organization
    event { nil }
    order { nil }
    dispute { nil }
    created_by_user { association :user, :admin }
    kind { "manual_credit" }
    amount_cents { 100 }
    currency { organization.currency }
    status { :posted }
    reason { "Reconciliation adjustment" }
    effective_at { Time.current }
  end

  factory :settlement do
    association :organization
    event { association :event, organization: organization, organizer_profile: association(:organizer_profile, organization: organization) }
    sequence(:version) { |n| n }
    status { :finalized }
    currency { organization.currency }
    sequence(:source_digest) { |n| Digest::SHA256.hexdigest("settlement-#{n}") }
    calculated_at { Time.current }
    finalized_at { Time.current }
  end

  factory :payout do
    association :organization
    event { association :event, organization: organization, organizer_profile: association(:organizer_profile, organization: organization) }
    settlement { association :settlement, organization: organization, event: event }
    connected_account { association :connected_account, organization: organization }
    provider { connected_account.provider }
    sequence(:idempotency_key) { |n| "payout-#{n}" }
    amount_cents { 100 }
    currency { organization.currency }
    status { :pending }
  end
end
