# HafaPass - Seed Data
# Based on real Guam events and venues for realistic demonstration
#
# Usage: rails db:seed
# To reset: rails db:reset (drops, creates, migrates, seeds)

puts "Seeding HafaPass with real Guam event data..."

# Clear existing data in correct order (respecting foreign keys)
Ticket.destroy_all
Order.destroy_all
TicketType.destroy_all
Event.destroy_all
OrganizerProfile.destroy_all
User.destroy_all

puts "  Cleared existing data."

# --- Platform Admin ---
admin_user = User.create!(
  clerk_id: "clerk_admin_leon",
  email: "shimizutechnology@gmail.com",
  first_name: "Leon",
  last_name: "Shimizu",
  phone: "+1-671-555-0001",
  role: :admin
)

# --- Organizers (inspired by real Guam event promoters) ---
org_guamtime = User.create!(
  clerk_id: "clerk_org_guamtime",
  email: "events@guamtime.net",
  first_name: "Tony",
  last_name: "Ada",
  phone: "+1-671-888-0101",
  role: :organizer
)

org_bwtc = User.create!(
  clerk_id: "clerk_org_bwtc",
  email: "info@bwtcguam.com",
  first_name: "Ashley",
  last_name: "Cruz",
  phone: "+1-671-888-0202",
  role: :organizer
)

org_heritage = User.create!(
  clerk_id: "clerk_org_heritage",
  email: "cultural@guamheritage.org",
  first_name: "Carmen",
  last_name: "Taitano",
  phone: "+1-671-888-0303",
  role: :organizer
)

org_nightlife = User.create!(
  clerk_id: "clerk_org_nightlife",
  email: "bookings@islandnightsgu.com",
  first_name: "Carlos",
  last_name: "Santos",
  phone: "+1-671-888-0404",
  role: :organizer
)

org_sports = User.create!(
  clerk_id: "clerk_org_sports",
  email: "events@guambasketball.com",
  first_name: "John",
  last_name: "Quinata",
  phone: "+1-671-888-0505",
  role: :organizer
)

# --- Attendees ---
attendee1 = User.create!(
  clerk_id: "clerk_att_jake",
  email: "jake.miller@navy.mil",
  first_name: "Jake",
  last_name: "Miller",
  phone: "+1-671-555-0301",
  role: :attendee
)

attendee2 = User.create!(
  clerk_id: "clerk_att_sarah",
  email: "sarah.tanaka@gmail.com",
  first_name: "Sarah",
  last_name: "Tanaka",
  phone: "+1-671-555-0302",
  role: :attendee
)

attendee3 = User.create!(
  clerk_id: "clerk_att_mike",
  email: "mike.reyes@yahoo.com",
  first_name: "Mike",
  last_name: "Reyes",
  phone: "+1-671-555-0303",
  role: :attendee
)

attendee4 = User.create!(
  clerk_id: "clerk_att_maria",
  email: "maria.pangelinan@gmail.com",
  first_name: "Maria",
  last_name: "Pangelinan",
  phone: "+1-671-555-0304",
  role: :attendee
)

puts "  Created #{User.count} users (1 admin, #{User.where(role: :organizer).count} organizers, #{User.where(role: :attendee).count} attendees)."

# --- Organizer Profiles ---
profile_guamtime = OrganizerProfile.create!(
  user: org_guamtime,
  business_name: "GuamTime Events",
  business_description: "Guam's premier event promotion and ticketing platform. We bring the best concerts, festivals, and experiences to the island.",
  is_ambros_partner: true
)

profile_bwtc = OrganizerProfile.create!(
  user: org_bwtc,
  business_name: "Breaking Wave Theatre Company",
  business_description: "Guam's community theatre company dedicated to storytelling, creative arts, and bringing unique performance experiences to the island.",
  is_ambros_partner: false
)

profile_heritage = OrganizerProfile.create!(
  user: org_heritage,
  business_name: "Humåtak Heritage Foundation",
  business_description: "Preserving and celebrating CHamoru heritage through annual festivals, cultural events, and community gatherings in the historic village of Umatac.",
  is_ambros_partner: true
)

