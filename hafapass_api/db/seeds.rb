# HafaPass - Seed Data
# Creates realistic sample data for development and frontend verification
#
# Usage: rails db:seed
# To reset: rails db:reset (drops, creates, migrates, seeds)

puts "Seeding HafaPass development data..."

# Clear existing data in correct order (respecting foreign keys)
Ticket.destroy_all
Order.destroy_all
TicketType.destroy_all
Event.destroy_all
OrganizerProfile.destroy_all
User.destroy_all

puts "  Cleared existing data."

# --- Users ---

organizer1 = User.create!(
  clerk_id: "clerk_organizer_island_nights",
  email: "carlos@islandnights.gu",
  first_name: "Carlos",
  last_name: "Santos",
  phone: "+1-671-555-0101",
  role: :organizer
)

organizer2 = User.create!(
  clerk_id: "clerk_organizer_beach_club",
  email: "maria@guambeachclub.com",
  first_name: "Maria",
  last_name: "Cruz",
  phone: "+1-671-555-0202",
  role: :organizer
)

attendee1 = User.create!(
  clerk_id: "clerk_attendee_jake",
  email: "jake.miller@navy.mil",
  first_name: "Jake",
  last_name: "Miller",
  phone: "+1-671-555-0301",
  role: :attendee
)

attendee2 = User.create!(
  clerk_id: "clerk_attendee_sarah",
  email: "sarah.tanaka@gmail.com",
  first_name: "Sarah",
  last_name: "Tanaka",
  phone: "+1-671-555-0302",
  role: :attendee
)

attendee3 = User.create!(
  clerk_id: "clerk_attendee_mike",
  email: "mike.reyes@yahoo.com",
  first_name: "Mike",
  last_name: "Reyes",
  phone: "+1-671-555-0303",
  role: :attendee
)

puts "  Created #{User.count} users."

# --- Organizer Profiles ---

profile1 = OrganizerProfile.create!(
  user: organizer1,
  business_name: "Island Nights Promotions",
  business_description: "Guam's premier nightlife and event promotion company. We bring the best DJs, artists, and experiences to the island.",
  is_ambros_partner: true
)

profile2 = OrganizerProfile.create!(
  user: organizer2,
  business_name: "Guam Beach Club",
  business_description: "Beachfront venue and event space in Tumon Bay. Perfect for concerts, festivals, and private events with stunning ocean views.",
  is_ambros_partner: true
)

puts "  Created #{OrganizerProfile.count} organizer profiles."

# --- Events ---

# Event 1: Nightlife (published, upcoming, featured)
event1 = Event.create!(
  organizer_profile: profile1,
  title: "Full Moon Beach Party",
  description: "Dance under the full moon at Tumon Bay! Featuring DJ Kiko spinning tropical house, live fire dancers, and island cocktail specials all night long. The ultimate beach party experience on Guam.",
  short_description: "Full moon beach party with DJ Kiko and fire dancers at Tumon Bay",
  venue_name: "Tumon Bay Beach",
  venue_address: "1255 Pale San Vitores Road",
  venue_city: "Tumon",
  starts_at: 3.days.from_now.change(hour: 21, min: 0),
  ends_at: 3.days.from_now.change(hour: 2, min: 0) + 1.day,
  doors_open_at: 3.days.from_now.change(hour: 20, min: 30),
  status: :published,
  published_at: 2.days.ago,
  category: :nightlife,
  age_restriction: :twenty_one_plus,
  max_capacity: 500,
  is_featured: true,
  cover_image_url: "https://images.unsplash.com/photo-1519671482749-fd09be7ccebf?w=1200"
)

# Event 2: Nightlife (published, upcoming)
event2 = Event.create!(
  organizer_profile: profile1,
  title: "Neon Nights: UV Glow Party",
  description: "Get your glow on at Guam's biggest UV party! Body paint stations, neon decorations, and the best EDM DJs from across the Pacific. Wear white for maximum glow effect!",
  short_description: "UV glow party with body paint stations and EDM DJs",
  venue_name: "Globe Nightclub",
  venue_address: "199 Chalan San Antonio",
  venue_city: "Tamuning",
  starts_at: 7.days.from_now.change(hour: 22, min: 0),
  ends_at: 7.days.from_now.change(hour: 3, min: 0) + 1.day,
  doors_open_at: 7.days.from_now.change(hour: 21, min: 30),
  status: :published,
  published_at: 1.day.ago,
  category: :nightlife,
  age_restriction: :eighteen_plus,
  max_capacity: 300,
  is_featured: false,
  cover_image_url: "https://images.unsplash.com/photo-1574391884720-bbc3740c59d1?w=1200"
)

