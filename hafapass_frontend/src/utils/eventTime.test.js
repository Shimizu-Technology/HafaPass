import { describe, expect, it } from 'vitest'
import { formatEventDate, formatEventTime, formatEventTimeRange, toEventLocalInput } from './eventTime'

describe('event time formatting', () => {
  const guamSevenPm = '2026-08-15T09:00:00.000Z'

  it('renders the Guam venue time instead of the browser timezone', () => {
    expect(formatEventTime(guamSevenPm, 'Pacific/Guam')).toBe('7:00 PM')
    expect(formatEventDate(guamSevenPm, 'Pacific/Guam')).toBe('Aug 15, 2026')
  })

  it('round-trips an API timestamp into a Guam datetime-local value', () => {
    expect(toEventLocalInput(guamSevenPm, 'Pacific/Guam')).toBe('2026-08-15T19:00')
  })

  it('keeps a same-day event range compact in its Guam venue timezone', () => {
    expect(formatEventTimeRange('2026-10-11T09:00:00Z', '2026-10-11T12:00:00Z', 'Pacific/Guam'))
      .toBe('7:00 PM – 10:00 PM')
  })

  it('shows the end date after Guam midnight even when both instants have the same UTC date', () => {
    expect(formatEventTimeRange('2026-10-11T13:14:00Z', '2026-10-11T17:14:00Z', 'Pacific/Guam'))
      .toBe('11:14 PM – Oct 12, 2026, 3:14 AM')
  })

  it('omits an extra date when different UTC days fall on the same Guam local day', () => {
    expect(formatEventTimeRange('2026-10-11T23:00:00Z', '2026-10-12T01:00:00Z', 'Pacific/Guam'))
      .toBe('9:00 AM – 11:00 AM')
  })

  it('includes the correct year when an event continues into the next local year', () => {
    expect(formatEventTimeRange('2026-12-31T13:00:00Z', '2026-12-31T15:00:00Z', 'Pacific/Guam'))
      .toBe('11:00 PM – Jan 1, 2027, 1:00 AM')
  })

  it('keeps the start time for an event without an end and avoids an invalid-date label', () => {
    expect(formatEventTimeRange(guamSevenPm, null, 'Pacific/Guam')).toBe('7:00 PM')
    expect(formatEventTimeRange(guamSevenPm, 'invalid', 'Pacific/Guam')).toBe('7:00 PM')
  })
})
