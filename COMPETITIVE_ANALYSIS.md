# HafaPass — Competitive Analysis & Insights

_Compiled Feb 2, 2026_

---

## The Landscape

### Direct Competitor: GuamTime
**Guam's #1 local event platform** — but they have weaknesses:
- **Ticketing site is currently DOWN** (tickets.guamtime.net shows "Your site will be live soon")
- They're primarily an event directory, not a tech platform
- Manual setup: organizers fill out a Google Form, GuamTime builds the ticketing page within 24 hours
- Claims 20,000+ social media audience
- Payment: check within 2-3 business days post-event
- No self-service — you can't create your own event
- Reportedly takes 10-15% of ticket revenue (per Leon's knowledge)

**HafaPass advantages over GuamTime:**
1. Self-service (create event → sell tickets in minutes, not 24 hours)
2. Lower fees (3% + $0.50 vs ~10-15%)
3. Instant digital tickets with QR codes
4. Real-time analytics
5. Ambros distribution network for venue adoption
6. Modern mobile-first UX

---

## Key Platforms Studied

### 1. DICE (Nightlife/Music Focus)
**What they do right:**
- **All-in-one pricing** — no hidden fees, what you see is what you pay
- **Anti-scalping** — tickets are non-transferable, tied to the app
- **Curated discovery** — editorial team selects events (quality over quantity)
- **Waiting list** — if sold out, fans join waitlist, get tickets at face value when others can't go
- **Mobile-only tickets** — QR code only appears right before event start (prevents screenshots)

**What we should learn:**
- The waiting list + anti-scalping combo is brilliant for nightlife
- Curated event discovery builds trust ("if it's on DICE, it's good")
- BUT forcing app download is polarizing — 90-120s checkout, no guest checkout

**What we should NOT copy:**
- Forcing app download (our web-first approach is better for Guam's market)
- Their checkout is actually slow (90-120s vs industry best of 30s)

### 2. Luma (Beautiful Design, Community Focus)
**What they do right:**
- **Stunning event pages** — modern, clean, feel premium (Instagram-worthy)
- **Social proof** — shows who's coming publicly (drives RSVP rates up)
- **Guest chat** — attendees can communicate before/during event
- **One-click RSVP** — minimal friction
- **Referral system** — guests can invite friends
- **Free for free events** — no fees at all
- **Next-day payouts** via Stripe

**What we should learn:**
- Beautiful event pages sell tickets. Design IS the product.
- Social proof ("38 people going, including Jake and Sarah") drives conversions
- Guest referrals create organic growth
- Post-event feedback surveys build organizer insights

### 3. TixFox (Lowest Fees)
**What they do right:**
- **$0.39 flat fee** per ticket — dramatically cheaper than everyone
- **Instant payouts** — money immediately
- **2-minute setup** — fastest onboarding
- **White-label** — custom branding

**Insight:** Proves that transparent, low pricing wins organizers. HafaPass's 3% + $0.50 is competitive but TixFox shows the floor.

### 4. Eventbrite (Market Leader)
**What they get wrong (and we can exploit):**
- 10-14% in fees per ticket
- Delayed payouts (5-7 days AFTER the event)
- Complex pricing structure
- No fee refunds since Aug 2023
- Limited white-label
- 23.5 form elements in checkout (bloated)

### 5. TicketSpice (Customization King)
**What they do right:**
- **RealView page builder** — drag-and-drop event pages with conditional logic
- **Keep your convenience fees** — organizers can add their own markup
- **Box office POS** — full point-of-sale for walk-ups
- **Offline scanning** — scanner works without internet

**What we should learn:**
- Box office / POS mode is essential for Guam events (door sales are huge)
- Offline scanning is critical (Guam venue WiFi is unreliable)

---

## Critical UX Insights

### Single-Page Checkout Wins
Data from Ticketsauce and Baymard Institute:
- **18% of buyers abandon** because checkout is too long/complicated
- **Single-page checkout is 66% faster** than multi-step (30s vs 89s average)
- **Apple Pay/Google Pay** reduces checkout to 10-15 seconds
- Average US checkout has 23.5 form elements; best-in-class has 12-14
- **0.1s load speed improvement** → 8% conversion increase (Google)
- **Mobile buyers**: 50%+ abandon if load > 3 seconds

### What This Means for HafaPass
Our current CheckoutPage is already single-page (good!) but has no payment integration. When we add Stripe, we must:
1. Keep it single-page (ticket selection + buyer info + payment)
2. Support Apple Pay / Google Pay via Stripe Payment Request Button
3. Minimize form fields (name, email, phone-optional, card)
4. Add inline validation (don't redirect on errors)
5. Show clear order summary with fee breakdown

---

## Differentiation Strategy for HafaPass

### What We Can Uniquely Do (That No One Else Can)

1. **Ambros Distribution Network** — Warm intros to every venue on Guam. This is the moat.
2. **Local-First** — GuamTime is manual and clunky. We're self-service and instant.
3. **Hospitality-Focused** — Built for bars, clubs, restaurants (not conferences or yoga classes)
4. **Family Connection** — Uncle Christian as first customer, Carlos/Uncle Tom at Ambros

### Features to Prioritize (Based on Research)

**Phase 1 (Must-Have for Launch):**
| Feature | Why | Competitor Reference |
|---------|-----|---------------------|
| Single-page checkout with Stripe | 66% faster conversion | Ticketsauce, TixFox |
| Apple Pay / Google Pay | 10-15 second checkout | Luma, TixFox |
| Beautiful event pages | Design sells tickets | Luma, DICE |
| QR scanner (works offline) | Guam WiFi unreliable | TicketSpice |
| Guest list / door list | Every Guam event has comps | Universe, TicketSpice |
| Mobile-first everything | 75%+ buyers on phone | All platforms |

**Phase 2 (Post-Launch):**
| Feature | Why | Competitor Reference |
|---------|-----|---------------------|
| Social proof on event pages | "38 people going" drives RSVP | Luma |
| Referral system | Organic growth | Luma |
| Box office / POS mode | Door sales are huge in Guam | TicketSpice |
| Recurring events | Weekly club nights | TicketSpice, SimpleTix |
| Promo codes | Every promoter wants them | TixFox, Eventbrite |
| Organizer payouts (Stripe Connect) | Scale beyond Uncle Christian | All platforms |

**Phase 3 (Differentiators):**
| Feature | Why | Competitor Reference |
|---------|-----|---------------------|
| Waiting list (at face value) | Anti-scalping for hot events | DICE |
| Ambros sponsor integration | Branded events (Bud Light party) | Unique to HafaPass |
| Post-event surveys | Help organizers improve | Luma |
| Event series/templates | "Every Saturday" for venues | TicketSpice |
| White-label for venues | "Powered by HafaPass" | TicketSpice, TixFox |

---

## Pricing Comparison

| Platform | Fee Model | $25 Ticket Cost |
|----------|-----------|-----------------|
| GuamTime | ~10-15% (estimated) | $2.50-$3.75 |
| Eventbrite | 3.7% + $1.79 + 2.9% processing | $3.45 (13.8%) |
| TixFox | $0.39 flat | $0.39 (1.6%) |
| Ticket Tailor | $0.85 + processing | ~$1.85 (7.4%) |
| **HafaPass** | **3% + $0.50/ticket** | **$1.25 (5.0%)** |

HafaPass is competitive but not the cheapest. Our value prop isn't price alone — it's **distribution + local + hospitality-focused**.

---

## Key Takeaways for Development

1. **Checkout speed is everything** — single page, minimal fields, wallet support
2. **Beautiful event pages sell tickets** — invest in design (Luma-level quality)
3. **Offline scanner is critical** for Guam venues
4. **Guest list is table stakes** for nightlife/hospitality events
5. **GuamTime is vulnerable** — their ticketing is literally down, and their model is manual
6. **Social proof drives conversion** — show who's going
7. **Instant payouts matter** for organizer adoption