# Event 3: Concert (published, upcoming, featured)
event3 = Event.create!(
  organizer_profile: profile2,
  title: "Sunset Sessions: Island Reggae Concert",
  description: "Live island reggae featuring local artists and special guest performers from Hawaii. Enjoy the sunset from our beachfront stage with food trucks, craft beer garden, and family-friendly vibes until 8 PM.",
  short_description: "Live island reggae concert at sunset with local and Hawaiian artists",
  venue_name: "Guam Beach Club",
  venue_address: "801 Pale San Vitores Road",
  venue_city: "Tumon",
  starts_at: 5.days.from_now.change(hour: 17, min: 0),
  ends_at: 5.days.from_now.change(hour: 23, min: 0),
  doors_open_at: 5.days.from_now.change(hour: 16, min: 0),
  status: :published,
  published_at: 3.days.ago,
  category: :concert,
  age_restriction: :all_ages,
  max_capacity: 1000,
  is_featured: true,
  cover_image_url: "https://images.unsplash.com/photo-1459749411175-04bf5292ceea?w=1200"
)

# Event 4: Festival (published, upcoming)
event4 = Event.create!(
  organizer_profile: profile2,
  title: "Taste of Guam Food Festival",
  description: "Celebrate Guam's diverse culinary heritage! Over 30 local restaurants and food vendors serving chamorro BBQ, Filipino favorites, Japanese street food, and fusion dishes. Live cooking demos, eating contests, and live music all day.",
  short_description: "Food festival with 30+ vendors celebrating Guam's culinary diversity",
  venue_name: "Paseo de Susana Park",
  venue_address: "Marine Corps Drive",
  venue_city: "Hagatna",
  starts_at: 10.days.from_now.change(hour: 11, min: 0),
  ends_at: 10.days.from_now.change(hour: 21, min: 0),
  doors_open_at: 10.days.from_now.change(hour: 10, min: 30),
  status: :published,
  published_at: 5.days.ago,
  category: :festival,
  age_restriction: :all_ages,
  max_capacity: 2000,
  is_featured: false,
  cover_image_url: "https://images.unsplash.com/photo-1555939594-58d7cb561ad1?w=1200"
)

# Event 5: Draft (not published, only visible to organizer)
event5 = Event.create!(
  organizer_profile: profile1,
  title: "New Year's Eve Countdown",
  description: "Ring in the new year with Guam's biggest countdown party! Premium open bar, champagne toast at midnight, live DJ, and spectacular fireworks view from our rooftop venue.",
  short_description: "NYE countdown party with premium open bar and fireworks",
  venue_name: "Dusit Thani Guam Resort",
  venue_address: "1227 Pale San Vitores Road",
  venue_city: "Tumon",
  starts_at: 60.days.from_now.change(hour: 21, min: 0),
  ends_at: 60.days.from_now.change(hour: 2, min: 0) + 1.day,
  doors_open_at: 60.days.from_now.change(hour: 20, min: 0),
  status: :draft,
  category: :nightlife,
  age_restriction: :twenty_one_plus,
  max_capacity: 200,
  is_featured: false
)

# Event 6: Past/Completed event
event6 = Event.create!(
  organizer_profile: profile2,
  title: "Beach Volleyball Tournament",
  description: "Annual beach volleyball tournament at Gun Beach. Teams of 4, double elimination bracket. Cash prizes for top 3 teams. Registration includes tournament t-shirt and post-tournament BBQ.",
  short_description: "Annual beach volleyball tournament with cash prizes",
  venue_name: "Gun Beach",
  venue_address: "Gun Beach Road",
  venue_city: "Tumon",
  starts_at: 14.days.ago.change(hour: 8, min: 0),
  ends_at: 14.days.ago.change(hour: 18, min: 0),
  doors_open_at: 14.days.ago.change(hour: 7, min: 30),
  status: :completed,
  published_at: 30.days.ago,
  category: :sports,
  age_restriction: :all_ages,
  max_capacity: 200,
  is_featured: false,
  cover_image_url: "https://images.unsplash.com/photo-1612872087720-bb876e2e67d1?w=1200"
)

puts "  Created #{Event.count} events (#{Event.published.count} published, #{Event.where(status: :draft).count} draft, #{Event.where(status: :completed).count} completed)."

# --- Ticket Types ---

