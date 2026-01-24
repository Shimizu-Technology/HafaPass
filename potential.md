# 🎟️ **HafaPass — Guam's Hospitality Ticketing Platform**

## 🧠 **Product Vision**

Build the **ticketing platform for Guam's hospitality industry** — powered by Ambros Inc.'s island-wide venue network. Not another generic event platform, but **the ticketing solution that venues already trust** because it comes through their existing beverage distributor relationship.

**Core thesis:** Distribution beats features. While competitors cold-call organizers one at a time, we leverage Ambros's existing relationships with every bar, club, restaurant, and hotel on Guam.

---

## 📋 **Project Overview**

| Item | Detail |
|------|--------|
| **Project Name** | HafaPass |
| **Business Entity** | Shimizu Technology LLC |
| **Timeline** | 12 weeks to MVP |
| **Team** | Solo developer + interns + junior SWE |
| **First Customer** | Uncle Christian's events |
| **Target Partners** | Ambros Inc. (Carlos, Uncle Tom) |

---

## 🎯 **Who Is This For?**

### **Primary Users (Venues & Organizers)**

* Bars, clubs, and nightlife venues (weekly events, DJ nights, parties)
* Hotels and resorts (concerts, luaus, special events)
* Restaurants hosting ticketed experiences (wine dinners, chef events)
* Event promoters (Uncle Christian's Vegas-style events)
* Festival and concert organizers

### **Secondary Users (Attendees)**

* Military personnel (large, event-hungry population)
* Tourists (1.5M+ annually looking for things to do)
* Local residents

### **The Problem We're Solving**

**For Venues:**
* No easy way to sell tickets to their events
* Current options (GuamTime) require manual setup and take a large cut of profits
* No integration with their existing business relationships
* Limited tools for recurring events (weekly club nights)

**For Ambros:**
* Venues hosting more events = more beverage sales
* Sponsored events (Bud Light parties) need ticketing
* Opportunity to add value beyond just distribution

**For Attendees:**
* Fragmented event discovery
* Clunky mobile checkout experiences
* No central place for nightlife/hospitality events

---

## 🚀 **Core Differentiator: Distribution Through Ambros**

### **Why This Wins**

| Traditional Ticketing | HafaPass (Ambros-Powered) |
|-----------------------|---------------------------|
| Cold outreach to organizers | Warm intros through existing B2B relationships |
| Compete on features & price | Win on trust & convenience |
| One event at a time | Network effect through venue accounts |
| No beverage industry connection | Built-in sponsor integrations |

### **The Ambros Advantage**

Ambros Inc. already has relationships with **every venue on Guam** that serves alcohol:
* Regular sales visits and account management
* Delivery logistics already in place
* Trust built over 75+ years ("Generations Serving Micronesia")
* Brands that sponsor events (Bud Light, Patrón, Grey Goose, etc.)

**Our pitch to venues:**
> *"You already work with Ambros. Now they're offering a free/low-cost ticketing platform for their accounts. Want us to set you up?"*

That's not a sale. That's a value-add.

---

## 💰 **Pricing Model (Confirmed)**

### **Fee Structure**

| Fee Type | Amount | Paid By |
|----------|--------|---------|
| **Service Fee** | 3% + $0.50 per ticket | Added to ticket price (buyer pays) |
| **Payment Processing** | ~2.9% + $0.30 (Stripe) | Deducted from organizer payout |
| **Free Events** | $0 | No fees |

### **Example: $25 Ticket**

| Line Item | Amount |
|-----------|--------|
| Ticket Price | $25.00 |
| Service Fee (3% + $0.50) | $1.25 |
| **Buyer Pays** | **$26.25** |
| Stripe Fee (~2.9% + $0.30) | -$1.06 |
| **Organizer Receives** | **$23.94** |
| **HafaPass Revenue** | **$1.25** |

### **Why This Wins**

GuamTime reportedly takes "a bunch of the profits" (10-15%+). Our transparent 3% + $0.50 is a clear value proposition:

> *"Tired of losing 10-15% of your ticket sales? HafaPass charges just 3% + $0.50. Keep more of what you earn."*

### **Ambros Account Pricing**

* **Free or discounted** for Ambros venue accounts (drives adoption)
* Standard pricing for non-Ambros venues
* Premium tier for high-volume venues (Phase 2+)

---

## 🧩 **Product Principles**

1. **Venue-first, not event-first:** Build for recurring venue needs (weekly nights, ongoing series), not one-off concerts
2. **Mobile-native:** 75%+ of tickets sold via phone — checkout must be 3 taps or less
3. **Hospitality-optimized:** VIP tables, bottle service, group bookings, door lists
4. **Leverage the network:** Every feature should make the Ambros relationship more valuable

---

# 🧪 **MVP (Phase 1 — Launch)**

### **Goal:** Validate with Uncle Christian's events + 3-5 Ambros venue accounts

### **Timeline:** 12 Weeks

| Week | Focus | Assignable to Interns/Jr Dev |
|------|-------|------------------------------|
| 1-2 | Project setup, data models, auth (Clerk) | Basic React components |
| 3-4 | Event creation flow, image uploads | Event form UI, styling |
| 5-6 | Checkout flow, Stripe integration | Checkout UI components |
| 7-8 | Digital tickets, QR generation | Ticket display components |
| 9-10 | Scanner app, dashboard | Dashboard charts, tables |
| 11-12 | Testing, polish, mobile optimization | Testing, bug fixes |

### 🛠️ **Core Features**

**1. Instant Event Setup**
* Self-service event creation (live in under 10 minutes)
* No waiting for approval or manual setup
* Templates for common event types (club night, concert, private party)

**2. Mobile-First Checkout**
* 3-tap purchase flow
* Apple Pay / Google Pay / Credit Card (via Stripe)
* Digital tickets with QR codes
* Add to Apple Wallet / Google Wallet

**3. Door Management**
* Mobile scanner app for check-in
* Real-time attendee count
* Guest list management (promoter comps, VIP lists)

**4. Basic Organizer Dashboard**
* Sales overview (tickets sold, revenue, sell-through rate)
* Attendee list with contact info
* Simple promo codes

**5. Recurring Event Support**
* "Every Saturday" event templates
* Clone previous events with one click
* Series management (monthly wine dinners, weekly DJ nights)

### **Not in MVP (Intentionally)**
* Complex analytics
* Seat maps
* Multi-currency
* API/integrations
* Promoter revenue splits

---

# 🏗️ **Technical Specification**

## **Tech Stack (Confirmed)**

| Layer | Technology | Notes |
|-------|------------|-------|
| **Backend** | Ruby on Rails API | API-only mode |
| **Frontend** | React.js | Mobile-first, responsive |
| **Auth** | Clerk | Handles users, sessions, OAuth |
| **Database** | PostgreSQL (Neon for prod) | Local Postgres for dev |
| **Backend Hosting** | Render | Auto-deploy from GitHub |
| **Frontend Hosting** | Netlify | Auto-deploy from GitHub |
| **File Storage** | AWS S3 | Event images, ticket PDFs |
| **Payments** | Stripe | Checkout, Connect for payouts |
| **Email** | Resend | Transactional emails |
| **SMS** | ClickSend | Ticket confirmations |
| **QR Codes** | rqrcode gem + React scanner | Generate + scan |

---

## **Database Schema**

### **Entity Relationship Diagram (Conceptual)**

```
Users (Clerk-managed)
  │
  ├── Organizers (profile for event creators)
  │     └── Events
  │           ├── TicketTypes
  │           ├── PromoCodes
  │           └── Orders
  │                 └── Tickets
  │
  └── Attendees (ticket buyers)
        └── Orders
              └── Tickets
```

---

### **Tables & Fields**

#### **users**
Managed by Clerk, synced to local DB for associations.

| Column | Type | Notes |
|--------|------|-------|
| id | uuid | Primary key |
| clerk_id | string | Clerk user ID (unique) |
| email | string | From Clerk |
| first_name | string | From Clerk |
| last_name | string | From Clerk |
| phone | string | Optional |
| role | enum | `attendee`, `organizer`, `admin` |
| created_at | timestamp | |
| updated_at | timestamp | |

#### **organizer_profiles**
Extended profile for users who create events.

| Column | Type | Notes |
|--------|------|-------|
| id | uuid | Primary key |
| user_id | uuid | FK to users |
| business_name | string | Venue/promoter name |
| business_description | text | Optional |
| logo_url | string | S3 URL |
| stripe_account_id | string | Stripe Connect account |
| stripe_onboarding_complete | boolean | Can receive payouts |
| phone | string | Business phone |
| website | string | Optional |
| is_ambros_partner | boolean | Special pricing flag |
| created_at | timestamp | |
| updated_at | timestamp | |

#### **events**

| Column | Type | Notes |
|--------|------|-------|
| id | uuid | Primary key |
| organizer_profile_id | uuid | FK to organizer_profiles |
| title | string | Event name |
| slug | string | URL-friendly identifier |
| description | text | Rich text/markdown |
| short_description | string | For cards/previews |
| cover_image_url | string | S3 URL |
| venue_name | string | Location name |
| venue_address | string | Full address |
| venue_city | string | Default: Guam cities |
| latitude | decimal | For maps (optional) |
| longitude | decimal | For maps (optional) |
| starts_at | timestamp | Event start |
| ends_at | timestamp | Event end (optional) |
| doors_open_at | timestamp | When doors open |
| timezone | string | Default: Pacific/Guam |
| status | enum | `draft`, `published`, `cancelled`, `completed` |
| is_recurring | boolean | Part of a series |
| parent_event_id | uuid | FK to events (for recurring) |
| category | enum | `nightlife`, `concert`, `festival`, `dining`, `sports`, `other` |
| age_restriction | enum | `all_ages`, `18_plus`, `21_plus` |
| max_capacity | integer | Total venue capacity |
| is_featured | boolean | Homepage feature |
| published_at | timestamp | When made public |
| created_at | timestamp | |
| updated_at | timestamp | |

#### **ticket_types**

| Column | Type | Notes |
|--------|------|-------|
| id | uuid | Primary key |
| event_id | uuid | FK to events |
| name | string | e.g., "General Admission", "VIP" |
| description | text | What's included |
| price_cents | integer | Price in cents (e.g., 2500 = $25) |
| quantity_available | integer | Total tickets of this type |
| quantity_sold | integer | Counter, default 0 |
| max_per_order | integer | Limit per purchase |
| sales_start_at | timestamp | When tickets go on sale |
| sales_end_at | timestamp | When sales close |
| sort_order | integer | Display order |
| is_hidden | boolean | Hidden from public |
| created_at | timestamp | |
| updated_at | timestamp | |

#### **promo_codes**

| Column | Type | Notes |
|--------|------|-------|
| id | uuid | Primary key |
| event_id | uuid | FK to events |
| code | string | e.g., "EARLYBIRD" (unique per event) |
| discount_type | enum | `percentage`, `fixed_amount` |
| discount_value | integer | Percentage (10 = 10%) or cents |
| max_uses | integer | Total redemptions allowed |
| times_used | integer | Counter, default 0 |
| valid_from | timestamp | Start date |
| valid_until | timestamp | Expiry date |
| is_active | boolean | Can be toggled off |
| created_at | timestamp | |
| updated_at | timestamp | |

#### **orders**

| Column | Type | Notes |
|--------|------|-------|
| id | uuid | Primary key |
| user_id | uuid | FK to users (buyer) |
| event_id | uuid | FK to events |
| status | enum | `pending`, `completed`, `refunded`, `cancelled` |
| subtotal_cents | integer | Before fees |
| service_fee_cents | integer | HafaPass fee |
| stripe_fee_cents | integer | Payment processing |
| total_cents | integer | What buyer paid |
| promo_code_id | uuid | FK to promo_codes (optional) |
| discount_cents | integer | Amount discounted |
| stripe_payment_intent_id | string | For refunds/tracking |
| stripe_charge_id | string | Charge reference |
| buyer_email | string | For guest checkout |
| buyer_name | string | For guest checkout |
| buyer_phone | string | Optional |
| completed_at | timestamp | When payment succeeded |
| created_at | timestamp | |
| updated_at | timestamp | |

#### **tickets**

| Column | Type | Notes |
|--------|------|-------|
| id | uuid | Primary key |
| order_id | uuid | FK to orders |
| ticket_type_id | uuid | FK to ticket_types |
| event_id | uuid | FK to events (denormalized for queries) |
| qr_code | string | Unique code for scanning |
| status | enum | `valid`, `checked_in`, `cancelled`, `transferred` |
| checked_in_at | timestamp | When scanned |
| checked_in_by | uuid | FK to users (staff who scanned) |
| attendee_name | string | Name on ticket |
| attendee_email | string | For ticket delivery |
| is_comp | boolean | Complimentary ticket |
| comp_reason | string | e.g., "Promoter guest list" |
| created_at | timestamp | |
| updated_at | timestamp | |

#### **guest_list_entries**
For comps and VIP lists (not purchased tickets).

| Column | Type | Notes |
|--------|------|-------|
| id | uuid | Primary key |
| event_id | uuid | FK to events |
| name | string | Guest name |
| email | string | Optional |
| phone | string | Optional |
| party_size | integer | +1s, default 1 |
| notes | text | e.g., "VIP table", "Promoter guest" |
| added_by | uuid | FK to users |
| status | enum | `pending`, `checked_in`, `no_show` |
| checked_in_at | timestamp | |
| created_at | timestamp | |
| updated_at | timestamp | |

---

## **Rails Models**

### **Associations Overview**

```ruby
# app/models/user.rb
class User < ApplicationRecord
  has_one :organizer_profile, dependent: :destroy
  has_many :orders, dependent: :nullify
  has_many :tickets, through: :orders
  
  enum role: { attendee: 0, organizer: 1, admin: 2 }
end

# app/models/organizer_profile.rb
class OrganizerProfile < ApplicationRecord
  belongs_to :user
  has_many :events, dependent: :destroy
  
  validates :business_name, presence: true
  validates :stripe_account_id, uniqueness: true, allow_nil: true
end

# app/models/event.rb
class Event < ApplicationRecord
  belongs_to :organizer_profile
  belongs_to :parent_event, class_name: 'Event', optional: true
  
  has_many :child_events, class_name: 'Event', foreign_key: 'parent_event_id'
  has_many :ticket_types, dependent: :destroy
  has_many :promo_codes, dependent: :destroy
  has_many :orders, dependent: :restrict_with_error
  has_many :tickets, dependent: :restrict_with_error
  has_many :guest_list_entries, dependent: :destroy
  
  has_one_attached :cover_image
  
  enum status: { draft: 0, published: 1, cancelled: 2, completed: 3 }
  enum category: { nightlife: 0, concert: 1, festival: 2, dining: 3, sports: 4, other: 5 }
  enum age_restriction: { all_ages: 0, eighteen_plus: 1, twenty_one_plus: 2 }
  
  validates :title, presence: true
  validates :starts_at, presence: true
  validates :venue_name, presence: true
  
  before_save :generate_slug
  
  scope :published, -> { where(status: :published) }
  scope :upcoming, -> { where('starts_at > ?', Time.current) }
  scope :past, -> { where('starts_at <= ?', Time.current) }
  
  def tickets_available?
    ticket_types.sum(:quantity_available) > ticket_types.sum(:quantity_sold)
  end
  
  def total_revenue_cents
    orders.completed.sum(:subtotal_cents)
  end
  
  private
  
  def generate_slug
    self.slug = title.parameterize if slug.blank?
  end
end

# app/models/ticket_type.rb
class TicketType < ApplicationRecord
  belongs_to :event
  has_many :tickets, dependent: :restrict_with_error
  
  validates :name, presence: true
  validates :price_cents, numericality: { greater_than_or_equal_to: 0 }
  validates :quantity_available, numericality: { greater_than: 0 }
  
  def sold_out?
    quantity_sold >= quantity_available
  end
  
  def available_quantity
    quantity_available - quantity_sold
  end
  
  def price_dollars
    price_cents / 100.0
  end
end

# app/models/promo_code.rb
class PromoCode < ApplicationRecord
  belongs_to :event
  has_many :orders, dependent: :nullify
  
  enum discount_type: { percentage: 0, fixed_amount: 1 }
  
  validates :code, presence: true, uniqueness: { scope: :event_id }
  validates :discount_value, numericality: { greater_than: 0 }
  
  before_save :upcase_code
  
  def valid_for_use?
    is_active && 
      (max_uses.nil? || times_used < max_uses) &&
      (valid_from.nil? || Time.current >= valid_from) &&
      (valid_until.nil? || Time.current <= valid_until)
  end
  
  def calculate_discount(subtotal_cents)
    if percentage?
      (subtotal_cents * discount_value / 100.0).round
    else
      [discount_value, subtotal_cents].min
    end
  end
  
  private
  
  def upcase_code
    self.code = code.upcase
  end
end

# app/models/order.rb
class Order < ApplicationRecord
  belongs_to :user, optional: true  # Guest checkout allowed
  belongs_to :event
  belongs_to :promo_code, optional: true
  
  has_many :tickets, dependent: :destroy
  
  enum status: { pending: 0, completed: 1, refunded: 2, cancelled: 3 }
  
  validates :buyer_email, presence: true
  validates :total_cents, numericality: { greater_than_or_equal_to: 0 }
  
  before_create :generate_order_number
  
  scope :completed, -> { where(status: :completed) }
  
  def complete!
    update!(status: :completed, completed_at: Time.current)
    promo_code&.increment!(:times_used)
    tickets.each(&:generate_qr_code!)
    send_confirmation_email
    send_confirmation_sms if buyer_phone.present?
  end
  
  private
  
  def generate_order_number
    self.order_number ||= "HP-#{SecureRandom.alphanumeric(8).upcase}"
  end
  
  def send_confirmation_email
    OrderMailer.confirmation(self).deliver_later
  end
  
  def send_confirmation_sms
    SmsService.send_ticket_confirmation(self)
  end
end

# app/models/ticket.rb
class Ticket < ApplicationRecord
  belongs_to :order
  belongs_to :ticket_type
  belongs_to :event
  
  enum status: { valid: 0, checked_in: 1, cancelled: 2, transferred: 3 }
  
  validates :qr_code, uniqueness: true, allow_nil: true
  
  before_create :set_attendee_info
  
  def generate_qr_code!
    update!(qr_code: SecureRandom.uuid)
  end
  
  def check_in!(staff_user = nil)
    return false unless valid?
    update!(
      status: :checked_in,
      checked_in_at: Time.current,
      checked_in_by: staff_user&.id
    )
  end
  
  def checked_in?
    status == 'checked_in'
  end
  
  private
  
  def set_attendee_info
    self.attendee_email ||= order.buyer_email
    self.attendee_name ||= order.buyer_name
  end
end

# app/models/guest_list_entry.rb
class GuestListEntry < ApplicationRecord
  belongs_to :event
  belongs_to :added_by, class_name: 'User'
  
  enum status: { pending: 0, checked_in: 1, no_show: 2 }
  
  validates :name, presence: true
  validates :party_size, numericality: { greater_than: 0 }
  
  def check_in!
    update!(status: :checked_in, checked_in_at: Time.current)
  end
end
```

---

## **Key API Endpoints**

### **Public Endpoints (No Auth)**

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v1/events` | List published events |
| GET | `/api/v1/events/:slug` | Get event details |
| POST | `/api/v1/orders` | Create order (checkout) |
| POST | `/api/v1/orders/:id/complete` | Stripe webhook callback |
| GET | `/api/v1/tickets/:qr_code` | Validate ticket (for scanner) |

### **Attendee Endpoints (Auth Required)**

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v1/me/orders` | My orders |
| GET | `/api/v1/me/tickets` | My tickets |

### **Organizer Endpoints (Auth + Organizer Role)**

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v1/organizer/events` | My events |
| POST | `/api/v1/organizer/events` | Create event |
| PUT | `/api/v1/organizer/events/:id` | Update event |
| DELETE | `/api/v1/organizer/events/:id` | Delete draft event |
| POST | `/api/v1/organizer/events/:id/publish` | Publish event |
| GET | `/api/v1/organizer/events/:id/orders` | Event orders |
| GET | `/api/v1/organizer/events/:id/attendees` | Attendee list |
| POST | `/api/v1/organizer/events/:id/ticket_types` | Add ticket type |
| POST | `/api/v1/organizer/events/:id/promo_codes` | Add promo code |
| POST | `/api/v1/organizer/events/:id/guest_list` | Add to guest list |
| POST | `/api/v1/organizer/tickets/:qr_code/check_in` | Check in ticket |

### **Stripe Webhooks**

| Endpoint | Events Handled |
|----------|----------------|
| `/webhooks/stripe` | `payment_intent.succeeded`, `payment_intent.failed`, `charge.refunded` |

---

## **Frontend Pages**

### **Public Pages**

| Page | Route | Description |
|------|-------|-------------|
| Home | `/` | Featured events, search |
| Event Listing | `/events` | Browse all events |
| Event Details | `/events/:slug` | Event info, buy tickets |
| Checkout | `/checkout/:event_slug` | Ticket selection, payment |
| Order Confirmation | `/orders/:id/confirmation` | Success page, ticket links |
| View Ticket | `/tickets/:qr_code` | Individual ticket with QR |

### **Organizer Dashboard**

| Page | Route | Description |
|------|-------|-------------|
| Dashboard Home | `/dashboard` | Overview, stats |
| My Events | `/dashboard/events` | List of my events |
| Create Event | `/dashboard/events/new` | Event creation form |
| Edit Event | `/dashboard/events/:id/edit` | Edit event details |
| Event Analytics | `/dashboard/events/:id` | Sales, attendees |
| Scanner | `/dashboard/scanner` | QR code scanner |
| Guest List | `/dashboard/events/:id/guest-list` | Manage comps |

---

# 🛣️ **Product Roadmap**

## 🟡 **Phase 2 — Ambros Pilot (3-6 months post-launch)**

**Goal:** Roll out to 10-20 Ambros venue accounts

**Features:**
* Venue Profiles (branded pages)
* Promoter revenue splits
* Sponsor branding on events
* Enhanced analytics
* Repeat attendee tracking

## 🔵 **Phase 3 — Island-Wide Expansion (6-12 months)**

**Goal:** Become the default ticketing platform for Guam's hospitality scene

**Features:**
* Mobile App (iOS/Android)
* Tourism integrations (hotel concierge)
* VIP & table reservations
* Military community features
* Multi-language support

## 🔴 **Phase 4 — Platform & Expansion (12+ months)**

**Goal:** Expand beyond nightlife; explore Micronesia expansion

**Features:**
* White-label for hotels
* Event category expansion
* API/embed widgets
* Advanced integrations

---

# 📦 **Feature Priority Matrix**

| Feature | MVP | Phase 2 | Phase 3 | Phase 4 |
|---------|:---:|:-------:|:-------:|:-------:|
| Self-service event setup | ✅ | ✔ | ✔ | ✔ |
| Mobile checkout | ✅ | ✔ | ✔ | ✔ |
| QR scanner/check-in | ✅ | ✔ | ✔ | ✔ |
| Recurring events | ✅ | ✔ | ✔ | ✔ |
| Promo codes | ✅ | ✔ | ✔ | ✔ |
| Guest list / comps | ✅ | ✔ | ✔ | ✔ |
| Promoter splits | ⚪ | ✅ | ✔ | ✔ |
| Sponsor branding | ⚪ | ✅ | ✔ | ✔ |
| Venue profiles | ⚪ | ✅ | ✔ | ✔ |
| Mobile app | ❌ | ❌ | ✅ | ✔ |
| VIP/table reservations | ❌ | ❌ | ✅ | ✔ |
| Hotel integrations | ❌ | ❌ | ✅ | ✔ |
| White-label | ❌ | ❌ | ❌ | ✅ |
| API/Widget | ❌ | ❌ | ❌ | ✅ |

---

# 🎯 **Go-To-Market Strategy**

### **Phase 1: Prove It Works (Months 1-3)**

| Step | Action |
|------|--------|
| 1 | Build MVP (12 weeks) |
| 2 | Test with Uncle Christian's events (2-3 events) |
| 3 | Iterate based on real feedback |
| 4 | Document results (tickets sold, user feedback, revenue) |

### **Phase 2: Ambros Pilot (Months 3-6)**

| Step | Action |
|------|--------|
| 1 | Pitch to Carlos/Uncle Tom with proven results |
| 2 | Identify 5-10 key venue accounts for pilot |
| 3 | Ambros sales reps introduce platform to accounts |
| 4 | Onboard pilot venues, provide hands-on support |

### **Phase 3: Scale (Months 6-12)**

| Step | Action |
|------|--------|
| 1 | Roll out to all interested Ambros accounts |
| 2 | Add to Ambros's standard account offering |
| 3 | Launch consumer-facing marketing (app, discovery) |
| 4 | Expand to non-Ambros venues (now with social proof) |

---

# 🧠 **Success Metrics**

### **MVP Phase**

| Metric | Target |
|--------|--------|
| Events hosted | 5+ |
| Tickets sold | 500+ |
| Mobile conversion rate | > 60% |
| Organizer satisfaction | Would recommend |

### **Ambros Pilot Phase**

| Metric | Target |
|--------|--------|
| Venue accounts onboarded | 10-20 |
| Monthly active events | 20+ |
| Venue retention (90 days) | > 70% |
| Revenue per venue | Measurable growth |

### **Scale Phase**

| Metric | Target |
|--------|--------|
| % of Ambros accounts using platform | > 30% |
| Monthly ticket sales | 5,000+ |
| App downloads | 10,000+ |
| Monthly active users | 5,000+ |

---

# 🔑 **Key Risks & Mitigations**

| Risk | Mitigation |
|------|------------|
| Ambros doesn't want to partner | Start with Uncle Christian's events; prove value first. Family connection gives you a real shot at the pitch. |
| Venues don't adopt | Make it dead-simple. Offer free setup + hands-on support for pilot accounts. |
| GuamTime fights back | You're not competing directly — you're venue/hospitality focused, they're event-discovery focused. Different positioning. |
| Technical complexity | Start simple. MVP is just: create event → sell tickets → scan at door. |

---

# 🎯 **Why This Wins**

1. **Distribution > Features:** Ambros gives you warm intros to every venue on Guam. No cold calls.

2. **Venue-first positioning:** GuamTime is event-discovery. You're venue-operations. Different market.

3. **Built-in sponsors:** Bud Light, Patrón, Grey Goose events = natural platform fit.

4. **Family advantage:** Uncle Christian tests it. Carlos/Tom at Ambros are family. You get real feedback and a real shot.

5. **Network effects:** Once 20 venues use it, organizers come to you. Once organizers use it, attendees expect it.

6. **Pricing advantage:** 3% + $0.50 vs. GuamTime's reportedly high fees.

---

# 🎨 **Design Direction**

### **Visual Style**

| Element | Direction |
|---------|-----------|
| **Overall** | Clean, modern, minimal |
| **Colors** | Ocean blues, sandy neutrals, coral/sunset accents |
| **Typography** | Modern sans-serif (clean), subtle island-inspired accents |
| **Dark Mode** | Yes — especially for nightlife focus |
| **Imagery** | Subtle wave patterns, island textures, not kitschy |
| **Reference** | Complement Ambros branding for future partnership |

---

# 📝 **Next Steps**

1. [x] Finalize PRD and technical spec
2. [ ] Set up Rails API project with Clerk auth
3. [ ] Set up React frontend with basic routing
4. [ ] Create database migrations for core models
5. [ ] Build event creation flow
6. [ ] Integrate Stripe checkout
7. [ ] Build ticket generation + QR codes
8. [ ] Build scanner interface
9. [ ] Test with Uncle Christian's first event
10. [ ] Iterate and prepare Ambros pitch

---

*"We're not building a GuamTime competitor. We're building the ticketing arm of Guam's hospitality network."*
