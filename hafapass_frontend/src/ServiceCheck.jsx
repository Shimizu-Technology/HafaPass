import { lazy, Suspense, useEffect, useState } from 'react'
import { useLocation } from 'react-router-dom'
import ClerkProviderWrapper from './components/ClerkProviderWrapper'
import App from './App'
import { useBackendAvailability } from './hooks/useBackendAvailability'
import PrivatePreviewPage from './pages/PrivatePreviewPage'
import EnvironmentBanner from './components/EnvironmentBanner'
import { loadAuthorizedScanner } from './utils/admissionStore'

const API_BASE_URL = (import.meta.env.VITE_API_URL || 'http://localhost:3000/api/v1').replace(/\/$/, '')
const HEALTH_URL = `${API_BASE_URL}/health`
const ScannerPage = lazy(() => import('./pages/dashboard/ScannerPage'))

export default function ServiceCheck() {
  const { status, retry } = useBackendAvailability(HEALTH_URL)
  const location = useLocation()
  const [cachedScanner, setCachedScanner] = useState(null)

  useEffect(() => {
    let current = true
    if (location.pathname !== '/dashboard/scanner') { setCachedScanner(null); return }
    const eventId = window.localStorage.getItem('hafapass_scanner_event_id')
    loadAuthorizedScanner(eventId).then(scanner => { if (current) setCachedScanner(scanner) }).catch(() => { if (current) setCachedScanner(null) })
    return () => { current = false }
  }, [location.pathname])

  // Previously authorized door access must survive an API or authentication-service outage.
  if (location.pathname === '/dashboard/scanner' && cachedScanner && status !== 'available') {
    return <main className="min-h-screen bg-neutral-50">
      <EnvironmentBanner offlineOnly />
      <div className="border-b border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-950" role="status">
        Using this device’s saved event access. Scans stay on this device until services reconnect.
        <button className="ml-3 min-h-11 font-semibold underline" onClick={retry}>Check connection</button>
      </div>
      <Suspense fallback={<p className="px-4 py-8" role="status">Opening the saved scanner…</p>}><ScannerPage offlineOnly /></Suspense>
    </main>
  }

  if (status === 'checking') {
    return (
      <main className="flex min-h-screen items-center justify-center bg-neutral-950 px-6 text-center" role="status">
        <div>
          <div className="mx-auto h-10 w-10 animate-spin rounded-full border-4 border-white/10 border-t-brand-400" />
          <p className="mt-4 font-semibold text-white/70">Checking HåfaPass services…</p>
        </div>
      </main>
    )
  }

  if (status === 'unavailable') return <PrivatePreviewPage onRetry={retry} />
  return <ClerkProviderWrapper><App /></ClerkProviderWrapper>
}
