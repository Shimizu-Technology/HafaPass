import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'
import { sentryVitePlugin } from '@sentry/vite-plugin'
import runtimeCaching from './src/config/pwaRuntimeCaching.js'
import { execFileSync } from 'node:child_process'
import { releaseMetadataPlugin, resolveRevision } from './config/releaseMetadata.js'

let gitRevision = null
try { gitRevision = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim() } catch { /* Source archives may have no Git metadata. */ }
const applicationRevision = resolveRevision(process.env, gitRevision)

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
  define: { 'import.meta.env.VITE_SENTRY_RELEASE': JSON.stringify(applicationRevision || '') },
  plugins: [
    react(),
    releaseMetadataPlugin(applicationRevision),
    VitePWA({
      registerType: 'autoUpdate',
      // Use the existing manifest.json in public/ — don't generate a new one
      manifest: false,
      workbox: {
        // Precache app shell assets
        globPatterns: ['**/*.{js,css,html,ico,png,svg,woff,woff2}'],
        // Runtime caching strategies
        runtimeCaching,
        // Don't cache POST, auth, admin, or organizer endpoints
        navigateFallback: '/index.html',
        navigateFallbackDenylist: [/^\/api/, /^\/robots\.txt$/, /^\/sitemap\.xml$/],
      },
    }),
    hasSentryUploadConfig && sentryVitePlugin({
      authToken: process.env.SENTRY_AUTH_TOKEN,
      org: process.env.SENTRY_ORG,
      project: process.env.SENTRY_PROJECT,
      release: { name: applicationRevision || undefined },
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
    // Bound jsdom/crypto contention on machines running parallel project sessions.
    maxWorkers: 2,
    environment: 'jsdom',
    globals: true,
    include: ['src/**/*.test.{js,jsx}'],
    setupFiles: './src/test/setup.js',
    css: true,
  },
})
