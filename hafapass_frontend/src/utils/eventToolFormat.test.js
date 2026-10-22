import { describe, expect, it } from 'vitest'
import { partialRefundCents, pluralize, refundConfirmLabel, ticketCountLabel } from './eventToolFormat'

describe('eventToolFormat', () => {
  it('pluralizes ticket and attendee counts', () => {
    expect(ticketCountLabel(1)).toBe('1 ticket')
    expect(ticketCountLabel(0)).toBe('0 tickets')
    expect(ticketCountLabel(3)).toBe('3 tickets')
    expect(pluralize(17, 'attendee')).toBe('17 attendees')
    expect(pluralize(1, 'attendee')).toBe('1 attendee')
  })

  it('states the amount on the refund confirm when it is known', () => {
    expect(refundConfirmLabel({ refundable_cents: 10500 }, { type: 'full' })).toBe('Refund $105.00')
    expect(refundConfirmLabel({ refundable_cents: 10500 }, { type: 'partial', amount: '12.5' })).toBe('Refund $12.50')
    expect(refundConfirmLabel({ refundable_cents: 10500 }, { type: 'partial', amount: '' })).toBe('Process Refund')
    expect(refundConfirmLabel({}, { type: 'full' })).toBe('Process Refund')
  })

  it('accepts only whole cents from 1 cent up to the refundable amount', () => {
    expect(partialRefundCents('0.004', 10500)).toEqual({ cents: null, error: 'Enter dollars and cents, like 12.50.' })
    expect(partialRefundCents('0', 10500)).toEqual({ cents: null, error: 'Enter at least $0.01.' })
    expect(partialRefundCents('0.00', 10500).cents).toBeNull()
    expect(partialRefundCents('0.01', 10500)).toEqual({ cents: 1, error: null })
    expect(partialRefundCents('105', 10500)).toEqual({ cents: 10500, error: null })
    expect(partialRefundCents('105.01', 10500)).toEqual({ cents: null, error: 'Enter no more than $105.00.' })
    expect(partialRefundCents('1e2', 10500).cents).toBeNull()
    expect(partialRefundCents('', 10500)).toEqual({ cents: null, error: 'Enter the amount to refund.' })
    expect(partialRefundCents('19.99')).toEqual({ cents: 1999, error: null })
    expect(refundConfirmLabel({ refundable_cents: 10500 }, { type: 'partial', amount: '0.004' })).toBe('Process Refund')
    expect(refundConfirmLabel({ refundable_cents: 10500 }, { type: 'partial', amount: '0.01' })).toBe('Refund $0.01')
  })
})
