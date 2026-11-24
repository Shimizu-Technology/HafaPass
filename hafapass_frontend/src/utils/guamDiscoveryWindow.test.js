import { describe, it, expect } from 'vitest'
import { matchesGuamWindow } from './guamDiscoveryWindow'
describe('Guam discovery calendar windows', () => {
  it.each(['2026-11-27T12:00:00+10:00', '2026-11-28T12:00:00+10:00', '2026-11-29T12:00:00+10:00'])('uses the current Fri–Sun weekend at %s', now => {
    expect(matchesGuamWindow('2026-11-28T18:00:00+10:00', 'weekend', now)).toBe(true)
    expect(matchesGuamWindow('2026-12-04T18:00:00+10:00', 'weekend', now)).toBe(false)
  })
  it('advances to the following weekend on Monday', () => {
    expect(matchesGuamWindow('2026-12-04T18:00:00+10:00', 'weekend', '2026-11-30T12:00:00+10:00')).toBe(true)
  })
  it('uses the Guam day before UTC midnight', () => {
    expect(matchesGuamWindow('2027-01-30T18:00:00+10:00', 'tonight', '2027-01-29T22:30:00Z')).toBe(true)
    expect(matchesGuamWindow('2027-01-29T18:00:00+10:00', 'tonight', '2027-01-29T22:30:00Z')).toBe(false)
  })
})
