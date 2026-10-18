export default [
  {
    // Listing snapshots include current sales eligibility, stock and pricing.
    // A service-worker cache must not turn a published change into stale discovery.
    urlPattern: /^https:\/\/hafapass-api\.onrender\.com\/api\/v1\/events(?:\?.*)?$/,
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
