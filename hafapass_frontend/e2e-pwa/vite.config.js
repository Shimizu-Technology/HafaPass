import process from 'node:process'
import { mergeConfig } from 'vite'
import applicationConfig from '../vite.config.js'

// The marker exists only in test builds; the application's design is untouched.
export default env => mergeConfig(applicationConfig(env), {
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
