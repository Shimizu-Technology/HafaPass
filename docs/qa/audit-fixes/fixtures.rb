abort 'Wrong database' unless ActiveRecord::Base.connection.select_value('SELECT current_database()') == 'hafapass_audit_fixes_test'
abort 'Expected an empty throwaway DB' unless Event.count.zero?
organization = Organization.create!(name: 'Audit fixes QA', timezone: 'Pacific/Guam', currency: 'usd', status: :active)
profile = OrganizerProfile.create!(organization: organization, business_name: 'Audit fixes QA', verification_status: :verified, verified_at: Time.current)
['Hagåtña', 'Yigo'].each do |village|
  event = Event.create!(organization: organization, organizer_profile: profile, title: 'Guam community night', status: :published, category: :concert, description: 'Synthetic audit fixture. No real admission or sales.', venue_name: 'QA Community Hall', venue_city: village, starts_at: 7.days.from_now, ends_at: 7.days.from_now + 3.hours, timezone: 'Pacific/Guam', max_capacity: 100)
  event.ticket_types.create!(name: 'General admission', price_cents: 0, quantity_available: 100)
end
puts "Owned fixture DB: #{ActiveRecord::Base.connection.select_value('SELECT current_database()')}; #{Event.count} events"
