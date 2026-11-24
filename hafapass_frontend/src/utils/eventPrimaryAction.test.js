import { describe, expect, it } from 'vitest'
import { getPrimaryAction, selectionAction } from './eventPrimaryAction'
import { accentStyle } from './eventPageDesign'
const now = Date.parse('2026-11-24T00:00:00Z')
const event = { status: 'published', purchasable: true, starts_at: '2027-01-01T00:00:00Z', ticket_types: [{ on_sale: true, quantity_remaining: 5 }] }
describe('event primary action', () => {
  it.each([
    [{}, { kind: 'from' }, 'paid'], [{}, { kind: 'free' }, 'free'],
    [{ ticket_types: [{ quantity_remaining: 0 }] }, null, 'waitlist'],
    [{ ticket_types: [{ on_sale: false, quantity_remaining: 5, pricing_schedule: { next_tier: { starts_at: '2026-12-01T00:00:00Z' } } }] }, null, 'notify'],
    [{ starts_at: '2026-01-01T00:00:00Z' }, null, 'past'],
    [{ status: 'cancelled' }, null, 'closed'], [{ status: 'postponed' }, null, 'closed'],
    [{ private_preview: true }, null, 'private'],
  ])('uses the event state for %j', (changes, summary, kind) => expect(getPrimaryAction({ ...event, ...changes }, summary, now).kind).toBe(kind))
  it('labels a free selection by count and a paid selection by total', () => {
    expect(selectionAction({ count: 2, totalCents: 0 })).toEqual({ key: 'eventActions.reserveCount', values: { count: 2 } })
    expect(selectionAction({ count: 2, totalCents: 3350, formattedTotal: '$33.50' })).toEqual({ key: 'eventActions.checkoutTotal', values: { total: '$33.50' } })
  })
  it('falls back to brand-700 instead of white on a low contrast accent', () => {
    expect(accentStyle('#ffff00')).toMatchObject({ '--event-accent': '#0b6563', '--event-on-accent': '#ffffff' })
    expect(accentStyle('#112233')).toMatchObject({ '--event-accent': '#112233', '--event-on-accent': '#ffffff' })
  })
})
