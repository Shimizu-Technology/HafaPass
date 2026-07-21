FactoryBot.define do
  factory :pilot_readiness_review do
    association :event
    actor_user { association :user, :admin }
    decision { :submission }
    evidence_reference { "private/pilot-readiness/test" }
    evidence_digest { Digest::SHA256.hexdigest("pilot-readiness-test") }
    event_state_digest { PilotReadiness.event_state_digest(event) }
    application_revision { PilotReadiness.application_revision }
    controls { PilotReadinessReview::CONTROL_KEYS.index_with(true) }
    assignments do
      PilotReadinessReview::ASSIGNMENT_KEYS.index_with do |role|
        { "name" => role.humanize, "contact_reference" => "private-directory/#{role}" }
      end
    end
    effective_at { 1.day.ago }
    expires_at { 90.days.from_now }

    trait :submission do
      decision { :submission }
      parent_review { nil }
    end
  end
end