# Event 1: Full Moon Beach Party
tt1_ga = TicketType.create!(event: event1, name: "General Admission", description: "Access to the beach party, one welcome drink included", price_cents: 2500, quantity_available: 400, max_per_order: 8, sort_order: 0)
tt1_vip = TicketType.create!(event: event1, name: "VIP", description: "VIP lounge access, 3 premium cocktails, priority entry, and exclusive meet & greet", price_cents: 7500, quantity_available: 80, max_per_order: 4, sort_order: 1)
tt1_table = TicketType.create!(event: event1, name: "VIP Table (4 guests)", description: "Reserved VIP table for 4, bottle service, dedicated server all night", price_cents: 30000, quantity_available: 20, max_per_order: 2, sort_order: 2)

# Event 2: Neon Nights
tt2_ga = TicketType.create!(event: event2, name: "General Admission", description: "Entry with one free glow accessory", price_cents: 2000, quantity_available: 250, max_per_order: 6, sort_order: 0)
tt2_glow = TicketType.create!(event: event2, name: "Glow VIP", description: "Premium glow kit, VIP area access, 2 drinks included", price_cents: 5000, quantity_available: 50, max_per_order: 4, sort_order: 1)

# Event 3: Sunset Sessions
tt3_ga = TicketType.create!(event: event3, name: "General Admission", description: "Lawn seating with access to food trucks and beer garden", price_cents: 3500, quantity_available: 700, max_per_order: 10, sort_order: 0)
tt3_vip = TicketType.create!(event: event3, name: "VIP Front Row", description: "Reserved front-row seating, backstage access, complimentary drinks", price_cents: 10000, quantity_available: 100, max_per_order: 6, sort_order: 1)
tt3_family = TicketType.create!(event: event3, name: "Family Pack (4)", description: "4 general admission tickets + kids activity area access", price_cents: 10000, quantity_available: 100, max_per_order: 4, sort_order: 2)

# Event 4: Taste of Guam
tt4_ga = TicketType.create!(event: event4, name: "General Entry", description: "Festival entry with 5 food tasting tokens", price_cents: 1500, quantity_available: 1500, max_per_order: 10, sort_order: 0)
tt4_foodie = TicketType.create!(event: event4, name: "Foodie Pass", description: "Festival entry with 15 tasting tokens and exclusive chef demo access", price_cents: 4500, quantity_available: 300, max_per_order: 6, sort_order: 1)
tt4_vip = TicketType.create!(event: event4, name: "VIP Experience", description: "All-you-can-taste, private chef dinner, front-row seats for cooking demos", price_cents: 12000, quantity_available: 50, max_per_order: 4, sort_order: 2)

# Event 5: NYE (draft, won't have sales yet)
TicketType.create!(event: event5, name: "Early Bird", description: "Limited early bird pricing - open bar and champagne toast", price_cents: 15000, quantity_available: 50, max_per_order: 4, sort_order: 0)
TicketType.create!(event: event5, name: "General Admission", description: "Open bar, champagne toast at midnight", price_cents: 20000, quantity_available: 120, max_per_order: 6, sort_order: 1)
TicketType.create!(event: event5, name: "Platinum Table (6)", description: "Premium rooftop table for 6, dedicated server, premium spirits", price_cents: 100000, quantity_available: 10, max_per_order: 1, sort_order: 2)

# Event 6: Beach Volleyball (past, had sales)
tt6_team = TicketType.create!(event: event6, name: "Team Registration (4 players)", description: "Full team registration including t-shirts and BBQ", price_cents: 8000, quantity_available: 32, max_per_order: 1, sort_order: 0)
tt6_spectator = TicketType.create!(event: event6, name: "Spectator", description: "Free spectator entry with access to BBQ area", price_cents: 0, quantity_available: 150, max_per_order: 10, sort_order: 1)

puts "  Created #{TicketType.count} ticket types across #{Event.count} events."

# --- Orders and Tickets (for published/completed events) ---

# Helper to calculate fees like the OrdersController does
def create_order_with_tickets(event:, buyer_name:, buyer_email:, buyer_phone: nil, user: nil, line_items:, checked_in_tickets: [])
  subtotal = 0
  total_ticket_count = 0

  line_items.each do |item|
    ticket_type = item[:ticket_type]
    quantity = item[:quantity]
    subtotal += ticket_type.price_cents * quantity
    total_ticket_count += quantity
  end

  service_fee = subtotal > 0 ? (subtotal * 0.03).round + (total_ticket_count * 50) : 0
  total = subtotal + service_fee

  order = Order.create!(
    event: event,
    user: user,
    buyer_name: buyer_name,
    buyer_email: buyer_email,
    buyer_phone: buyer_phone,
    subtotal_cents: subtotal,
    service_fee_cents: service_fee,
    total_cents: total,
    status: :completed,
    completed_at: rand(1..14).days.ago
  )

  ticket_index = 0
  line_items.each do |item|
    ticket_type = item[:ticket_type]
    quantity = item[:quantity]

    quantity.times do
      ticket = Ticket.create!(
        order: order,
        ticket_type: ticket_type,
        event: event,
        attendee_name: buyer_name,
        attendee_email: buyer_email
      )

      # Update quantity_sold
      ticket_type.increment!(:quantity_sold)

      # Check in specific tickets
      if checked_in_tickets.include?(ticket_index)
        ticket.check_in!
      end
      ticket_index += 1
    end
  end

  order
