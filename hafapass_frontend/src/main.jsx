import '@fontsource-variable/plus-jakarta-sans'
import '@fontsource-variable/plus-jakarta-sans/wght-italic.css'
import '@fontsource-variable/space-grotesk'
import './i18n'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { createBrowserRouter, RouterProvider } from 'react-router-dom'
import DraftNavigationProvider from './components/DraftNavigationProvider'
import { HelmetProvider } from 'react-helmet-async'
import { MotionConfig } from 'framer-motion'
import './index.css'
import ServiceCheck from './ServiceCheck.jsx'
import { initializeMonitoring, Sentry } from './monitoring'
import ErrorFallback from './components/ErrorFallback'
import { initializeInstallationOffers } from './utils/installationOffers'

initializeInstallationOffers()
initializeMonitoring()

async function removeLegacyPrivateCaches() {
  if (!('caches' in window)) return
  await Promise.all(['tickets', 'my-tickets'].map(cacheName => window.caches.delete(cacheName)))
}

removeLegacyPrivateCaches().finally(() => {
  const router = createBrowserRouter([{ path: '*', element: <Sentry.ErrorBoundary fallback={({ error, resetError }) => <ErrorFallback error={error} resetError={resetError} />}>
    <DraftNavigationProvider><ServiceCheck /></DraftNavigationProvider>
  </Sentry.ErrorBoundary> }])
  createRoot(document.getElementById('root')).render(
    <StrictMode>
      {/* JS animations follow the visitor's reduced-motion preference, matching the CSS fallback. */}
      <MotionConfig reducedMotion="user">
        <HelmetProvider>
          <RouterProvider router={router} />
        </HelmetProvider>
      </MotionConfig>
    </StrictMode>,
  )
})