profile_nightlife = OrganizerProfile.create!(
  user: org_nightlife,
  business_name: "Island Nights Promotions",
  business_description: "Guam's hottest nightlife events — beach parties, DJ nights, and premium club experiences across the island.",
  is_ambros_partner: true
)

profile_sports = OrganizerProfile.create!(
  user: org_sports,
  business_name: "Guam Basketball Confederation",
  business_description: "Official organizing body for basketball events on Guam, including FIBA World Cup qualifiers and local tournaments.",
  is_ambros_partner: false
)

puts "  Created #{OrganizerProfile.count} organizer profiles."

# --- Events (based on real Guam events) ---

# Event 1: Hafaloha Concert Series — J Boog (FEATURED, upcoming)
event1 = Event.create!(
  organizer_profile: profile_guamtime,
  title: "Hafaloha Concert Series Part 5: featuring J Boog",
  description: "The Hafaloha Concert Series returns with Part 5, headlined by island reggae superstar J Boog! Known for hits like 'Let's Do It Again' and 'Sunshine Girl,' J Boog brings his signature sound to Guam for an unforgettable evening under the stars at Ypao Beach Park. Local opening acts, food trucks, craft beer garden, and good vibes all night long. This is THE concert event of the spring — don't miss it!",
  short_description: "Island reggae superstar J Boog live at Ypao Beach Park with local opening acts and food trucks",
  venue_name: "Ypao Beach Park",
  venue_address: "Ypao Road",
  venue_city: "Tumon",
  starts_at: 14.days.from_now.change(hour: 17, min: 0),
  ends_at: 14.days.from_now.change(hour: 23, min: 0),
  doors_open_at: 14.days.from_now.change(hour: 16, min: 0),
  status: :published,
  published_at: 7.days.ago,
  category: :concert,
  age_restriction: :all_ages,
  max_capacity: 3000,
  is_featured: true,
  cover_image_url: "https://sc-events.s3.amazonaws.com/32856/10244887/a91b1e92e03f19017094d73739facdd6a15c1e9b35259a7ddd1665a4f13c7493/922f43db-8352-410e-a057-dd943d6c54ae.png"
)

# Event 2: Humåtak CHamoru Heritage Festival (FEATURED, upcoming)
event2 = Event.create!(
  organizer_profile: profile_heritage,
  title: "Humåtak Guam History & CHamoru Heritage Day Festival 2026",
  description: "Celebrate Culture at the 2026 Humåtak Guam History & CHamoru Heritage Day Festival! Located in the historic village of Umatac, this four-day celebration honors the island's indigenous roots. Explore historical landmarks around Umatac Bay, see displays of local craftsmanship including weaving and carving inspired by the ancient Latte Stone culture, enjoy authentic island cuisine, and experience live entertainment that captures the spirit of the Mariana Islands. A family-friendly event perfect for those interested in Guam history and community celebrations.",
  short_description: "Four-day cultural celebration in historic Umatac honoring CHamoru heritage with food, music, and traditional crafts",
  venue_name: "Umatac Festival Grounds",
  venue_address: "Marine Corps Drive",
  venue_city: "Umatac",
  starts_at: 7.days.from_now.change(hour: 18, min: 0),
  ends_at: 10.days.from_now.change(hour: 0, min: 0),
  doors_open_at: 7.days.from_now.change(hour: 17, min: 30),
  status: :published,
  published_at: 14.days.ago,
  category: :festival,
  age_restriction: :all_ages,
  max_capacity: 5000,
  is_featured: true,
  cover_image_url: "https://guam.stripes.com/travel/cc6jnj-chamoru-heritage.jpg/alternates/LANDSCAPE_910/Chamoru-Heritage.jpg"
)

