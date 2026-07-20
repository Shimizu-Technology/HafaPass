import { describe, expect, it } from 'vitest'
import { formatEventDate, formatEventTime, toEventLocalInput } from './eventTime'

describe('event time formatting', () => {
  const guamSevenPm = '2026-08-15T09:00:00.000Z'

  it('renders the Guam venue time instead of the browser timezone', () => {
    expect(formatEventTime(guamSevenPm, 'Pacific/Guam')).toBe('7:00 PM')
    expect(formatEventDate(guamSevenPm, 'Pacific/Guam')).toBe('Aug 15, 2026')
  })

  it('round-trips an API timestamp into a Guam datetime-local value', () => {
    expect(toEventLocalInput(guamSevenPm, 'Pacific/Guam')).toBe('2026-08-15T19:00')
  })
})
