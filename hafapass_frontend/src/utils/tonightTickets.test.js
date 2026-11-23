import { describe, expect, it } from 'vitest'
import { happeningToday, pinnableTonight } from './tonightTickets'
import { eventTimeZone } from './eventTime'

// 2026-11-23 00:10 in Guam (UTC+10) is 2026-11-22 14:10 UTC.
const guamJustAfterMidnight = new Date('2026-11-22T14:10:00Z')
const guam = (iso, extra = {}) => ({ starts_at: iso, timezone: 'Pacific/Guam', ...extra })
const usable = { status: 'issued', admission_allowed: true }

describe('eventTimeZone', () => {
  it('keeps a known zone and falls back to Guam for missing or malformed ones', () => {
    expect(eventTimeZone('America/Los_Angeles')).toBe('America/Los_Angeles')
    for (const zone of [null, undefined, '', 'Not/AZone', 42]) expect(eventTimeZone(zone)).toBe('Pacific/Guam')
  })
})

describe('happeningToday', () => {
  it('never counts an event without a usable start date', () => {
    const future = '2099-01-01T00:00:00Z'
    expect(happeningToday({ starts_at: null, ends_at: future }, guamJustAfterMidnight)).toBe(false)
    expect(happeningToday({ ends_at: future }, guamJustAfterMidnight)).toBe(false)
    expect(happeningToday({ starts_at: 'not a date', ends_at: future }, guamJustAfterMidnight)).toBe(false)
    expect(happeningToday(null, guamJustAfterMidnight)).toBe(false)
  })

  it('ignores a malformed end date and uses six hours from the start', () => {
    const started = '2026-11-22T13:00:00Z' // 23:00 Guam, 70 minutes ago
    expect(happeningToday(guam(started, { ends_at: 'garbage' }), guamJustAfterMidnight)).toBe(true)
    expect(happeningToday(guam('2026-11-22T07:00:00Z', { ends_at: 'garbage' }), guamJustAfterMidnight)).toBe(false)
  })

  it('falls back to Guam for a malformed or missing time zone instead of throwing', () => {
    for (const timezone of ['Not/AZone', null, undefined]) {
      expect(() => happeningToday({ starts_at: '2026-11-22T22:00:00Z', timezone }, guamJustAfterMidnight)).not.toThrow()
      expect(happeningToday({ starts_at: '2026-11-22T22:00:00Z', timezone }, guamJustAfterMidnight)).toBe(true)
    }
  })

  it('follows the Guam calendar day across midnight', () => {
    // 08:00 the same Guam day: later today, pinned.
    expect(happeningToday(guam('2026-11-22T22:00:00Z'), guamJustAfterMidnight)).toBe(true)
    // 08:00 the next Guam day: not tonight yet.
    expect(happeningToday(guam('2026-11-23T22:00:00Z'), guamJustAfterMidnight)).toBe(false)
    // Started 23:30 yesterday and still under way: stays pinned past midnight.
    expect(happeningToday(guam('2026-11-22T13:30:00Z'), guamJustAfterMidnight)).toBe(true)
    // Yesterday's event that ended at 23:59 is no longer pinned.
    expect(happeningToday(guam('2026-11-22T09:00:00Z', { ends_at: '2026-11-22T13:59:00Z' }), guamJustAfterMidnight)).toBe(false)
    // The same instant is a different day in Los Angeles: 06:10 on Nov 22 there.
    expect(happeningToday({ starts_at: '2026-11-23T03:00:00Z', timezone: 'America/Los_Angeles' }, guamJustAfterMidnight)).toBe(true)
  })
})

describe('pinnableTonight', () => {
  const tonight = guam('2026-11-22T22:00:00Z')
  it('pins only issued tickets the server will admit', () => {
    expect(pinnableTonight(usable, tonight, guamJustAfterMidnight)).toBe(true)
    expect(pinnableTonight({ ...usable, admission_allowed: false }, tonight, guamJustAfterMidnight)).toBe(false)
    expect(pinnableTonight({ status: 'issued' }, tonight, guamJustAfterMidnight)).toBe(false)
    expect(pinnableTonight({ ...usable, status: 'checked_in' }, tonight, guamJustAfterMidnight)).toBe(false)
    expect(pinnableTonight({ ...usable, pass_parent: true }, tonight, guamJustAfterMidnight)).toBe(false)
  })
})
