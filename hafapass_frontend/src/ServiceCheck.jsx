import { lazy, Suspense, useEffect, useState } from 'react'
import { useLocation } from 'react-router-dom'
import ClerkProviderWrapper from './components/ClerkProviderWrapper'
import App from './App'
import { useBackendAvailability } from './hooks/useBackendAvailability'
import PrivatePreviewPage from './pages/PrivatePreviewPage'
import EnvironmentBanner from './components/EnvironmentBanner'
import { loadAuthorizedScanner } from './utils/admissionStore'
import { currentScannerOwner } from './utils/scannerAccountBinding'

const API_BASE_URL = (import.meta.env.VITE_API_URL || 'http://localhost:3000/api/v1').replace(/\/$/, '')
const HEALTH_URL = `${API_BASE_URL}/health`
const ScannerPage = lazy(() => import('./pages/dashboard/ScannerPage'))

// Fast checks never flash a loading screen; slow ones get a quiet light gate.
export const GATE_DELAY_MS = 400
// A successful check is remembered for the browser session so reloads render
// immediately while the same health check re-validates in the background.
export const HEALTH_CACHE_KEY = 'hafapass_services_ok_at'
export const HEALTH_CACHE_TTL_MS = 5 * 60_000

function readRecentSuccess() {
  try {
    const checkedAt = Number(window.sessionStorage.getItem(HEALTH_CACHE_KEY))
    return checkedAt > 0 && Date.now() - checkedAt < HEALTH_CACHE_TTL_MS
  } catch { return false }
}

function rememberHealth(available) {
  try {
    if (available) window.sessionStorage.setItem(HEALTH_CACHE_KEY, String(Date.now()))
    else window.sessionStorage.removeItem(HEALTH_CACHE_KEY)
  } catch { /* Unavailable storage only disables the fast path. */ }
}

function ServiceGate() {
  const [visible, setVisible] = useState(false)
  useEffect(() => {
    const timer = window.setTimeout(() => setVisible(true), GATE_DELAY_MS)
    return () => window.clearTimeout(timer)
  }, [])
  if (!visible) return <main className="min-h-screen bg-neutral-50" aria-busy="true" />
  return (
    <main className="flex min-h-screen items-center justify-center bg-neutral-50 px-6 text-center" role="status">
      <div>
        <div aria-hidden="true" className="mx-auto h-9 w-9 rounded-full border-4 border-brand-100 border-t-brand-500 motion-safe:animate-spin" />
        <p className="mt-4 font-semibold text-neutral-700">Checking HåfaPass services…</p>
      </div>
    </main>
  )
}

export default function ServiceCheck() {
  const { status: checkedStatus, retry } = useBackendAvailability(HEALTH_URL)
  // Read once per mount: a failed check clears it, so retries show the gate again.
  const [recentSuccess, setRecentSuccess] = useState(readRecentSuccess)
  const status = checkedStatus === 'checking' && recentSuccess ? 'available' : checkedStatus
  useEffect(() => {
    if (checkedStatus === 'checking') return
    rememberHealth(checkedStatus === 'available')
    if (checkedStatus === 'unavailable') setRecentSuccess(false)
  }, [checkedStatus])
  const location = useLocation()
  const [cachedScanner, setCachedScanner] = useState(null)
  const scannerRoute = JSON.stringify([location.key, location.pathname, location.search])

  useEffect(() => {
    let current = true
    const owner = currentScannerOwner()
    if (location.pathname !== '/dashboard/scanner') { setCachedScanner(null); return }
    const requestedEventId = new URLSearchParams(location.search).get('event')
    let eventId = requestedEventId
    try { eventId ??= window.localStorage.getItem('hafapass_scanner_event_id') } catch { /* Unavailable storage cannot authorize a fallback. */ }
    setCachedScanner(null)
    if (!eventId) return
    loadAuthorizedScanner(eventId).then(scanner => {
      if (current && owner && owner === currentScannerOwner() && scanner && Number(scanner.manifest?.payload?.event?.id) === Number(eventId)) {
        setCachedScanner({ scanner, eventId, route: scannerRoute, owner })
      }
    }).catch(() => { if (current) setCachedScanner(null) })
    return () => { current = false }
  }, [location.pathname, location.search, scannerRoute, status])

  // Previously authorized door access must survive an API or authentication-service outage.
  const cachedDoor = location.pathname === '/dashboard/scanner' && cachedScanner?.route === scannerRoute ? <main className="min-h-screen bg-neutral-50">
      <EnvironmentBanner offlineOnly />
      <div className="border-b border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-950" role="status">
        Using this device’s saved event access. Saved scans stay on this device. When services return, reload to reconnect.
        <button type="button" className="ml-3 inline-flex min-h-11 items-center font-semibold underline" onClick={() => window.location.reload()}>Reload to reconnect</button>
      </div>
      <Suspense fallback={<p className="px-4 py-8" role="status">Opening the saved scanner…</p>}><ScannerPage offlineOnly offlineEventId={cachedScanner.eventId} /></Suspense>
    </main> : null
  const renderServices = ({ scannerOwner }) => {
    if (cachedDoor && cachedScanner.owner === scannerOwner && status !== 'available') return cachedDoor
    if (status === 'checking') return <ServiceGate />
    if (status === 'unavailable') return <PrivatePreviewPage onRetry={retry} />
    return <App />
  }
  // Health transitions must not unmount the observer of definitive Clerk
  // sign-out/account changes, including while the saved scanner is open.
  return <ClerkProviderWrapper loadingFallback={cachedScanner?.owner === currentScannerOwner() ? cachedDoor : null} loadingFallbackOwner={cachedScanner?.owner}>{renderServices}</ClerkProviderWrapper>
}
