import { describe, expect, it } from 'vitest'
import { estimateCheckoutLine } from './checkoutEstimate'

const event = { buyer_fee_percent: 100, ticket_types: [
  { id: 8, name: 'Admission', price_cents: 2500, current_price_cents: 2000, service_fee_cents: 200, all_in_price_cents: 2200 },
] }

describe('checkout estimate lines', () => {
  it('prices a claimed waitlist offer at the offered unit and fee, not the current tier', () => {
    const offer = { ticket_type_id: 8, quantity: 2, unit_price_cents: 2500, service_fee_cents: 225, all_in_price_cents: 2725 }
    expect(estimateCheckoutLine(event, { ticket_type_id: 8, quantity: 2 }, { waitlistOffer: offer }))
      .toMatchObject({ price_cents: 2500, lineTotal: 5000, feeCents: 450 })
  })
  it('prices held seats from the seat map', () => {
    const seats = [{ ticket_type_id: 8, price_cents: 1800, service_fee_cents: 190 }, { ticket_type_id: 8, price_cents: 1800, service_fee_cents: 190 }]
    expect(estimateCheckoutLine(event, { ticket_type_id: 8, quantity: 2 }, { seats }))
      .toMatchObject({ lineTotal: 3600, feeCents: 380 })
  })
  it('uses the ticket type all-in data otherwise and flags missing paid fee data', () => {
    expect(estimateCheckoutLine(event, { ticket_type_id: 8, quantity: 3 })).toMatchObject({ lineTotal: 6000, feeCents: 600 })
    const stale = { buyer_fee_percent: 50, ticket_types: [{ id: 8, name: 'Admission', price_cents: 2000 }] }
    expect(estimateCheckoutLine(stale, { ticket_type_id: 8, quantity: 1 }).feeCents).toBeNull()
    expect(estimateCheckoutLine({ ...stale, buyer_fee_percent: 0 }, { ticket_type_id: 8, quantity: 1 }).feeCents).toBe(0)
    expect(estimateCheckoutLine(event, { ticket_type_id: 99, quantity: 1 })).toBeNull()
  })
})