# Event 3: FIBA World Cup Qualifiers (upcoming)
event3 = Event.create!(
  organizer_profile: profile_sports,
  title: "FIBA World Cup Qualifiers: Guam vs Australia",
  description: "Team Guam takes on Australia in FIBA Basketball World Cup 2027 Asian Qualifiers at the UOG Calvo Field House! Come support our island warriors as they compete on the world stage. The energy in the Field House is electric — this is Guam basketball at its finest. Food vendors outside, team merchandise available, and the loudest crowd in the Pacific!",
  short_description: "Team Guam faces Australia in FIBA World Cup qualifying action at UOG Calvo Field House",
  venue_name: "UOG Calvo Field House",
  venue_address: "University of Guam",
  venue_city: "Mangilao",
  starts_at: 6.days.from_now.change(hour: 19, min: 0),
  ends_at: 6.days.from_now.change(hour: 22, min: 0),
  doors_open_at: 6.days.from_now.change(hour: 17, min: 30),
  status: :published,
  published_at: 10.days.ago,
  category: :sports,
  age_restriction: :all_ages,
  max_capacity: 2500,
  is_featured: false,
  cover_image_url: "https://sc-events.s3.amazonaws.com/33143/10261224/dce11f39df6197871f2b01f5149c18b6f5c92ec1f53ca3b01d441bd3067c1c50/8625e216-218d-4e9c-ad0e-dcd0a7dfe462.png"
)

# Event 4: Scraps 6 — MMA/Boxing (upcoming)
event4 = Event.create!(
  organizer_profile: profile_guamtime,
  title: "Scraps 6: Island Throwdown",
  description: "Scraps is back for round 6! Guam's premier amateur MMA and boxing event returns to the Dusit Thani Resort with a stacked fight card featuring the island's toughest competitors. Full bar, ringside seating available, and an after-party to follow. This is the fight night Guam has been waiting for!",
  short_description: "Amateur MMA and boxing event with a stacked fight card at Dusit Thani Resort",
  venue_name: "Dusit Thani Guam Resort",
  venue_address: "1227 Pale San Vitores Road",
  venue_city: "Tumon",
  starts_at: 28.days.from_now.change(hour: 19, min: 0),
  ends_at: 28.days.from_now.change(hour: 23, min: 30),
  doors_open_at: 28.days.from_now.change(hour: 18, min: 0),
  status: :published,
  published_at: 5.days.ago,
  category: :sports,
  age_restriction: :eighteen_plus,
  max_capacity: 800,
  is_featured: false,
  cover_image_url: "https://sc-events.s3.amazonaws.com/32896/10297726/34647bbd177ac93cb8816747536ae8be36125d2d0f531d76e385422f99a06d5b/efe69b3b-94a1-4e9f-90a3-cc4b320e9e07.jpeg"
)

# Event 5: Tides of Fantasy — Renaissance Faire (this weekend, almost sold out)
event5 = Event.create!(
  organizer_profile: profile_bwtc,
  title: "Tides of Fantasy: A Renaissance Faire & Live Tabletop Adventure",
  description: "Step into a world where imagination meets island storytelling! Tides of Fantasy is Guam's first Renaissance Faire, bringing classic medieval fantasy to life while weaving in oceanic imagery and island-rooted creativity. Saturday night features a Live Tabletop Roleplaying Adventure show. Sunday, wander the Renaissance Faire — themed vendors, medieval performances, interactive games, costume contests, and workshops. Dress in your finest fantasy, Renaissance, or island-inspired attire!",
  short_description: "Guam's first Renaissance Faire with live tabletop RPG show, themed vendors, and performances",
  venue_name: "Holiday Resort & Spa Guam",
  venue_address: "946 Pale San Vitores Road",
  venue_city: "Tumon",
  starts_at: 1.day.from_now.change(hour: 18, min: 30),
  ends_at: 2.days.from_now.change(hour: 19, min: 0),
  doors_open_at: 1.day.from_now.change(hour: 18, min: 0),
  status: :published,
  published_at: 21.days.ago,
  category: :festival,
  age_restriction: :all_ages,
  max_capacity: 500,
  is_featured: true,
  cover_image_url: "https://sc-events.s3.amazonaws.com/32904/10262262/9b4292ea3f5f5f96a8393de382bd097501febd126364a1e57d238c4df4a10a33/2f8b7ba3-2973-487e-a3fb-523574b915e6.jpg"
)

