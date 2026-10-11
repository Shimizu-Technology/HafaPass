import { describe, expect, it } from 'vitest'
import { eventBrowseReturn } from './browseReturn'
describe('public browse return', () => {
  it('retains current filters and pagination', () => {
    expect(eventBrowseReturn('/events?search=music&category=concert&page=2')).toBe('/events?search=music&category=concert&page=2')
  })
  it.each([undefined, '//evil.invalid/events', 'https://evil.invalid/events', '/dashboard/events', '/events/paid', '/events/../dashboard', '/events\\evil.invalid'])('rejects unrelated or external target %s', target => {
    expect(eventBrowseReturn(target)).toBe('/events')
  })
})
