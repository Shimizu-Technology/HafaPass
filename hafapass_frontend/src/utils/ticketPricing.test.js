import { describe, expect, it } from 'vitest'
import { formatTicketPrice, lowestPurchasablePrice, purchasableAllInPrices, remainingTickets, ticketAllInCents, ticketServiceFeeCents } from './ticketPricing'

describe('discovery ticket pricing', () => {
  it('advertises current available tiers instead of sold-out free or closed cheaper types', () => {
    expect(lowestPurchasablePrice([
      { price_cents: 0, quantity_remaining: 0 },
      { price_cents: 500, quantity_remaining: 10, on_sale: false },
      { price_cents: 2000, current_price_cents: 1250, quantity_remaining: 3, on_sale: true },
    ])).toBe(1250)
    expect(formatTicketPrice(1250)).toBe('$12.50')
  })
  it('does not coerce missing, negative or invalid prices to Free', () => {
    expect(lowestPurchasablePrice([{ price_cents: null }, { price_cents: -1 }, { price_cents: '0' }])).toBeNull()
    expect(formatTicketPrice(null)).toBe('')
    expect(formatTicketPrice(0, 'Free admission')).toBe('Free admission')
  })
  it('handles legacy remaining inventory and no purchasable tickets', () => {
    expect(remainingTickets({ quantity_available: 10, quantity_sold: 12 })).toBe(0)
    expect(lowestPurchasablePrice([{ price_cents: 1200, quantity_available: 10, quantity_sold: 10 }])).toBeNull()
    expect(lowestPurchasablePrice([])).toBeNull()
  })
  it('advertises the lowest all-in price including the buyer service fee', () => {
    const types = [
      { price_cents: 2000, current_price_cents: 2000, all_in_price_cents: 2200, service_fee_cents: 200, quantity_remaining: 5 },
      { price_cents: 1900, current_price_cents: 1900, all_in_price_cents: 2295, service_fee_cents: 395, quantity_remaining: 5 },
      { price_cents: 1000, all_in_price_cents: 1150, service_fee_cents: 150, quantity_remaining: 0 },
    ]
    expect(lowestPurchasablePrice(types)).toBe(2200)
    expect(purchasableAllInPrices(types)).toEqual([2200, 2295])
    expect(ticketServiceFeeCents(types[1])).toBe(395)
  })
  it('falls back to the ticket price only when the payload has no fee data', () => {
    expect(ticketAllInCents({ price_cents: 1250 })).toBe(1250)
    expect(ticketAllInCents({ price_cents: 1250, all_in_price_cents: -5 })).toBe(1250)
    expect(ticketAllInCents({ price_cents: null, all_in_price_cents: 900 })).toBeNull()
    expect(ticketServiceFeeCents({ price_cents: 1250 })).toBe(0)
  })
})
