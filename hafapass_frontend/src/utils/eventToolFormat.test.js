import { describe, expect, it } from 'vitest'
import { pluralize, refundConfirmLabel, ticketCountLabel } from './eventToolFormat'

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
})
