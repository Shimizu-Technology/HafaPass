import { describe, expect, it } from 'vitest'
import buildRuntimeCaching, { eventsListPattern } from './pwaRuntimeCaching'

const API_URL = 'https://api.tickets.example.test/api/v1'
const runtimeCaching = buildRuntimeCaching(`${API_URL}/`)
const routeFor = url => runtimeCaching.find(route => route.urlPattern.test(url))

describe('public discovery network policy', () => {
  it.each([
    `${API_URL}/events`,
    `${API_URL}/events?page=1&per_page=12`,
    `${API_URL}/events?category=music&price=under_25`,
  ])('uses the network without a cache response or offline fallback for %s', url => {
    const route = routeFor(url)
    expect(route).toEqual(expect.objectContaining({ handler: 'NetworkOnly' }))
    expect(route.options).toBeUndefined()
    expect(runtimeCaching.some(candidate => candidate.options?.cacheName === 'events-list')).toBe(false)
  })

  it.each([
    `${API_URL}/events/concert`,
    `${API_URL}/orders`,
    `${API_URL}/organizer/events`,
    `${API_URL}/admin/events`,
  ])('leaves detail, checkout and private JSON requests outside runtime caches: %s', url => {
    expect(routeFor(url)).toBeUndefined()
  })

  it('derives the API matcher from configuration instead of a hardcoded host', () => {
    expect(eventsListPattern(API_URL).test('https://api.tickets.example.test/api/v1/events')).toBe(true)
    expect(eventsListPattern(API_URL).test('https://apiXtickets.example.test/api/v1/events')).toBe(false)
    expect(eventsListPattern(API_URL).test('https://other.example.test/api/v1/events')).toBe(false)
    expect(eventsListPattern().test('http://localhost:3000/api/v1/events')).toBe(true)
  })

  it('retains the existing image caching policy', () => {
    expect(routeFor('https://images.example.invalid/event-poster.webp')).toEqual(expect.objectContaining({
      handler: 'CacheFirst', options: { cacheName: 'images', expiration: { maxEntries: 100, maxAgeSeconds: 60 * 60 * 24 * 30 } },
    }))
  })
})
