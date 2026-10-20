import { describe, expect, it } from 'vitest'
import { eventLinkFormatError, eventLinkUrl, normalizeEventLinkInput } from './eventLink'
import { PUBLIC_WEB_URL } from './site'

describe('event link helpers', () => {
  it('builds the public URL from the configured site URL', () => {
    expect(eventLinkUrl('reef-night')).toBe(`${PUBLIC_WEB_URL}/events/reef-night`)
  })

  it('lowercases and hyphenates while typing', () => {
    expect(normalizeEventLinkInput('Summer Jam_2026 ')).toBe('summer-jam-2026-')
  })

  it('explains format problems', () => {
    expect(eventLinkFormatError('')).toBe('Enter a link name')
    expect(eventLinkFormatError('ab')).toBe('Use 3 to 80 characters')
    expect(eventLinkFormatError('a'.repeat(81))).toBe('Use 3 to 80 characters')
    expect(eventLinkFormatError('reef--night')).toMatch(/single hyphens/)
    expect(eventLinkFormatError('reef-night-')).toMatch(/single hyphens/)
    expect(eventLinkFormatError('café-night')).toMatch(/lowercase letters/)
    expect(eventLinkFormatError('reef-night-2026')).toBeNull()
  })
})
