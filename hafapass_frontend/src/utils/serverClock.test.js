import { afterEach, expect, it, vi } from 'vitest'
import { formatScheduleTime, getServerNow, syncServerClock } from './serverClock'

afterEach(() => {
  vi.useRealTimers()
  vi.restoreAllMocks()
})

it('anchors server time even when the client clock is spoofed and changes again', () => {
  vi.useFakeTimers({ toFake: ['Date', 'performance'] })
  vi.setSystemTime(new Date('2035-01-01T00:00:00Z'))
  syncServerClock('2027-05-01T13:58:59.000Z')
  expect(getServerNow()).toBe(Date.parse('2027-05-01T13:58:59Z'))
  vi.setSystemTime(new Date('2036-01-01T00:00:00Z'))
  vi.advanceTimersByTime(1000)
  expect(getServerNow()).toBe(Date.parse('2027-05-01T13:59:00Z'))
})

it('ignores a delayed server sample older than the extrapolated server clock', () => {
  vi.useFakeTimers({ toFake: ['Date', 'performance'] })
  vi.setSystemTime(new Date('2027-05-01T14:00:00Z'))
  syncServerClock('2027-05-01T14:00:00.000Z')
  vi.advanceTimersByTime(10_000)
  // A response stamped 1s after the first sample arriving 10s later must not move clock backward.
  syncServerClock('2027-05-01T14:00:01.000Z')
  expect(getServerNow()).toBe(Date.parse('2027-05-01T14:00:10Z'))
})

it.each([
  ['America/Los_Angeles', ' (6:59 AM PDT your time)'],
  ['Pacific/Guam', ''],
])('renders Guam time and conditionally appends the local time for %s', (localZone, suffix) => {
  const DateTimeFormat = Intl.DateTimeFormat
  vi.spyOn(Intl, 'DateTimeFormat').mockImplementation(function (locale, options) {
    return new DateTimeFormat(locale, { timeZone: localZone, ...options })
  })
  expect(formatScheduleTime('2026-05-01T13:59:00Z', 'Pacific/Guam')).toBe(
    `Fri, May 1 at 11:59 PM Guam time (ChST)${suffix}`,
  )
})

it('formats schedule dates using the requested interface locale', () => {
  const formatted = formatScheduleTime('2026-05-01T13:59:00Z', 'Pacific/Guam', { includeLocal: false, locale: 'ja-JP' })
  expect(formatted).toContain('5月1日')
  expect(formatted).toContain('Guam time (ChST)')
})
