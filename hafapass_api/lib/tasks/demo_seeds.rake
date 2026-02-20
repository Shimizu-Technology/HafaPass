namespace :db do
  desc "Seed demo events with realistic Guam data"
  task seed_demo: :environment do
    puts "Creating demo organizer profile..."

    # Find or create a demo user + organizer profile
    demo_user = User.find_or_create_by!(email: "demo@hafapass.com") do |u|
      u.first_name = "HafaPass"
      u.last_name = "Demo"
      u.role = "organizer"
      u.clerk_id = "demo_clerk_#{SecureRandom.hex(8)}"
    end

    organizer = OrganizerProfile.find_or_create_by!(user: demo_user) do |op|
      op.business_name = "HafaPass Demo Events"
      op.business_description = "Showcasing the best events on Guam"
    end

    puts "Creating demo events..."

    events_data = [
      {
        title: "Island Vibes Music Festival",
        slug: "island-vibes-music-festival",
        description: "Experience the ultimate island music festival featuring local and international artists. From reggae to island pop, enjoy a full day of live performances under the Guam sky. Food vendors, art installations, and good vibes all day long.",
        short_description: "A full-day outdoor music festival with local and international artists.",
        category: :concert,
        venue_name: "Gov. Joseph Flores Memorial Park (Ypao Beach)",
        venue_address: "Ypao Beach, Tumon, Guam 96913",
        venue_city: "Tumon",
        starts_at: Time.zone.parse("2026-03-14 16:00"),
        ends_at: Time.zone.parse("2026-03-14 23:00"),
        doors_open_at: Time.zone.parse("2026-03-14 15:30"),
        age_restriction: :all_ages,
        status: :published,
        published_at: Time.current,
        is_featured: true,
        max_capacity: 500,
        ticket_types: [
          { name: "General Admission", price_cents: 2500, quantity: 400, description: "Full festival access with all performances" },
          { name: "VIP Experience", price_cents: 7500, quantity: 100, description: "Front-stage area, complimentary drinks, VIP lounge access" },
        ]
      },
      {
        title: "Guam Food Truck Rally",
        slug: "guam-food-truck-rally",
        description: "Guam's favorite food trucks gather at Paseo de Susana for an evening of incredible eats. From CHamoru BBQ to Filipino fusion, Korean tacos to island desserts — bring your appetite! Live acoustic music, picnic seating, and family-friendly fun.",
        short_description: "Free entry food truck gathering with CHamoru BBQ, Filipino fusion, and more.",
        category: :dining,
        venue_name: "Paseo de Susana Park",
        venue_address: "Paseo de Susana, Hagåtña, Guam 96910",
        venue_city: "Hagåtña",
        starts_at: Time.zone.parse("2026-03-21 17:00"),
        ends_at: Time.zone.parse("2026-03-21 21:00"),
        age_restriction: :all_ages,
        status: :published,
        published_at: Time.current,
        is_featured: false,
        max_capacity: 1000,
        ticket_types: [
          { name: "Free Entry", price_cents: 0, quantity: 1000, description: "Free admission — just show up and eat!" },
        ]
      },
      {
        title: "Saturday Night Live Comedy",
        slug: "saturday-night-live-comedy",
        description: "Get ready for a night of nonstop laughs! Featuring stand-up comedians from across the Pacific, this comedy showcase brings the funny to Guam. Two-drink minimum at the bar. Mature content — 21+ only.",
        short_description: "Stand-up comedy showcase featuring Pacific island comedians.",
        category: :nightlife,
        venue_name: "Livehouse Guam",
        venue_address: "Marine Corps Dr, Tamuning, Guam 96913",
        venue_city: "Tamuning",
        starts_at: Time.zone.parse("2026-03-28 20:00"),
        ends_at: Time.zone.parse("2026-03-28 23:00"),
        doors_open_at: Time.zone.parse("2026-03-28 19:30"),
        age_restriction: :twenty_one_plus,
        status: :published,
        published_at: Time.current,
        is_featured: false,
        max_capacity: 150,
        ticket_types: [
          { name: "General Admission", price_cents: 1500, quantity: 150, description: "Includes entry and seating" },
        ]
      },
      {
        title: "Sunset Yoga on Tumon Beach",
        slug: "sunset-yoga-tumon-beach",
        description: "Unwind with a guided yoga session as the sun sets over Tumon Bay. Open to all levels — mats provided. Arrive 15 minutes early to settle in. Bring water and a towel. Led by certified instructor Lina Cruz.",
        short_description: "Beachside yoga at sunset — all levels welcome, mats provided.",
        category: :other,
        venue_name: "Tumon Beach (near Matapang Beach Park)",
        venue_address: "Tumon Beach, Tumon, Guam 96913",
        venue_city: "Tumon",
        starts_at: Time.zone.parse("2026-03-08 17:30"),
        ends_at: Time.zone.parse("2026-03-08 18:45"),
        age_restriction: :all_ages,
        status: :published,
        published_at: Time.current,
        is_featured: false,
        max_capacity: 40,
        ticket_types: [
          { name: "Yoga Pass", price_cents: 1000, quantity: 40, description: "Includes mat rental and guided session" },
        ]
      },
      {
        title: "CHamoru Cultural Night",
        slug: "chamoru-cultural-night",
        description: "Celebrate the rich heritage of the CHamoru people with an evening of traditional dance, chanting, storytelling, and a fiesta-style dinner. Learn about ancient navigation, weaving, and the history of the Mariana Islands. A truly immersive cultural experience.",
        short_description: "Traditional dance, storytelling, and fiesta dinner celebrating CHamoru heritage.",
        category: :festival,
        venue_name: "Sagan Kotturan CHamoru (CHamoru Cultural Center)",
        venue_address: "Adelup, Hagåtña, Guam 96910",
        venue_city: "Hagåtña",
        starts_at: Time.zone.parse("2026-03-15 18:00"),
        ends_at: Time.zone.parse("2026-03-15 21:30"),
        doors_open_at: Time.zone.parse("2026-03-15 17:30"),
        age_restriction: :all_ages,
        status: :published,
        published_at: Time.current,
        is_featured: true,
        max_capacity: 200,
        ticket_types: [
          { name: "General Admission", price_cents: 2000, quantity: 150, description: "Cultural show and fiesta dinner" },
          { name: "VIP Table", price_cents: 4000, quantity: 50, description: "Reserved front-row seating, priority dinner service, souvenir program" },
        ]
      },
    ]

    events_data.each do |event_data|
      ticket_types_data = event_data.delete(:ticket_types)

      event = Event.find_or_initialize_by(slug: event_data[:slug])
      event.assign_attributes(event_data.merge(organizer_profile: organizer))

      if event.save
        ticket_types_data.each do |tt_data|
          event.ticket_types.find_or_create_by!(name: tt_data[:name]) do |tt|
            tt.price_cents = tt_data[:price_cents]
            tt.quantity_available = tt_data[:quantity]
            tt.description = tt_data[:description]
          end
        end
        puts "  ✓ #{event.title} (#{event.ticket_types.count} ticket types)"
      else
        puts "  ✗ #{event.title}: #{event.errors.full_messages.join(', ')}"
      end
    end

    puts "\nDone! Created #{Event.count} events."
  end
end
