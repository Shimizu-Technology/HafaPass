import process from 'node:process'
import { mergeConfig } from 'vite'
import { VitePWA } from 'vite-plugin-pwa'
import applicationConfig from '../vite.config.js'
import buildRuntimeCaching from '../src/config/pwaRuntimeCaching.js'

// The marker exists only in test builds; the application's design is untouched.
export default env => {
  const config = applicationConfig(env)
  if (process.env.PWA_TEST_LEGACY_SW === '1') {
    config.plugins = config.plugins.flat().filter(plugin => !plugin?.name?.startsWith('vite-plugin-pwa'))
    config.plugins.push(...VitePWA({
      registerType: 'autoUpdate', injectRegister: 'auto', manifest: false,
      workbox: {
        globPatterns: ['**/*.{js,css,html,ico,png,svg,woff,woff2}'],
        runtimeCaching: buildRuntimeCaching(),
        navigateFallback: '/index.html',
        navigateFallbackDenylist: [/^\/api/, /^\/robots\.txt$/, /^\/sitemap\.xml$/],
      },
    }))
  }
  return mergeConfig(config, {
    plugins: [{
      name: 'visible-deploy-test-marker',
      transformIndexHtml: () => [{ tag: 'p', attrs: { id: 'deploy-marker' }, children: `Build ${process.env.PWA_TEST_MARKER}`, injectTo: 'body' }],
    }, {
      // The production auth gate correctly rejects an unconfigured Clerk key.
      // Authenticate the synthetic operator only in this isolated fixture build.
      name: 'synthetic-scanner-authentication',
      enforce: 'pre',
      transform(_code, id) {
        if (id.endsWith('/components/ProtectedRoute.jsx')) return 'export default function ProtectedRoute({ children }) { return children }'
      },
    }],
  })
}
