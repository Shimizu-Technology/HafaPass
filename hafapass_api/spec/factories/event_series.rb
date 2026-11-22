# frozen_string_literal: true

FactoryBot.define do
  factory :event_series do
    association :organization
    sequence(:name) { |n| "Tournament Series #{n}" }
    description { "Multi-night tournament event series" }
    status { :draft }
    revenue_share_bps { nil }
    revenue_share_base { "admissions_net_proceeds" }
    revenue_share_includes_door_cash { false }
  end

  factory :event_series_membership do
    association :event_series
    event { create(:event, organization: event_series.organization, organizer_profile: event_series.organization.organizer_profile || create(:organizer_profile, organization: event_series.organization)) }
    role { :regular_night }
    position { 0 }
  end
end
