abort 'Wrong database' unless ActiveRecord::Base.connection.select_value('SELECT current_database()') == 'hafapass_pass_dir'
abort 'Expected an empty throwaway DB' unless Event.count.zero?
organization = Organization.create!(name: 'Pass direction QA', timezone: 'Pacific/Guam', currency: 'usd', status: :active)
profile = OrganizerProfile.create!(organization: organization, business_name: 'Pass direction QA', verification_status: :verified, verified_at: Time.current)
['Guam community night', 'An evening of food, music and stories with our neighbors in Mongmong-Toto-Maite', 'Weekend printmaking workshop', 'Guam community night'].each_with_index do |title,index|
 event = Event.create!(organization: organization, organizer_profile: profile, title: title, status: :published, category: :concert, description: 'Synthetic public design rehearsal. No real admission or sales.', venue_name: 'QA Community Hall', venue_city: index == 3 ? 'Yigo' : 'Hagåtña', starts_at: 7.days.from_now + index.days, ends_at: 7.days.from_now + index.days + 3.hours, timezone: 'Pacific/Guam', max_capacity: 100)
 event.ticket_types.create!(name: 'General admission', price_cents: index == 1 ? 0 : 2500, quantity_available: 100)
end
puts "Owned fixture DB: #{ActiveRecord::Base.connection.select_value('SELECT current_database()')}; #{Event.count} events"
