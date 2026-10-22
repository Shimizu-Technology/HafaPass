// Same default as src/api/client.js so the matcher always follows the API the app calls.
export const DEFAULT_API_URL = 'http://localhost:3000/api/v1'

const escapeRegExp = value => value.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&')

// The API host is configuration (VITE_API_URL), never a hardcoded domain.
export function eventsListPattern(apiUrl = DEFAULT_API_URL) {
  const base = String(apiUrl || DEFAULT_API_URL).trim().replace(/\/+$/, '')
  return new RegExp(`^${escapeRegExp(base)}\\/events(?:\\?.*)?$`)
}

export default function buildRuntimeCaching(apiUrl) {
  return [
    {
      // Listing snapshots include current sales eligibility, stock and pricing.
      // A service-worker cache must not turn a published change into stale discovery.
      urlPattern: eventsListPattern(apiUrl),
      handler: 'NetworkOnly',
    },
    {
      // Images — CacheFirst with 30 day expiry
      urlPattern: /\.(?:png|jpg|jpeg|svg|gif|webp)$/,
      handler: 'CacheFirst',
      options: {
        cacheName: 'images',
        expiration: { maxEntries: 100, maxAgeSeconds: 60 * 60 * 24 * 30 }, // 30 days
      },
    },
    {
      // Google Fonts stylesheets
      urlPattern: /^https:\/\/fonts\.googleapis\.com\/.*/,
      handler: 'StaleWhileRevalidate',
      options: {
        cacheName: 'google-fonts-stylesheets',
      },
    },
    {
      // Google Fonts webfont files
      urlPattern: /^https:\/\/fonts\.gstatic\.com\/.*/,
      handler: 'CacheFirst',
      options: {
        cacheName: 'google-fonts-webfonts',
        expiration: { maxEntries: 20, maxAgeSeconds: 60 * 60 * 24 * 365 }, // 1 year
      },
    },
  ]
}
