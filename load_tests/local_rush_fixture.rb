# frozen_string_literal: true

# Seeds the local 600-buyer / 200-ticket rush fixtures (see load_tests/README.md).
# Run with `bin/rails runner ../load_tests/local_rush_fixture.rb` against a
# throwaway local database only. It refuses any other target.
database = ActiveRecord::Base.connection_db_config
host = database.configuration_hash[:host].to_s
unless %w[localhost 127.0.0.1].include?(host) && database.database.to_s.match?(/bench|load/) && !Rails.env.production?
  abort "Refusing to seed: use a local database whose name contains 'bench' or 'load' (got #{database.database}@#{host})"
end

SiteSetting.instance.update_columns(payment_mode: "simulate")
owner = User.create!(clerk_id: "load_bench_owner", email: "load-bench-owner@example.invalid", first_name: "Load",
  last_name: "Bench", role: :organizer)
org = Organization.create!(name: "Load Bench Org", timezone: "Pacific/Guam", currency: "usd", status: :active)
profile = OrganizerProfile.create!(user: owner, organization: org, business_name: "Load Bench",
  business_description: "Local rush fixture")
base = { organizer_profile: profile, organization: org, description: "Local rush fixture", short_description: "bench",
  venue_name: "Bench Venue", venue_address: "1 Bench Rd", venue_city: "Hagatna", timezone: "Pacific/Guam",
  status: :published, published_at: Time.current, category: :sports, age_restriction: :all_ages }
start = 9.days.from_now.change(hour: 19)

single = Event.create!(base.merge(title: "[LOAD TEST] Copa Rush Single", max_capacity: 200, starts_at: start,
  ends_at: start + 3.hours, doors_open_at: start - 30.minutes))
single_type = TicketType.create!(event: single, name: "Free GA", description: "bench", price_cents: 0,
  quantity_available: 200, max_per_order: 10)

pass_event = Event.create!(base.merge(title: "[LOAD TEST] Copa Rush Pass", max_capacity: 200, starts_at: start,
  ends_at: start + 2.days, doors_open_at: start - 30.minutes))
nights = 2.times.map do |index|
  night_start = start + index.days
  Event.create!(base.merge(title: "[LOAD TEST] Copa Rush Night #{index + 1}", max_capacity: 200,
    starts_at: night_start, ends_at: night_start + 3.hours, doors_open_at: night_start - 30.minutes))
end
pass_type = TicketType.create!(event: pass_event, name: "Free Pass", description: "bench", price_cents: 0,
  quantity_available: 200, max_per_order: 10, is_pass: true)
nights.each_with_index do |night, index|
  TicketTypeIncludedEvent.create!(ticket_type: pass_type, included_event: night, position: index)
end

puts({ single: { EVENT_SLUG: single.slug, TICKET_TYPE_ID: single_type.id },
  pass: { EVENT_SLUG: pass_event.slug, TICKET_TYPE_ID: pass_type.id }, ORG_SLUG: org.slug }.to_json)