end

# Orders for Event 1: Full Moon Beach Party
create_order_with_tickets(
  event: event1, user: attendee1,
  buyer_name: "Jake Miller", buyer_email: "jake.miller@navy.mil", buyer_phone: "+1-671-555-0301",
  line_items: [{ ticket_type: tt1_ga, quantity: 3 }]
)

create_order_with_tickets(
  event: event1, user: attendee2,
  buyer_name: "Sarah Tanaka", buyer_email: "sarah.tanaka@gmail.com",
  line_items: [{ ticket_type: tt1_vip, quantity: 2 }]
)

create_order_with_tickets(
  event: event1,
  buyer_name: "Tom Rodriguez", buyer_email: "tom.rod@gmail.com",
  line_items: [{ ticket_type: tt1_ga, quantity: 2 }, { ticket_type: tt1_vip, quantity: 1 }]
)

# Orders for Event 3: Sunset Sessions
create_order_with_tickets(
  event: event3, user: attendee1,
  buyer_name: "Jake Miller", buyer_email: "jake.miller@navy.mil",
  line_items: [{ ticket_type: tt3_ga, quantity: 2 }]
)

create_order_with_tickets(
  event: event3, user: attendee3,
  buyer_name: "Mike Reyes", buyer_email: "mike.reyes@yahoo.com",
  line_items: [{ ticket_type: tt3_family, quantity: 1 }]
)

create_order_with_tickets(
  event: event3,
  buyer_name: "Linda Park", buyer_email: "linda.park@hotmail.com",
  line_items: [{ ticket_type: tt3_vip, quantity: 2 }]
)

# Orders for Event 4: Taste of Guam
create_order_with_tickets(
  event: event4, user: attendee2,
  buyer_name: "Sarah Tanaka", buyer_email: "sarah.tanaka@gmail.com",
  line_items: [{ ticket_type: tt4_foodie, quantity: 2 }]
)

create_order_with_tickets(
  event: event4,
  buyer_name: "David Kim", buyer_email: "david.kim@outlook.com",
  line_items: [{ ticket_type: tt4_ga, quantity: 4 }]
)

# Orders for Event 6: Beach Volleyball (past event, with check-ins)
create_order_with_tickets(
  event: event6, user: attendee3,
  buyer_name: "Mike Reyes", buyer_email: "mike.reyes@yahoo.com",
  line_items: [{ ticket_type: tt6_team, quantity: 1 }],
  checked_in_tickets: [0]
)

create_order_with_tickets(
  event: event6,
  buyer_name: "Team Chamorro Fire", buyer_email: "chamorro.fire@gmail.com",
  line_items: [{ ticket_type: tt6_team, quantity: 1 }],
  checked_in_tickets: [0]
)

create_order_with_tickets(
  event: event6, user: attendee1,
  buyer_name: "Jake Miller", buyer_email: "jake.miller@navy.mil",
  line_items: [{ ticket_type: tt6_spectator, quantity: 3 }],
  checked_in_tickets: [0, 1]
)

puts "  Created #{Order.count} orders with #{Ticket.count} tickets (#{Ticket.where(status: :checked_in).count} checked in)."

# --- Summary ---
puts ""
puts "=== Seed Data Summary ==="
puts "  Users:             #{User.count}"
puts "  Organizer Profiles: #{OrganizerProfile.count}"
puts "  Events:            #{Event.count} (#{Event.published.count} published, #{Event.where(status: :draft).count} draft, #{Event.where(status: :completed).count} completed)"
puts "  Ticket Types:      #{TicketType.count}"
puts "  Orders:            #{Order.count}"
puts "  Tickets:           #{Ticket.count} (#{Ticket.where(status: :issued).count} issued, #{Ticket.where(status: :checked_in).count} checked in)"
puts ""
puts "Published events available at: GET /api/v1/events"
puts "Seeding complete!"
