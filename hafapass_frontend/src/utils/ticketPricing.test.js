import { describe, expect, it } from 'vitest'
import { formatTicketPrice, lowestPurchasablePrice, remainingTickets } from './ticketPricing'

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
})