# Event 6: Full Moon Beach Party (nightlife, upcoming)
event6 = Event.create!(
  organizer_profile: profile_nightlife,
  title: "Full Moon Beach Party: March Edition",
  description: "Dance under the full moon at Tumon Bay! Featuring DJ Kiko spinning tropical house, live fire dancers, and island cocktail specials all night long. The ultimate beach party experience on Guam. Full bar, glow accessories at the door, and the best sunset-to-moonrise views on the island.",
  short_description: "Full moon beach party with DJ Kiko, fire dancers, and island cocktail specials at Tumon Bay",
  venue_name: "Tumon Bay Beach",
  venue_address: "1255 Pale San Vitores Road",
  venue_city: "Tumon",
  starts_at: 10.days.from_now.change(hour: 21, min: 0),
  ends_at: 10.days.from_now.change(hour: 2, min: 0) + 1.day,
  doors_open_at: 10.days.from_now.change(hour: 20, min: 30),
  status: :published,
  published_at: 3.days.ago,
  category: :nightlife,
  age_restriction: :twenty_one_plus,
  max_capacity: 500,
  is_featured: false,
  cover_image_url: "https://images.unsplash.com/photo-1519671482749-fd09be7ccebf?w=1200"
)

# Event 7: Safe Haven Gala (upcoming, formal)
event7 = Event.create!(
  organizer_profile: profile_guamtime,
  title: "Safe Haven Gala 2026",
  description: "An elegant evening supporting Guam's Safe Haven foundation. Join us at the beautiful Dusit Thani Resort for a night of fine dining, live entertainment, silent auction, and community spirit. Black tie optional. All proceeds support programs for women and children in need on Guam.",
  short_description: "Formal gala benefiting Safe Haven foundation with fine dining, live entertainment, and silent auction",
  venue_name: "Dusit Thani Guam Resort",
  venue_address: "1227 Pale San Vitores Road",
  venue_city: "Tumon",
  starts_at: 63.days.from_now.change(hour: 18, min: 0),
  ends_at: 63.days.from_now.change(hour: 23, min: 0),
  doors_open_at: 63.days.from_now.change(hour: 17, min: 30),
  status: :published,
  published_at: 1.day.ago,
  category: :other,
  age_restriction: :twenty_one_plus,
  max_capacity: 300,
  is_featured: false,
  cover_image_url: "https://sc-events.s3.amazonaws.com/32933/10282525/d33db73fe173b9d2c35e61e12034392763972cd02229320a3655ba729ceca3ef/87eec079-2e26-4514-8e94-520ccbc7edb6.png"
)

# Event 8: The Mad Collab Block Party (upcoming, community)
event8 = Event.create!(
  organizer_profile: profile_guamtime,
  title: "The Mad Collab: Block Party 2026",
  description: "The Mad Collab returns with the biggest block party of the year! Local artists, live music, food vendors, art installations, custom merch drops, and the best vibes on the island. This is where Guam's creative community comes together — DJs, painters, dancers, photographers, and everyone in between. Free entry, pay-as-you-go for food and drinks.",
  short_description: "Guam's biggest creative block party with local artists, live music, food vendors, and art installations",
  venue_name: "Tumon Night Market",
  venue_address: "Pale San Vitores Road",
  venue_city: "Tumon",
  starts_at: 72.days.from_now.change(hour: 16, min: 0),
  ends_at: 72.days.from_now.change(hour: 23, min: 0),
  doors_open_at: 72.days.from_now.change(hour: 15, min: 30),
  status: :published,
  published_at: 2.days.ago,
  category: :festival,
  age_restriction: :all_ages,
  max_capacity: 2000,
  is_featured: false,
  cover_image_url: "https://sc-events.s3.amazonaws.com/32988/10260840/0ebf50cf2ea18ef783b2de31b4016fe834af186aeb4e845a79f362240ad27615/8a50fb54-beda-4a99-aadf-a54da1ff165f.png"
)

