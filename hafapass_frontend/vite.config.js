import { defineConfig, loadEnv } from 'vite'
import { fileURLToPath } from 'node:url'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'
import { sentryVitePlugin } from '@sentry/vite-plugin'
import { offlinePrecache } from './config/pwaPrecache.js'
import { execFileSync } from 'node:child_process'
import { releaseMetadataPlugin, resolveRevision } from './config/releaseMetadata.js'
import { headerThemePlugin } from './config/headerTheme.js'
import { fontPreloadPlugin } from './config/fontPreload.js'
import { publicSitePlugin } from './config/publicSite.js'

let gitRevision = null
try { gitRevision = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim() } catch { /* Source archives may have no Git metadata. */ }
const applicationRevision = resolveRevision(process.env, gitRevision)

const hasSentryUploadConfig = Boolean(
  process.env.SENTRY_AUTH_TOKEN && process.env.SENTRY_ORG && process.env.SENTRY_PROJECT,
)

const manualChunkGroups = {
  analytics: ['posthog-js'],
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
export default defineConfig(({ mode, command }) => {
  // Domains are deploy configuration: VITE_PUBLIC_WEB_URL and VITE_API_URL.
  const env = loadEnv(mode, process.cwd(), 'VITE_')
  if (env.VITE_HAFAPASS_DEMO_DATA === '1' && (process.env.CONTEXT === 'production' || (command === 'build' && process.env.CONTEXT !== 'deploy-preview'))) {
    throw new Error('Demo data can only be built in the deploy-preview context; production is forbidden')
  }
  const precache = offlinePrecache()
  return {
    // Demo builds replace the provider at the module boundary so Stripe's eager
    // script loader never runs. Flag-off retains the original provider/imports.
    resolve: { alias: env.VITE_HAFAPASS_DEMO_DATA === '1' ? [{
      find: /(?:\.\/|\.\.\/components\/)StripeProvider$/,
      replacement: fileURLToPath(new URL('./src/demo/DisabledStripeProvider.jsx', import.meta.url)),
    }] : [] },
    define: { 'import.meta.env.VITE_SENTRY_RELEASE': JSON.stringify(applicationRevision || '') },
    plugins: [
      react(),
      headerThemePlugin(),
      fontPreloadPlugin(),
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
