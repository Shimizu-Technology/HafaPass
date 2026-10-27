import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'
import { sentryVitePlugin } from '@sentry/vite-plugin'
import { offlinePrecache } from './config/pwaPrecache.js'
import { execFileSync } from 'node:child_process'
import { releaseMetadataPlugin, resolveRevision } from './config/releaseMetadata.js'
import { publicSitePlugin } from './config/publicSite.js'

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
export default defineConfig(({ mode }) => {
  // Domains are deploy configuration: VITE_PUBLIC_WEB_URL and VITE_API_URL.
  const env = loadEnv(mode, process.cwd(), 'VITE_')
  const precache = offlinePrecache()
  return {
    define: { 'import.meta.env.VITE_SENTRY_RELEASE': JSON.stringify(applicationRevision || '') },
    plugins: [
      react(),
      releaseMetadataPlugin(applicationRevision),
      publicSitePlugin(env.VITE_PUBLIC_WEB_URL),
      precache.plugin,
      VitePWA({
        strategies: 'injectManifest',
        srcDir: 'src',
        filename: 'sw.js',
        registerType: 'autoUpdate',
        // ReleaseUpdateCoordinator owns registration and the safe reload policy.
        injectRegister: 'auto',
        // Use the existing manifest.json in public/ — don't generate a new one
        manifest: false,
        injectManifest: {
          globPatterns: ['**/*.{js,css,html,ico,png,svg,woff,woff2}'],
          manifestTransforms: [precache.manifestTransform],
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
  }
})