# Event 9: Neon Nights UV Glow Party (nightlife)
event9 = Event.create!(
  organizer_profile: profile_nightlife,
  title: "Neon Nights: UV Glow Party",
  description: "Get your glow on at Guam's biggest UV party! Body paint stations, neon decorations, and the best EDM DJs from across the Pacific. Wear white for maximum glow effect! Glow accessories included with entry. VIP section with bottle service available.",
  short_description: "UV glow party with body paint stations, EDM DJs, and neon decorations",
  venue_name: "Globe Nightclub",
  venue_address: "199 Chalan San Antonio",
  venue_city: "Tamuning",
  starts_at: 21.days.from_now.change(hour: 22, min: 0),
  ends_at: 21.days.from_now.change(hour: 3, min: 0) + 1.day,
  doors_open_at: 21.days.from_now.change(hour: 21, min: 30),
  status: :published,
  published_at: 1.day.ago,
  category: :nightlife,
  age_restriction: :eighteen_plus,
  max_capacity: 300,
  is_featured: false,
  cover_image_url: "https://images.unsplash.com/photo-1574391884720-bbc3740c59d1?w=1200"
)

# Event 10: Draft event (organizer hasn't published yet)
event10 = Event.create!(
  organizer_profile: profile_nightlife,
  title: "Summer Kickoff Party 2026",
  description: "The biggest party of the summer! Details coming soon...",
  short_description: "Summer kickoff party — details TBA",
  venue_name: "TBA",
  venue_city: "Tumon",
  starts_at: 90.days.from_now.change(hour: 20, min: 0),
  ends_at: 90.days.from_now.change(hour: 2, min: 0) + 1.day,
  status: :draft,
  category: :nightlife,
  age_restriction: :twenty_one_plus,
  max_capacity: 1000,
  is_featured: false
)

puts "  Created #{Event.count} events (#{Event.published.count} published, #{Event.where(status: :draft).count} draft)."

# --- Ticket Types ---

# J Boog Concert
tt1_ga = TicketType.create!(event: event1, name: "General Admission", description: "Lawn access with food trucks and beer garden", price_cents: 4500, quantity_available: 2000, max_per_order: 8, sort_order: 0)
tt1_vip = TicketType.create!(event: event1, name: "VIP Front Row", description: "Reserved front section, backstage meet & greet, 2 complimentary drinks", price_cents: 12000, quantity_available: 200, max_per_order: 4, sort_order: 1)
tt1_table = TicketType.create!(event: event1, name: "VIP Table (6 guests)", description: "Reserved table for 6, bottle service, priority entry, dedicated server", price_cents: 50000, quantity_available: 20, max_per_order: 2, sort_order: 2)

# Humåtak Heritage Festival
tt2_free = TicketType.create!(event: event2, name: "General Entry", description: "Free entry to all festival grounds and performances", price_cents: 0, quantity_available: 5000, max_per_order: 10, sort_order: 0)
tt2_vip = TicketType.create!(event: event2, name: "Cultural VIP Experience", description: "VIP seating for performances, exclusive crafting workshop, traditional lunch included", price_cents: 3500, quantity_available: 100, max_per_order: 6, sort_order: 1)

# FIBA Qualifiers
tt3_ga = TicketType.create!(event: event3, name: "General Admission", description: "Upper bowl seating", price_cents: 2500, quantity_available: 1500, max_per_order: 8, sort_order: 0)
tt3_court = TicketType.create!(event: event3, name: "Courtside", description: "Floor-level seating, closest to the action", price_cents: 7500, quantity_available: 100, max_per_order: 4, sort_order: 1)
tt3_vip = TicketType.create!(event: event3, name: "VIP Suite", description: "Private suite with catering, air conditioning, and premium views", price_cents: 15000, quantity_available: 20, max_per_order: 2, sort_order: 2)

# Scraps 6
tt4_ga = TicketType.create!(event: event4, name: "General Admission", description: "Standing room and general seating", price_cents: 3500, quantity_available: 500, max_per_order: 6, sort_order: 0)
tt4_ring = TicketType.create!(event: event4, name: "Ringside", description: "Front row seats next to the ring", price_cents: 8000, quantity_available: 80, max_per_order: 4, sort_order: 1)
tt4_vip = TicketType.create!(event: event4, name: "VIP Table (4 guests)", description: "Reserved table for 4 with bottle service and ringside view", price_cents: 25000, quantity_available: 15, max_per_order: 2, sort_order: 2)

