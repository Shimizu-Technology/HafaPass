import { describe, expect, it } from 'vitest'
import runtimeCaching from './pwaRuntimeCaching'

const routeFor = url => runtimeCaching.find(route => route.urlPattern.test(url))

describe('public discovery network policy', () => {
  it.each([
    'https://hafapass-api.onrender.com/api/v1/events',
    'https://hafapass-api.onrender.com/api/v1/events?page=1&per_page=12',
    'https://hafapass-api.onrender.com/api/v1/events?category=music&price=under_25',
  ])('uses the network without a cache response or offline fallback for %s', url => {
    const route = routeFor(url)
    expect(route).toEqual(expect.objectContaining({ handler: 'NetworkOnly' }))
    expect(route.options).toBeUndefined()
    expect(runtimeCaching.some(candidate => candidate.options?.cacheName === 'events-list')).toBe(false)
  })

  it.each([
    'https://hafapass-api.onrender.com/api/v1/events/concert',
    'https://hafapass-api.onrender.com/api/v1/orders',
    'https://hafapass-api.onrender.com/api/v1/organizer/events',
    'https://hafapass-api.onrender.com/api/v1/admin/events',
  ])('leaves detail, checkout and private JSON requests outside runtime caches: %s', url => {
    expect(routeFor(url)).toBeUndefined()
  })

  it('retains the existing image caching policy', () => {
    expect(routeFor('https://images.example.invalid/event-poster.webp')).toEqual(expect.objectContaining({
      handler: 'CacheFirst', options: { cacheName: 'images', expiration: { maxEntries: 100, maxAgeSeconds: 60 * 60 * 24 * 30 } },
    }))
  })
})
