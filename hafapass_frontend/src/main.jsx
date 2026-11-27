import '@fontsource-variable/plus-jakarta-sans'
import '@fontsource-variable/plus-jakarta-sans/wght-italic.css'
import '@fontsource-variable/space-grotesk'
import './i18n'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { createBrowserRouter, RouterProvider } from 'react-router-dom'
import DraftNavigationProvider from './components/DraftNavigationProvider'
import { PostHogPageView, PostHogProvider } from './components/PostHogProvider'
import ReleaseUpdateCoordinator from './components/ReleaseUpdateCoordinator'
import { HelmetProvider } from 'react-helmet-async'
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

async function installDemoStaff() {
  // Preview-only fictional staff sign-in; the literal check lets Rollup drop it.
  if (import.meta.env.VITE_HAFAPASS_DEMO_DATA === '1') (await import('./demo/staff/session')).installDemoStaffSession()
}

removeLegacyPrivateCaches().catch(() => {}).then(installDemoStaff).catch(() => {}).finally(() => {
  const router = createBrowserRouter([{ path: '*', element: <Sentry.ErrorBoundary fallback={({ error, resetError }) => <ErrorFallback error={error} resetError={resetError} />}>
    <DraftNavigationProvider><PostHogPageView /><ReleaseUpdateCoordinator /><ServiceCheck /></DraftNavigationProvider>
  </Sentry.ErrorBoundary> }])
  createRoot(document.getElementById('root')).render(
    <StrictMode>
      {/* Motion on buyer routes uses CSS transitions and usePrefersReducedMotion,
          keeping the critical path free of JS motion libraries. */}
      <HelmetProvider>
        <PostHogProvider>
          <RouterProvider router={router} />
        </PostHogProvider>
      </HelmetProvider>
    </StrictMode>,
  )
})
