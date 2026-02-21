import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'

// https://vite.dev/config/
export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      // Use the existing manifest.json in public/ — don't generate a new one
      manifest: false,
      workbox: {
        // Precache app shell assets
        globPatterns: ['**/*.{js,css,html,ico,png,svg,woff,woff2}'],
        // Runtime caching strategies
        runtimeCaching: [
          {
            // Public events listing
            urlPattern: /^https:\/\/hafapass-api\.onrender\.com\/api\/v1\/events$/,
            handler: 'StaleWhileRevalidate',
            options: {
              cacheName: 'events-list',
              expiration: { maxEntries: 10, maxAgeSeconds: 60 * 60 * 24 }, // 1 day
            },
          },
          {
            // Individual ticket by QR code — critical for offline door access
            urlPattern: /^https:\/\/hafapass-api\.onrender\.com\/api\/v1\/tickets\/[^/]+$/,
            handler: 'CacheFirst',
            options: {
              cacheName: 'tickets',
              expiration: { maxEntries: 50, maxAgeSeconds: 60 * 60 * 24 * 7 }, // 7 days
            },
          },
          {
            // My tickets listing
            urlPattern: /^https:\/\/hafapass-api\.onrender\.com\/api\/v1\/me\/tickets$/,
            handler: 'StaleWhileRevalidate',
            options: {
              cacheName: 'my-tickets',
              expiration: { maxEntries: 10, maxAgeSeconds: 60 * 60 * 24 }, // 1 day
            },
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
        ],
        // Don't cache POST, auth, admin, or organizer endpoints
        navigateFallback: '/index.html',
        navigateFallbackDenylist: [/^\/api/, /^\/robots\.txt$/, /^\/sitemap\.xml$/],
      },
    }),
  ],
})