# Tides of Fantasy
tt5_faire = TicketType.create!(event: event5, name: "Village Faire Pass", description: "Sunday Faire access only — vendors, performances, games", price_cents: 2000, quantity_available: 300, max_per_order: 6, sort_order: 0)
tt5_show = TicketType.create!(event: event5, name: "Adventurer Pass", description: "Saturday Live Tabletop Show only", price_cents: 2000, quantity_available: 150, max_per_order: 4, sort_order: 1)
tt5_explorer = TicketType.create!(event: event5, name: "Explorer Pass", description: "2-Day Pass — includes both the Show and the Faire", price_cents: 3000, quantity_available: 200, max_per_order: 4, sort_order: 2)
tt5_noble = TicketType.create!(event: event5, name: "Noble Council VIP", description: "Sunday Faire + VIP lounge with appetizers + priority entry", price_cents: 7500, quantity_available: 30, max_per_order: 2, sort_order: 3)
tt5_royal = TicketType.create!(event: event5, name: "Royal Court VIP", description: "2-Day VIP — VIP seating for Show + all Noble Council perks", price_cents: 10000, quantity_available: 15, max_per_order: 2, sort_order: 4)

# Full Moon Beach Party
tt6_ga = TicketType.create!(event: event6, name: "General Admission", description: "Beach access, one welcome drink included", price_cents: 2500, quantity_available: 400, max_per_order: 8, sort_order: 0)
tt6_vip = TicketType.create!(event: event6, name: "VIP", description: "VIP lounge, 3 premium cocktails, priority entry", price_cents: 7500, quantity_available: 80, max_per_order: 4, sort_order: 1)

# Safe Haven Gala
tt7_seat = TicketType.create!(event: event7, name: "Individual Seat", description: "Dinner, entertainment, and one drink ticket", price_cents: 15000, quantity_available: 200, max_per_order: 6, sort_order: 0)
tt7_table = TicketType.create!(event: event7, name: "Table of 10", description: "Reserved table for 10 guests, premium wine service, event program recognition", price_cents: 125000, quantity_available: 15, max_per_order: 2, sort_order: 1)

# Mad Collab Block Party
tt8_free = TicketType.create!(event: event8, name: "Free Entry", description: "General entry — food and drinks pay-as-you-go", price_cents: 0, quantity_available: 2000, max_per_order: 10, sort_order: 0)

# Neon Nights
tt9_ga = TicketType.create!(event: event9, name: "General Admission", description: "Entry with one free glow accessory", price_cents: 2000, quantity_available: 250, max_per_order: 6, sort_order: 0)
tt9_vip = TicketType.create!(event: event9, name: "Glow VIP", description: "Premium glow kit, VIP area, 2 drinks included", price_cents: 5000, quantity_available: 50, max_per_order: 4, sort_order: 1)

puts "  Created #{TicketType.count} ticket types across #{Event.count} events."

# --- Orders and Tickets ---

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

      ticket_type.increment!(:quantity_sold)

      if checked_in_tickets.include?(ticket_index)
        ticket.check_in!
      end
      ticket_index += 1
    end
  end

  order
end

# J Boog Concert orders
create_order_with_tickets(event: event1, user: attendee1, buyer_name: "Jake Miller", buyer_email: "jake.miller@navy.mil", line_items: [{ ticket_type: tt1_ga, quantity: 4 }])
create_order_with_tickets(event: event1, user: attendee2, buyer_name: "Sarah Tanaka", buyer_email: "sarah.tanaka@gmail.com", line_items: [{ ticket_type: tt1_vip, quantity: 2 }])
create_order_with_tickets(event: event1, buyer_name: "Tom Rodriguez", buyer_email: "tom.rod@gmail.com", line_items: [{ ticket_type: tt1_ga, quantity: 2 }, { ticket_type: tt1_vip, quantity: 1 }])
create_order_with_tickets(event: event1, buyer_name: "Lisa Park", buyer_email: "lisa.park@hotmail.com", line_items: [{ ticket_type: tt1_table, quantity: 1 }])
15.times do |i|
  create_order_with_tickets(event: event1, buyer_name: "Guest #{i+1}", buyer_email: "guest#{i+1}@example.com", line_items: [{ ticket_type: tt1_ga, quantity: rand(1..4) }])
end

