import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'
import { sentryVitePlugin } from '@sentry/vite-plugin'

const hasSentryUploadConfig = Boolean(
  process.env.SENTRY_AUTH_TOKEN && process.env.SENTRY_ORG && process.env.SENTRY_PROJECT,
)

const manualChunkGroups = {
  clerk: ['@clerk/clerk-react'],
  monitoring: ['@sentry/react'],
  payments: ['@stripe/react-stripe-js', '@stripe/stripe-js'],
  react: ['react', 'react-dom', 'react-router-dom'],
  translations: ['i18next', 'i18next-browser-languagedetector', 'react-i18next'],
}

function manualChunks(id) {
  if (!id.includes('/node_modules/')) return undefined

  return Object.entries(manualChunkGroups).find(([, packages]) => (
    packages.some((packageName) => id.includes(`/node_modules/${packageName}/`))
  ))?.[0]
}

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
    hasSentryUploadConfig && sentryVitePlugin({
      authToken: process.env.SENTRY_AUTH_TOKEN,
      org: process.env.SENTRY_ORG,
      project: process.env.SENTRY_PROJECT,
      release: { name: process.env.VITE_SENTRY_RELEASE || process.env.COMMIT_REF },
      sourcemaps: { filesToDeleteAfterUpload: ['./dist/**/*.map'] },
    }),
  ],
  build: {
    sourcemap: hasSentryUploadConfig,
    rollupOptions: {
      output: {
        manualChunks,
      },
    },
  },
  test: {
    environment: 'jsdom',
    globals: true,
    include: ['src/**/*.test.{js,jsx}'],
    setupFiles: './src/test/setup.js',
    css: true,
  },
})
