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

    transient do
      with_readiness_approval { true }
    end

    after(:create) do |account, evaluator|
      next unless evaluator.with_readiness_approval && account.status_ready?

      submitter = create(:user, :admin)
      approver = create(:user, :admin)
      snapshot = {
        evidence_reference: "test-evidence/#{account.id}",
        evidence_digest: Digest::SHA256.hexdigest("test-evidence-#{account.id}"),
        provider_approval_reference: "test-provider-approval/#{account.provider}",
        merchant_of_record: "organizer",
        fee_tax_schedule_reference: "test-fee-tax-v1",
        liability_schedule_reference: "test-liability-v1",
        controls: PaymentReadinessReview::CONTROL_KEYS.index_with(true),
        effective_at: 1.day.ago,
        expires_at: 1.year.from_now,
        provider_state_digest: account.readiness_state_digest
      }
      submission = create(:payment_readiness_review, :submission, connected_account: account,
        actor_user: submitter, **snapshot)
      create(:payment_readiness_review, :approval, connected_account: account,
        parent_review: submission, actor_user: approver, **snapshot)
    end
  end

  factory :payment_readiness_review do
    association :connected_account, with_readiness_approval: false
    actor_user { association :user, :admin }
    decision { :submission }
    evidence_reference { "ops/payment-readiness/test" }
    evidence_digest { Digest::SHA256.hexdigest("payment-readiness-test") }
    provider_approval_reference { "provider/approval/test" }
    merchant_of_record { "organizer" }
    fee_tax_schedule_reference { "finance/fee-tax-v1" }
    liability_schedule_reference { "legal/liability-v1" }
    controls { PaymentReadinessReview::CONTROL_KEYS.index_with(true) }
    effective_at { 1.day.ago }
    expires_at { 1.year.from_now }
    provider_state_digest { connected_account.readiness_state_digest }

    trait :submission do
      decision { :submission }
      parent_review { nil }
    end

    trait :approval do
      decision { :approval }
    end

    trait :revocation do
      decision { :revocation }
      reason { "Provider authorization withdrawn" }
    end


    trait :rejection do
      decision { :rejection }
      reason { "Evidence does not support the requested production scope" }
    end
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

  factory :scanner_device do
    association :organization
    event { association :event, :published, organization: organization,
      organizer_profile: association(:organizer_profile, organization: organization) }
    association :user
    sequence(:identifier) { |n| "scanner-device-#{n}" }
    sequence(:name) { |n| "Door device #{n}" }
    status { :active }
    authorization_expires_at { 2.hours.from_now }

    after(:build) do |device|
      device.organization = device.event.organization if device.event
    end
  end

  factory :admission_manifest do
    association :organization
    event { association :event, :published, organization: organization,
      organizer_profile: association(:organizer_profile, organization: organization) }
    sequence(:version) { |n| n }
    sequence(:source_digest) { |n| Digest::SHA256.hexdigest("admission-source-#{n}") }
    sequence(:digest) { |n| Digest::SHA256.hexdigest("admission-manifest-#{n}") }
    signature { "test-signature" }
    key_id { "test-key" }
    algorithm { "PS256" }
    payload { { schema_version: 1, tickets: [] } }
    ticket_count { 0 }
    generated_at { Time.current }
    expires_at { 2.hours.from_now }

    after(:build) do |manifest|
      manifest.organization = manifest.event.organization if manifest.event
    end
  end

  factory :admission_action do
    association :organization
    event { association :event, :published, organization: organization,
      organizer_profile: association(:organizer_profile, organization: organization) }
    ticket { nil }
    scanner_device { association :scanner_device, organization: organization, event: event }
    actor_user { scanner_device.user }
    sequence(:action_uuid) { |n| "admission-action-#{n}" }
    kind { :admit }
    source { :offline }
    result { :accepted }
    reason_code { "admitted" }
    sequence(:sequence) { |n| n }
    occurred_at { Time.current }
    received_at { Time.current }
  end

  factory :card_present_account do
    association :organization
    provider { "boh_clover" }
    status { :onboarding }
    connection_mode { :cloud }

    trait :verified do
      status { :verified }
      sequence(:merchant_id) { |n| "clover-merchant-#{n}" }
      sequence(:device_id) { |n| "clover-device-#{n}" }
      sequence(:pos_id) { |n| "hafapass-pos-#{n}" }
      sequence(:verification_evidence) do |n|
        { "guam_merchant_approved" => true, "provider" => "Bank of Hawaii Clover",
          "verification_reference" => "boh-approval-#{n}" }
      end
      verified_at { Time.current }
      verified_by_user { association :user, :admin }
    end
  end
end