# Heritage Festival orders
create_order_with_tickets(event: event2, user: attendee3, buyer_name: "Mike Reyes", buyer_email: "mike.reyes@yahoo.com", line_items: [{ ticket_type: tt2_free, quantity: 4 }])
create_order_with_tickets(event: event2, user: attendee4, buyer_name: "Maria Pangelinan", buyer_email: "maria.pangelinan@gmail.com", line_items: [{ ticket_type: tt2_vip, quantity: 2 }])
10.times do |i|
  create_order_with_tickets(event: event2, buyer_name: "Family #{i+1}", buyer_email: "family#{i+1}@example.com", line_items: [{ ticket_type: tt2_free, quantity: rand(2..6) }])
end

# FIBA orders
create_order_with_tickets(event: event3, user: attendee1, buyer_name: "Jake Miller", buyer_email: "jake.miller@navy.mil", line_items: [{ ticket_type: tt3_ga, quantity: 2 }])
create_order_with_tickets(event: event3, user: attendee3, buyer_name: "Mike Reyes", buyer_email: "mike.reyes@yahoo.com", line_items: [{ ticket_type: tt3_court, quantity: 4 }])
8.times do |i|
  create_order_with_tickets(event: event3, buyer_name: "Fan #{i+1}", buyer_email: "fan#{i+1}@example.com", line_items: [{ ticket_type: tt3_ga, quantity: rand(1..4) }])
end

# Tides of Fantasy orders (almost sold out!)
create_order_with_tickets(event: event5, user: attendee2, buyer_name: "Sarah Tanaka", buyer_email: "sarah.tanaka@gmail.com", line_items: [{ ticket_type: tt5_explorer, quantity: 2 }])
create_order_with_tickets(event: event5, user: attendee4, buyer_name: "Maria Pangelinan", buyer_email: "maria.pangelinan@gmail.com", line_items: [{ ticket_type: tt5_royal, quantity: 2 }])
20.times do |i|
  create_order_with_tickets(event: event5, buyer_name: "Adventurer #{i+1}", buyer_email: "adventurer#{i+1}@example.com", line_items: [{ ticket_type: [tt5_faire, tt5_show, tt5_explorer].sample, quantity: rand(1..3) }])
end

# Full Moon Beach Party orders
create_order_with_tickets(event: event6, user: attendee1, buyer_name: "Jake Miller", buyer_email: "jake.miller@navy.mil", line_items: [{ ticket_type: tt6_ga, quantity: 3 }])
5.times do |i|
  create_order_with_tickets(event: event6, buyer_name: "Partygoer #{i+1}", buyer_email: "party#{i+1}@example.com", line_items: [{ ticket_type: tt6_ga, quantity: rand(1..4) }])
end

# Neon Nights orders
create_order_with_tickets(event: event9, user: attendee2, buyer_name: "Sarah Tanaka", buyer_email: "sarah.tanaka@gmail.com", line_items: [{ ticket_type: tt9_vip, quantity: 2 }])
3.times do |i|
  create_order_with_tickets(event: event9, buyer_name: "Raver #{i+1}", buyer_email: "raver#{i+1}@example.com", line_items: [{ ticket_type: tt9_ga, quantity: rand(1..3) }])
end

puts "  Created #{Order.count} orders with #{Ticket.count} tickets (#{Ticket.where(status: :checked_in).count} checked in)."

# --- Summary ---
puts ""
puts "=== Seed Data Summary ==="
puts "  Users:              #{User.count} (#{User.where(role: :admin).count} admin, #{User.where(role: :organizer).count} organizers, #{User.where(role: :attendee).count} attendees)"
puts "  Organizer Profiles: #{OrganizerProfile.count}"
puts "  Events:             #{Event.count} (#{Event.published.count} published, #{Event.where(status: :draft).count} draft)"
puts "  Ticket Types:       #{TicketType.count}"
puts "  Orders:             #{Order.count}"
puts "  Tickets:            #{Ticket.count} (#{Ticket.where(status: :issued).count} issued, #{Ticket.where(status: :checked_in).count} checked in)"
puts ""
puts "Featured events: #{Event.featured.count}"
puts "Published events available at: GET /api/v1/events"
puts "Seeding complete! 🎫"
