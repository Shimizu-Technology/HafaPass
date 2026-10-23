import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { configureEnabledLanguages, setActiveLanguage } from './locale'
import { formatEventDate, formatEventDateTime, formatEventTime, formatEventTimeRange, formatPlatformDateTime, fromEventLocalInput, toEventLocalInput } from './eventTime'

describe('event time formatting', () => {
  const guamSevenPm = '2026-08-15T09:00:00.000Z'

  it('renders the Guam venue time instead of the browser timezone', () => {
    expect(formatEventTime(guamSevenPm, 'Pacific/Guam')).toBe('7:00 PM Guam time')
    expect(formatEventDate(guamSevenPm, 'Pacific/Guam')).toBe('Aug 15, 2026')
  })

  it('names a different event zone and follows daylight saving time', () => {
    expect(formatEventTime('2026-08-15T09:00:00Z', 'America/New_York')).toContain('EDT')
    expect(formatEventTime('2026-01-15T09:00:00Z', 'America/New_York')).toContain('EST')
    expect(formatEventTime('invalid')).toBe('')
  })

  it('round-trips an API timestamp into a Guam datetime-local value', () => {
    expect(toEventLocalInput(guamSevenPm, 'Pacific/Guam')).toBe('2026-08-15T19:00')
    expect(fromEventLocalInput('2026-08-15T19:00', 'Pacific/Guam').toISOString()).toBe('2026-08-15T09:00:00.000Z')
  })

  it('keeps a same-day event range compact in its Guam venue timezone', () => {
    expect(formatEventTimeRange('2026-10-11T09:00:00Z', '2026-10-11T12:00:00Z', 'Pacific/Guam'))
      .toBe('7:00 PM Guam time – 10:00 PM Guam time')
  })

  it('shows the end date after Guam midnight even when both instants have the same UTC date', () => {
    expect(formatEventTimeRange('2026-10-11T13:14:00Z', '2026-10-11T17:14:00Z', 'Pacific/Guam'))
      .toBe('11:14 PM Guam time – Oct 12, 2026, 3:14 AM Guam time')
  })

  it('omits an extra date when different UTC days fall on the same Guam local day', () => {
    expect(formatEventTimeRange('2026-10-11T23:00:00Z', '2026-10-12T01:00:00Z', 'Pacific/Guam'))
      .toBe('9:00 AM Guam time – 11:00 AM Guam time')
  })

  it('includes the correct year when an event continues into the next local year', () => {
    expect(formatEventTimeRange('2026-12-31T13:00:00Z', '2026-12-31T15:00:00Z', 'Pacific/Guam'))
      .toBe('11:00 PM Guam time – Jan 1, 2027, 1:00 AM Guam time')
  })

  it('keeps the start time for an event without an end and avoids an invalid-date label', () => {
    expect(formatEventTimeRange(guamSevenPm, null, 'Pacific/Guam')).toBe('7:00 PM Guam time')
    expect(formatEventTimeRange(guamSevenPm, 'invalid', 'Pacific/Guam')).toBe('7:00 PM Guam time')
  })
})

describe('event time formatting in the active language', () => {
  beforeEach(() => configureEnabledLanguages('ko,ja,zh-Hant,zh,tl'))
  afterEach(() => { setActiveLanguage('en'); configureEnabledLanguages('en') })

  it('keeps platform timestamps in US English and Guam time with Japanese active', () => {
    setActiveLanguage('ja')
    expect(formatPlatformDateTime('2026-10-21T17:00:00Z')).toBe('Oct 22, 2026, 3:00 AM Guam time')
  })

  it('keeps the Guam venue time while following the selected language', () => {
    const start = '2026-10-21T09:00:00Z'
    setActiveLanguage('ko')
    expect(formatEventDate(start)).toBe('2026년 10월 21일')
    // ICU releases differ on whether ko-KR renders the day period in Korean or English.
    expect(['오후 7:00 Guam time', 'PM 7:00 Guam time']).toContain(formatEventTime(start))
    setActiveLanguage('ja')
    expect(formatEventDate(start)).toBe('2026年10月21日')
    expect(formatEventTime(start)).toBe('19:00 Guam time')
    setActiveLanguage('zh-Hant')
    expect(formatEventDate(start)).toBe('2026年10月21日')
    setActiveLanguage('en')
    expect(formatEventDateTime(start)).toBe('Oct 21, 2026, 7:00 PM Guam time')
  })
})
