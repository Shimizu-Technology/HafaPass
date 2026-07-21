FactoryBot.define do
  factory :venue_layout do
    association :venue
    association :organization
    sequence(:name) { |n| "Main Floor #{n}" }
    version { 1 }
    status { :published }
    renderer { :internal }
  end

  factory :seating_price_zone do
    association :venue_layout
    sequence(:name) { |n| "Zone #{n}" }
    sequence(:code) { |n| "ZONE#{n}" }
    color { "#2563EB" }
  end

  factory :seating_section do
    association :venue_layout
    sequence(:name) { |n| "Section #{n}" }
    sequence(:code) { |n| "SEC#{n}" }
  end

  factory :seating_row do
    association :seating_section
    sequence(:label) { |n| "R#{n}" }
  end

  factory :venue_seat do
    association :seating_row
    seating_price_zone { association :seating_price_zone, venue_layout: seating_row.seating_section.venue_layout }
    sequence(:label) { |n| n.to_s }
    sequence(:position) { |n| n }
    accessibility_kind { :standard }
  end

  factory :event_seating_configuration do
    event { association :event, venue: association(:venue) }
    venue_layout do
      association :venue_layout, venue: event.venue, organization: event.organization
    end
    status { :active }
    activated_at { Time.current }
  end

  factory :event_seat do
    association :event_seating_configuration
    venue_seat do
      association :venue_seat,
        seating_row: association(:seating_row,
          seating_section: association(:seating_section, venue_layout: event_seating_configuration.venue_layout)),
        seating_price_zone: association(:seating_price_zone, venue_layout: event_seating_configuration.venue_layout)
    end
    ticket_type { association :ticket_type, event: event_seating_configuration.event }
    operational_status { :available }
  end
end
