import useOperationalListing from '../../hooks/useOperationalListing'
import OperationalSearch from '../../components/OperationalSearch'
import OperationalPagination from '../../components/OperationalPagination'
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react'
import {
  AlertTriangle, Camera, CheckCircle2, CloudOff, Download, Loader2, RefreshCw,
  RotateCcw, Search, ShieldCheck, Smartphone, StopCircle, XCircle,
} from 'lucide-react'
import { Link, useLocation, useSearchParams } from 'react-router-dom'
import apiClient, { getApiAuthContext, subscribeApiAuthContext } from '../../api/client'
import { DEFAULT_EVENT_TIME_ZONE, formatEventDateTime } from '../../utils/eventTime'
import {
  applySyncResults, captureAdmissionAccessContext, captureOrganizationAdmissionContexts, currentScannerOwner, clearEventAdmissionData, loadAuthorizedScanner, loadPendingDeviceIdentity, localScanState, queueAdmission,
  queuedActions, queueReversal, loadDevice, invalidateManifestAccess, saveDevice, saveVerifiedManifest, sha256Hex, purgeExpiredAdmissionAccess,
} from '../../utils/admissionStore'
import { scannerBindingRevision, scannerWithdrawalRevision, subscribeScannerBinding } from '../../utils/scannerAccountBinding'

const LOOKUP_STATUS_LABELS = {
  issued: 'Issued', checked_in: 'Already checked in', cancelled: 'Cancelled',
  transferred: 'Transferred', refund_pending: 'Refund pending', payment_blocked: 'Payment blocked',
}

const browserIdentifier = () => {
  const key = 'hafapass_scanner_browser_id'
  let identifier = window.localStorage.getItem(key)
  if (!identifier) {
    identifier = `browser-${crypto.randomUUID()}`
    window.localStorage.setItem(key, identifier)
  }
  return identifier
}

const credentialValue = raw => {
  const value = raw.trim()
  try {
    const parsed = new URL(value)
    return parsed.pathname.split('/').filter(Boolean).at(-1) || value
  } catch {
    return value
  }
}

const refusalStorageKey = (owner, eventId) => `hafapass:scanner-refusal:v1:${encodeURIComponent(owner || 'guest')}:${eventId}`
const refusalStores = () => [() => window.localStorage, () => window.sessionStorage]
function hasStoredRefusal(owner, eventId) {
  return refusalStores().some(storage => {
    try { return storage().getItem(refusalStorageKey(owner, eventId)) !== null }
    catch { return true } // Unreadable refusal evidence cannot authorize offline entry.
  })
}
function saveStoredRefusal(owner, eventId, token) {
  let saved = false
  for (const storage of refusalStores()) {
    try { storage().setItem(refusalStorageKey(owner, eventId), token); saved = true } catch { /* Try the other storage. */ }
  }
  if (!saved) {
    // Quota failures may still permit deletion. Remove only this event's restore
    // pointer so an offline remount cannot rediscover its unquarantined cache.
    try {
      if (window.localStorage.getItem('hafapass_scanner_event_id') === String(eventId)) window.localStorage.removeItem('hafapass_scanner_event_id')
    } catch { /* Unreadable storage is blocked by hasStoredRefusal. */ }
  }
  return saved
}
function storedRefusalTokens(owner, eventId) {
  const tokens = []
  for (const storage of refusalStores()) {
    try {
      const token = storage().getItem(refusalStorageKey(owner, eventId))
      if (token !== null) tokens.push(token)
    } catch { /* hasStoredRefusal keeps unreadable storage blocked. */ }
  }
  return tokens
}
function clearStoredRefusal(owner, eventId, tokens) {
  const allowed = new Set(Array.isArray(tokens) ? tokens : [tokens])
  for (const storage of refusalStores()) {
    try {
      const key = refusalStorageKey(owner, eventId)
      if (allowed.has(storage().getItem(key))) storage().removeItem(key)
    } catch { /* Keep entry paused if refusal evidence cannot be cleared. */ }
  }
  return !hasStoredRefusal(owner, eventId)
}
function canPersistRefusal(owner, eventId) {
  // A readable but unwritable store cannot remember a later denial. Probe an
  // exclusively owned key; never replace or clear the actual refusal key.
  const token = crypto.randomUUID()
  const key = `${refusalStorageKey(owner, eventId)}:probe:${token}`
  let available = false
  for (const storage of refusalStores()) {
    let verified = false
    try {
      const target = storage()
      target.setItem(key, token)
      verified = target.getItem(key) === token
      if (target.getItem(key) === token) target.removeItem(key)
      verified = verified && target.getItem(key) === null
    } catch { verified = false /* Try the other store; unreadable stores remain quarantined. */ }
    available ||= verified
  }
  return available
}

const localDay = (value, timeZone) => {
  try { return new Intl.DateTimeFormat('en-CA', { timeZone: timeZone || DEFAULT_EVENT_TIME_ZONE, year: 'numeric', month: '2-digit', day: '2-digit' }).format(value) }
  catch { return new Intl.DateTimeFormat('en-CA', { timeZone: DEFAULT_EVENT_TIME_ZONE, year: 'numeric', month: '2-digit', day: '2-digit' }).format(value) }
}

// Only published events can issue scanner manifests, so drafts and other
// states are never chosen automatically. Prefer what is on today (live first,
// then later today, then earlier today), then the soonest upcoming event, then
// the most recent past one. Returns null when no published event is listed,
// leaving the selection empty rather than preparing a draft or cancelled event.
function defaultScannerEvent(events, now = Date.now()) {
  const ranked = events.filter(event => event.status === 'published').map(event => {
    const start = Date.parse(event.starts_at || '')
    const parsedEnd = Date.parse(event.ends_at || '')
    const end = Number.isFinite(parsedEnd) ? parsedEnd : start
    if (!Number.isFinite(start)) return { event, rank: [4, 0] }
    const today = localDay(now, event.timezone)
    const onToday = (start <= now && now < end) || localDay(start, event.timezone) === today || localDay(end, event.timezone) === today
    if (onToday) return { event, rank: end > now ? [0, start] : [1, -end] }
    return { event, rank: start > now ? [2, start] : [3, -end] }
  })
  ranked.sort((first, second) => first.rank[0] - second.rank[0] || first.rank[1] - second.rank[1])
  return ranked[0]?.event || null
}

// Bounded lookups through the same scan-scoped list: everything published that
// ended within the last day or is still to come (soonest first), and only if
// none exists, the latest published events. A failed or slow lookup falls back
// to the visible page after the deadline; it never blocks device preparation or
// widens event selection. Abandoning the page aborts it immediately.
const SCANNER_DEFAULT_LOOKUP_DEADLINE_MS = 4000

async function scannerDefaultCandidates(config, q) {
  const parent = config.signal
  if (parent?.aborted) throw new DOMException('Scanner context changed', 'AbortError')
  const controller = new AbortController()
  let timer
  let abandon
  const deadline = new Promise((resolve, reject) => {
    timer = window.setTimeout(() => { controller.abort(); resolve([]) }, SCANNER_DEFAULT_LOOKUP_DEADLINE_MS)
    abandon = () => { controller.abort(); reject(new DOMException('Scanner context changed', 'AbortError')) }
  })
  parent?.addEventListener('abort', abandon, { once: true })
  const lookup = async params => {
    const response = await apiClient.get('/organizer/events', { ...config, signal: controller.signal, params: { purpose: 'scan', status: 'published', q, ...params } })
    return (response.data.events || []).filter(event => event.permissions?.scan !== false)
  }
  const candidates = (async () => {
    const current = await lookup({ ends_after: new Date(Date.now() - 86_400_000).toISOString(), order: 'starts_at', per_page: 50 })
    return current.length ? current : await lookup({ order: '-starts_at', per_page: 20 })
  })()
  // Whichever promise loses the race must not surface as an unhandled rejection.
  candidates.catch(() => {})
  deadline.catch(() => {})
  try {
    return await Promise.race([candidates, deadline])
  } catch (lookupError) {
    if (parent?.aborted) throw lookupError
    return []
  } finally {
    window.clearTimeout(timer)
    parent?.removeEventListener('abort', abandon)
  }
}

function admissionAcknowledgement(current, receipt) {
  const result = receipt.result || receipt.status
  if (result === 'accepted') return { ...current, type: 'success', message: 'Admission confirmed', detail: 'The server confirmed this entry.' }
  if (receipt.reason_code === 'refund_pending') return { ...current, type: 'error', message: 'Refund pending — do not admit', detail: 'Entry is paused while this ticket’s refund is unresolved. Ask a door manager to check its current status.' }
  return { ...current, type: result === 'conflict' ? 'warning' : 'error', message: receipt.reason_code === 'already_admitted' ? 'Already admitted on another device' : 'Do not admit — scan rejected', detail: 'The server refused this entry. Ask a door manager to check the ticket and saved scan.' }
}

function ResultPanel({ result, className = '' }) {
  if (!result) return null
  const styles = {
    pending: ['bg-neutral-50 border-neutral-300 text-neutral-900', Loader2],
    success: ['bg-emerald-50 border-emerald-300 text-emerald-900', CheckCircle2],
    warning: ['bg-amber-50 border-amber-300 text-amber-900', AlertTriangle],
    error: ['bg-red-50 border-red-300 text-red-900', XCircle],
  }
  const [classes, Icon] = styles[result.type]
  return (
    <div className={`rounded-2xl border-2 p-5 ${classes} ${className}`} role="status" aria-live="assertive" aria-atomic="true">
      <div className="flex gap-3">
        <Icon aria-hidden="true" className="h-7 w-7 shrink-0" />
        <div className="min-w-0 break-words">
          <p className="text-lg font-bold">{result.message}</p>
          {result.detail && <p className="mt-1 text-sm">{result.detail}</p>}
          {result.ticket && (
            <p className="mt-2 text-sm font-medium">
              {result.ticket.attendee_name} · {result.ticket.ticket_type} · {result.ticket.code}
            </p>
          )}
          {result.latency != null && <details className="mt-3 text-xs">
            <summary className="flex min-h-11 cursor-pointer items-center font-medium">Scan details</summary>
            <p className="pb-2">Local response: {Math.round(result.latency)}ms</p>
          </details>}
        </div>
      </div>
    </div>
  )
}

export default function ScannerPage({ offlineOnly = false, offlineEventId = null }) {
  const bindingRevision = useSyncExternalStore(subscribeScannerBinding, scannerBindingRevision)
  const bindingOwnerRef = useRef(currentScannerOwner())
  const withdrawalRef = useRef(scannerWithdrawalRevision())
  const [searchParams, setSearchParams] = useSearchParams()
  const location = useLocation()
  const requestedEventId = searchParams.get('event')
  // Attendees page "Check in" hands over a ticket number (HP-T123). The scanner
  // only runs the lookup; staff still press Admit so the admission goes through
  // this device's signed manifest, offline queue and Undo like any other scan.
  const requestedLookup = searchParams.get('lookup')?.trim().slice(0, 80) || ''
  const routeScope = JSON.stringify([location.key, location.search, offlineOnly ? offlineEventId : null])
  const selectionVisitRef = useRef({ route: routeScope, generation: 0 })
  if (selectionVisitRef.current.route !== routeScope) {
    selectionVisitRef.current = { route: routeScope, generation: selectionVisitRef.current.generation + 1 }
  }
  const selectionVisit = selectionVisitRef.current.generation
  const [events, setEvents] = useState([])
  const listing = useOperationalListing(`scanner-events:${currentScannerOwner()}:${window.localStorage.getItem('hafapass_organization_id')}`)
  const [eventMeta, setEventMeta] = useState(null)
  const [resolvedEvent, setResolvedEvent] = useState(null)
  const [eventListError, setEventListError] = useState('')
  const [eventListLoading, setEventListLoading] = useState(false)
  const [eventListRetry, setEventListRetry] = useState(0)
  const [eventSelection, setEventSelection] = useState(null)
  const eventId = eventSelection?.route === routeScope && eventSelection?.visit === selectionVisit ? eventSelection.id : ''
  const setEventId = useCallback(id => setEventSelection({ route: routeScope, visit: selectionVisit, id: String(id) }), [routeScope, selectionVisit])
  const [device, setDevice] = useState(null)
  const [recoveryDevice, setRecoveryDevice] = useState(null)
  const [manifest, setManifest] = useState(null)
  const [dashboard, setDashboard] = useState(null)
  const [pendingCount, setPendingCount] = useState(0)
  const [online, setOnline] = useState(navigator.onLine && !offlineOnly)
  const [setupBusy, setSetupBusy] = useState(true)
  const [syncing, setSyncing] = useState(false)
  const [error, setError] = useState(null)
  const [scanResult, setScanResult] = useState(null)
  const [manualCode, setManualCode] = useState('')
  const [searchQuery, setSearchQuery] = useState(requestedLookup)
  const [searchResults, setSearchResults] = useState([])
  const [searching, setSearching] = useState(false)
  const [downloading, setDownloading] = useState(false)
  const [scanning, setScanning] = useState(false)
  const [cameraError, setCameraError] = useState(null)
  const [sessionCount, setSessionCount] = useState(0)

  const videoRef = useRef(null)
  const streamRef = useRef(null)
  const detectorTimerRef = useRef(null)
  const zxingControlsRef = useRef(null)
  const scanCooldownRef = useRef(false)
  const syncingRef = useRef(false)
  const setupGenerationRef = useRef(0)
  const mountedRef = useRef(false)
  const presentationRef = useRef(0)
  const resultContextRef = useRef(null)
  const eventIdRef = useRef(eventId)
  eventIdRef.current = eventId
  const processCredentialRef = useRef(null)
  const cameraGenerationRef = useRef(0)
  const currentManifestRef = useRef(manifest)
  currentManifestRef.current = manifest
  const visitRef = useRef(location.key)
  visitRef.current = location.key
  const searchRequestRef = useRef(null)
  const downloadRequestRef = useRef(null)
  const dashboardRequestRef = useRef(null)
  const eventListAccessRef = useRef(null)
  const directEventAccessRef = useRef(null)
  const privateReadGenerationRef = useRef(0)
  const refusedAccessRef = useRef(new Set())
  const routeScopeRef = useRef(null)
  routeScopeRef.current = JSON.stringify([routeScope, selectionVisit])

  useEffect(() => {
    const abortReads = () => {
      ++privateReadGenerationRef.current
      searchRequestRef.current?.abort()
      downloadRequestRef.current?.abort()
      dashboardRequestRef.current?.abort()
      eventListAccessRef.current?.abort()
      directEventAccessRef.current?.abort()
      setSearching(false)
      setDownloading(false)
    }
    abortReads()
    const unsubscribe = subscribeApiAuthContext(abortReads)
    return () => { unsubscribe(); abortReads() }
  }, [eventId, location.key])

  useEffect(() => {
    mountedRef.current = true
    return () => { mountedRef.current = false; setupGenerationRef.current += 1 }
  }, [])

  const ticketsByHash = useMemo(
    () => new Map((manifest?.payload?.tickets || []).map(ticket => [ticket.credential_hash, ticket])),
    [manifest],
  )
  const ticketsById = useMemo(
    () => new Map((manifest?.payload?.tickets || []).map(ticket => [Number(ticket.ticket_id), ticket])),
    [manifest],
  )

  const refreshPending = useCallback(async (selectedEventId, selectedDevice) => {
    if (!selectedEventId || !selectedDevice) return setPendingCount(0)
    const count = (await queuedActions(selectedEventId, selectedDevice.id)).length
    if (eventIdRef.current === String(selectedEventId)) setPendingCount(count)
  }, [])

  const stopCamera = useCallback(() => {
    cameraGenerationRef.current += 1
    if (detectorTimerRef.current) clearInterval(detectorTimerRef.current)
    detectorTimerRef.current = null
    zxingControlsRef.current?.stop()
    zxingControlsRef.current = null
    streamRef.current?.getTracks().forEach(track => track.stop())
    streamRef.current = null
    if (videoRef.current) videoRef.current.srcObject = null
    setScanning(false)
  }, [])

  const withdrawPresentation = useCallback(() => {
    ++setupGenerationRef.current
    ++presentationRef.current
    ++privateReadGenerationRef.current
    searchRequestRef.current?.abort()
    downloadRequestRef.current?.abort()
    dashboardRequestRef.current?.abort()
    eventListAccessRef.current?.abort()
    directEventAccessRef.current?.abort()
    currentManifestRef.current = null
    resultContextRef.current = null
    stopCamera()
    setEventSelection(null)
    setEvents([])
    setResolvedEvent(null)
    setDevice(null)
    setRecoveryDevice(null)
    setManifest(null)
    setDashboard(null)
    setScanResult(null)
    setManualCode('')
    setSearchQuery('')
    setSearchResults([])
    setPendingCount(0)
    setError(null)
    setSetupBusy(true)
  }, [stopCamera])

  useLayoutEffect(() => {
    // Withdraw private presentation before the next paint, keeping the journal.
    withdrawPresentation()
  }, [routeScope, selectionVisit, withdrawPresentation])

  useLayoutEffect(() => {
    const owner = currentScannerOwner()
    if (owner === bindingOwnerRef.current && withdrawalRef.current === scannerWithdrawalRevision()) return
    bindingOwnerRef.current = owner
    withdrawalRef.current = scannerWithdrawalRevision()
    withdrawPresentation()
    setSetupBusy(false)
    setError('Saved event access changed. Sign in and prepare this scanner again.')
  }, [bindingRevision, withdrawPresentation])

  const beginPrivateRead = useCallback((requestRef, selectedEventId) => {
    requestRef.current?.abort()
    const controller = new AbortController()
    requestRef.current = controller
    const owner = currentScannerOwner()
    const generation = setupGenerationRef.current
    const visit = visitRef.current
    const readGeneration = privateReadGenerationRef.current
    const authContext = getApiAuthContext()
    const organizationId = window.localStorage.getItem('hafapass_organization_id')
    const scopeCurrent = () => mountedRef.current && !controller.signal.aborted && requestRef.current === controller
      && owner === currentScannerOwner() && selectedEventId === eventIdRef.current
      && visit === visitRef.current
      && readGeneration === privateReadGenerationRef.current && authContext === getApiAuthContext()
      && organizationId === window.localStorage.getItem('hafapass_organization_id')
    const current = () => scopeCurrent() && generation === setupGenerationRef.current
    return { selectedEventId, current, scopeCurrent, controller, config: { signal: controller.signal, authContext, organizationId } }
  }, [])

  const handlePrivateReadError = useCallback(async (readError, request, context, fallback) => {
    if (!request.current() || readError.manifestContextChanged) return
    if ([401, 403].includes(readError.response?.status) && context) {
      const owner = currentScannerOwner()
      const refusedKey = JSON.stringify([owner, String(request.selectedEventId)])
      const token = crypto.randomUUID()
      const stored = saveStoredRefusal(owner, request.selectedEventId, token)
      refusedAccessRef.current.add(refusedKey)
      const deniedGeneration = ++setupGenerationRef.current
      const denialCurrent = () => request.scopeCurrent() && deniedGeneration === setupGenerationRef.current
      // Pause entry before yielding to IndexedDB. A late setup continuation or
      // camera callback must not admit during the refusal's storage transaction.
      ++presentationRef.current
      currentManifestRef.current = null
      stopCamera()
      for (const ref of [searchRequestRef, downloadRequestRef, dashboardRequestRef, eventListAccessRef, directEventAccessRef]) {
        if (ref.current !== request.controller) ref.current?.abort()
      }
      setDevice(null); setManifest(null); setRecoveryDevice(null); setDashboard(null)
      setSearchResults([]); setSearchQuery(''); setManualCode(''); setScanResult(null)
      setSearching(false); setDownloading(false); setSetupBusy(false)
      setError('Scanner access is being checked. Admission is paused; saved scans remain on this device.')
      let removed = false
      const message = readError.response?.data?.error || 'Scanner access was refused. Reload while connected to verify access. Saved scans remain on this device.'
      try { removed = await purgeExpiredAdmissionAccess(request.selectedEventId, { context: { ...context, isCurrent: denialCurrent } }) }
      catch {
        if (denialCurrent()) setError(stored
          ? 'Saved scanner access could not be removed. Stay connected and verify access before admitting more guests. Saved scans remain on this device.'
          : 'Saved scanner access could not be removed or locked. Stay online and ask the door manager for help. Do not reload this device offline.')
        return
      }
      // A peer renewal or a later visit owns its own access. An old refusal must
      // never erase that newer grant or its attendee records.
      if (!denialCurrent()) return
      if (!removed) {
        const renewed = await loadAuthorizedScanner(request.selectedEventId).catch(() => null)
        if (!denialCurrent()) return
        if (renewed && clearStoredRefusal(owner, request.selectedEventId, token)) {
          refusedAccessRef.current.delete(refusedKey)
          currentManifestRef.current = renewed.manifest
          setDevice(renewed.device); setManifest(renewed.manifest); setError(null)
          return
        }
      }
      setError(message)
      return
    }
    setError(readError.response?.data?.error || fallback)
  }, [stopCamera])

  const handleEventListRefusal = useCallback(async (readError, request, contexts) => {
    if (!request.current()) return
    const owner = currentScannerOwner()
    const generation = ++setupGenerationRef.current
    const denialCurrent = () => request.scopeCurrent() && generation === setupGenerationRef.current
    ++presentationRef.current
    currentManifestRef.current = null
    stopCamera()
    for (const ref of [searchRequestRef, downloadRequestRef, dashboardRequestRef, directEventAccessRef]) ref.current?.abort()
    setDevice(null); setManifest(null); setRecoveryDevice(null); setDashboard(null)
    setEvents([]); setResolvedEvent(null); setEventMeta(null)
    setSearchResults([]); setSearchQuery(''); setManualCode(''); setScanResult(null)
    setSearching(false); setDownloading(false); setSetupBusy(false)
    // Persist every refusal before the first storage yield. The journals and
    // their device identities remain available for authorized recovery.
    const refusals = contexts.map(context => {
      const token = crypto.randomUUID()
      refusedAccessRef.current.add(JSON.stringify([owner, String(context.eventId)]))
      saveStoredRefusal(owner, context.eventId, token)
      return { context, token }
    })
    setError(readError.response?.data?.error || 'Scanner access was refused. Sign in and verify your event assignments while connected. Saved scans remain on this device.')
    for (const { context, token } of refusals) {
      try {
        const removed = await purgeExpiredAdmissionAccess(context.eventId, { context: { ...context, isCurrent: denialCurrent } })
        if (!denialCurrent()) return
        if (!removed) {
          const renewed = await loadAuthorizedScanner(context.eventId).catch(() => null)
          if (!denialCurrent()) return
          if (renewed && clearStoredRefusal(owner, context.eventId, token)) {
            refusedAccessRef.current.delete(JSON.stringify([owner, String(context.eventId)]))
            if (String(context.eventId) === request.preparedEventId) {
              currentManifestRef.current = renewed.manifest
              setDevice(renewed.device); setManifest(renewed.manifest)
              setResolvedEvent(renewed.manifest.payload.event); setError(null)
            }
          }
        }
      } catch {
        if (denialCurrent()) setError('Saved scanner access could not be removed. Stay connected and verify access before admitting more guests. Saved scans remain on this device.')
      }
    }
  }, [stopCamera])

  const fetchDashboard = useCallback(async selectedEventId => {
    if (!selectedEventId || !online) return
    const request = beginPrivateRead(dashboardRequestRef, String(selectedEventId))
    let context
    try {
      context = await captureAdmissionAccessContext(request.selectedEventId, { isCurrent: request.current })
      if (!request.current()) return
      const response = await apiClient.get(`/organizer/events/${request.selectedEventId}/admissions`, request.config)
      if (request.current()) setDashboard(response.data)
    } catch (dashboardError) {
      await handlePrivateReadError(dashboardError, request, context, 'Door totals could not be loaded. Please retry while connected.')
      throw dashboardError
    }
  }, [online, beginPrivateRead, handlePrivateReadError])

  const downloadManifest = useCallback(async (selectedEventId, selectedDevice) => {
    const owner = currentScannerOwner()
    const generation = setupGenerationRef.current
    const current = () => mountedRef.current && owner === currentScannerOwner()
      && eventIdRef.current === String(selectedEventId) && generation === setupGenerationRef.current
    const context = await captureAdmissionAccessContext(selectedEventId, { isCurrent: current })
    let response
    try {
      response = await apiClient.get(`/organizer/events/${selectedEventId}/scanner_devices/${selectedDevice.id}/manifest`)
    } catch (manifestError) {
      if ([401, 403, 404, 410, 422].includes(manifestError.response?.status)) {
        const removed = await purgeExpiredAdmissionAccess(selectedEventId, { context })
        manifestError.scannerAccessRefused = true
        manifestError.scannerAccessPurged = removed && current()
        if (manifestError.scannerAccessPurged) { setDevice(null); setManifest(null); setRecoveryDevice(null) }
      }
      throw manifestError
    }
    if (!current() || selectedDevice.owner_user_id !== currentScannerOwner()) return null
    let verified
    try {
      if (Number(response.data?.payload?.event?.id) !== Number(selectedEventId)) throw new Error('The downloaded ticket list belongs to a different event.')
      verified = await saveVerifiedManifest(response.data)
    } catch (verificationError) {
      // A stale callback must block its UI without erasing a newer context's access.
      if (!verificationError.manifestContextChanged) await invalidateManifestAccess(selectedEventId, { context })
      verificationError.manifestInvalid = true
      throw verificationError
    }
    // The store may retain a newer signed manifest over a delayed network response.
    if (current()) setManifest(verified)
    return verified
  }, [])

  const reconcileStoredResult = useCallback(async selectedEventId => {
    const context = resultContextRef.current
    const current = () => context && mountedRef.current && resultContextRef.current === context
      && context.owner === currentScannerOwner() && context.eventId === String(selectedEventId)
      && eventIdRef.current === context.eventId && context.generation === setupGenerationRef.current
      && context.presentation === presentationRef.current
    if (!current()) return
    const activeDevice = await loadDevice(selectedEventId)
    if (!current() || activeDevice?.id !== context.deviceId) return
    if (context.kind === 'reverse') {
      const pending = await queuedActions(selectedEventId, context.deviceId)
      if (current() && !pending.some(item => item.action_uuid === context.uuid)) setScanResult(existing => current()
        && existing?.actionUuid === context.uuid && existing.actionKind === 'reverse' && existing.type === 'pending'
        ? { ...existing, message: 'Undo is no longer queued', detail: 'Refresh admissions to check its result.' } : existing)
      return
    }
    if (context.kind !== 'admit' || !context.ticketId) return
    // Queue deletion and the terminal admit receipt commit atomically. Re-read
    // after observing empty, including an ACK from a different browser tab.
    const receipt = await localScanState(selectedEventId, context.ticketId)
    if (!current() || receipt?.action_uuid !== context.uuid || !['accepted', 'conflict', 'rejected'].includes(receipt.status)) return
    setScanResult(existing => current() && existing?.actionUuid === context.uuid && existing.actionKind === context.kind
      ? admissionAcknowledgement(existing, receipt) : existing)
  }, [])

  const syncQueue = useCallback(async ({ selectedEventId = eventId, selectedDevice = device, quiet = false } = {}) => {
    if (!selectedEventId || !selectedDevice || selectedDevice.owner_user_id !== currentScannerOwner() || !online || syncingRef.current) return
    const owner = currentScannerOwner()
    const generation = setupGenerationRef.current
    const current = () => owner === currentScannerOwner() && eventIdRef.current === String(selectedEventId) && generation === setupGenerationRef.current
    const ownsJournal = async () => {
      const identity = await loadPendingDeviceIdentity(selectedEventId)
      return current() && identity?.device_id === selectedDevice.id
    }
    syncingRef.current = true
    setSyncing(true)
    let failureContext
    try {
      if (!await ownsJournal()) return
      failureContext = await captureAdmissionAccessContext(selectedEventId, { isCurrent: current })
      let remaining = await queuedActions(selectedEventId, selectedDevice.id)
      if (!remaining.length) {
        if (current()) setPendingCount(0)
        await reconcileStoredResult(selectedEventId)
        if (!current()) return
        if (!quiet) await Promise.all([downloadManifest(selectedEventId, selectedDevice), fetchDashboard(selectedEventId)])
        return
      }
      let currentDevice = selectedDevice
      while (remaining.length) {
        if (!await ownsJournal()) return
        const batch = remaining.slice(0, 500)
        failureContext = await captureAdmissionAccessContext(selectedEventId, { isCurrent: current })
        const response = await apiClient.post(
          `/organizer/events/${selectedEventId}/scanner_devices/${currentDevice.id}/sync`,
          { actions: batch.map(({ event_id: _eventId, device_id: _deviceId, owner_user_id: _ownerId, ...action }) => action) },
        )
        if (!await ownsJournal()) return
        const results = response.data?.results
        if (response.data?.device?.id !== currentDevice.id || !Array.isArray(results) || batch.some(action => !results.some(result => result.action_uuid === action.action_uuid && result.kind === action.kind && ['accepted', 'conflict', 'rejected'].includes(result.result)))) {
          throw new Error('The server did not confirm every saved scan. They remain on this device; please retry synchronization.')
        }
        await applySyncResults(selectedEventId, response.data.device, response.data.results, owner, { context: failureContext })
        if (!current()) return
        const pendingAfterSync = await queuedActions(selectedEventId, currentDevice.id)
        if (batch.some(action => pendingAfterSync.some(pending => pending.action_uuid === action.action_uuid))) {
          throw new Error('Saved scans could not be acknowledged on this device. They remain saved; reconnect and retry synchronization.')
        }
        if (eventIdRef.current === String(selectedEventId)) setScanResult(current => {
          if (!current) return current
          const result = current.actionUuid && results.find(item => item.action_uuid === current.actionUuid
            && item.kind === current.actionKind)
          if (!result) return current
          if (result.kind === 'reverse') {
            if (result.result === 'accepted') return { ...current, type: 'success', message: 'Admission reversal confirmed', detail: 'The server confirmed the Undo. Current ticket status determines whether it can be admitted again.' }
            if (result.reason_code === 'already_reversed') return { ...current, type: 'warning', message: 'Admission already reversed', detail: 'The original Undo was already confirmed. This saved request has been acknowledged.' }
            return { ...current, type: 'error', message: 'Admission reversal refused', detail: 'The server did not confirm this Undo. Ask a door manager to check the ticket status.' }
          }
          return admissionAcknowledgement(current, result)
        })
        // Receipt reconciliation may retain a newer peer's authorization. Never
        // reapply the old response's lease over the store's retained device.
        const retainedDevice = await loadDevice(selectedEventId)
        if (!current()) return
        if (retainedDevice?.id === currentDevice.id) {
          currentDevice = retainedDevice
          if (retainedDevice.status === 'revoked') {
            try {
              const context = await captureAdmissionAccessContext(selectedEventId, { isCurrent: current, expectedDevice: retainedDevice })
              if (await purgeExpiredAdmissionAccess(selectedEventId, { context }) && current()) {
                const revokedDevice = await loadDevice(selectedEventId)
                if (current() && revokedDevice?.id === retainedDevice.id && revokedDevice.status === 'revoked') {
                  setDevice(null)
                  setManifest(null)
                  setRecoveryDevice(revokedDevice)
                  setError('This scanner device was revoked. Ask the event manager for help. Saved scans remain on this device.')
                }
              }
            } catch (revocationError) {
              if (!revocationError.manifestContextChanged) throw revocationError
            }
          } else setDevice(retainedDevice)
        }
        if (eventIdRef.current === String(selectedEventId)) setDashboard(current => current ? { ...current, counts: response.data.summary } : current)
        remaining = pendingAfterSync
      }
      if (!await ownsJournal()) return
      await refreshPending(selectedEventId, currentDevice)
      const retainedAccess = await loadDevice(selectedEventId)
      if (!current()) return
      if (retainedAccess?.id === currentDevice.id && retainedAccess.status === 'revoked') return
      if (!retainedAccess || retainedAccess.id !== currentDevice.id) {
        setDevice(null)
        setManifest(null)
        setRecoveryDevice(currentDevice)
        setError('Saved scans synchronized. Reload while connected to renew scanner access before admitting more guests.')
        return
      }
      setDevice(currentDevice)
      await Promise.all([downloadManifest(selectedEventId, currentDevice), fetchDashboard(selectedEventId)])
    } catch (syncError) {
      if (!current()) return
      try {
        if (!await ownsJournal()) return
      } catch {
        // Storage failure is not an authorization verdict. Keep both access and the
        // pending journal untouched rather than throwing again from recovery.
        if (current()) setError('Saved scanner data could not be read. Reload this device and retry; saved scans have not been removed.')
        return
      }
      if (syncError.scannerAccessRefused) {
        if (syncError.scannerAccessPurged) setError(syncError.response?.data?.error || 'Scanner authorization was refused. Saved scans remain available to the original staff account after access is restored.')
      } else if ([401, 403, 404, 410, 422].includes(syncError.response?.status)) {
        if (!await purgeExpiredAdmissionAccess(selectedEventId, { context: failureContext }) || !current()) return
        if (eventIdRef.current === String(selectedEventId)) { setDevice(null); setManifest(null); setRecoveryDevice(null) }
        setError(syncError.response?.data?.error || 'Scanner authorization was refused. Saved scans remain available to the original staff account after access is restored.')
      } else if (syncError.manifestInvalid) {
        setDevice(null)
        setManifest(null)
        setError(syncError.message)
      } else if (!quiet) setError(syncError.response?.data?.error || syncError.message || 'Queued scans could not be synchronized. They remain saved on this device; reconnect and retry.')
    } finally {
      // A new scan can be acknowledged by a peer while this tab's older sync is
      // busy. Resolve its own receipt even when the loop ends without another RPC.
      try {
        if (current()) await reconcileStoredResult(selectedEventId)
      } catch {
        if (current()) setError('Saved scanner data could not be read. Reload this device and retry; saved scans have not been removed.')
      }
      syncingRef.current = false
      setSyncing(false)
    }
  }, [device, downloadManifest, eventId, fetchDashboard, refreshPending, online, reconcileStoredResult])

  const configureEvent = useCallback(async selectedEventId => {
    if (!selectedEventId) return
    const generation = ++setupGenerationRef.current
    const owner = currentScannerOwner()
    const organizationId = window.localStorage.getItem('hafapass_organization_id')
    const route = routeScopeRef.current
    const current = () => mountedRef.current && route === routeScopeRef.current
      && generation === setupGenerationRef.current && eventIdRef.current === String(selectedEventId) && owner === currentScannerOwner() && organizationId === window.localStorage.getItem('hafapass_organization_id')
    const refusedKey = JSON.stringify([owner, String(selectedEventId)])
    const priorRefusalTokens = storedRefusalTokens(owner, selectedEventId)
    const accessRefused = refusedAccessRef.current.has(refusedKey) || hasStoredRefusal(owner, selectedEventId)
    const safetyStorageReady = canPersistRefusal(owner, selectedEventId)
    setSetupBusy(true)
    setError(null)
    setScanResult(null)
    setDevice(null)
    setRecoveryDevice(null)
    setManifest(null)
    setDashboard(null)
    setSearchResults([])
    try {
      const pendingIdentity = await loadPendingDeviceIdentity(selectedEventId)
      await refreshPending(selectedEventId, pendingIdentity ? { id: pendingIdentity.device_id } : null)
      if (!current()) return
      if (!online && !safetyStorageReady) throw new Error('This browser cannot save scanner safety checks. Stay connected and ask the door manager for help before admitting guests.')
      if (!online && (accessRefused || hasStoredRefusal(owner, selectedEventId))) throw new Error('Scanner access was refused. Reconnect to verify access before admitting more guests.')
      let cached = await loadAuthorizedScanner(selectedEventId)
      if (!current()) return
      if (online) {
        let networkPhase = true
        let failureContext = await captureAdmissionAccessContext(selectedEventId, { isCurrent: current })
        try {
          if (!current()) return
          let previousIdentity = await loadPendingDeviceIdentity(selectedEventId)
          if (!current()) return
          if (!previousIdentity) {
            const me = await apiClient.get('/me')
            if (!current()) return
            previousIdentity = await loadPendingDeviceIdentity(selectedEventId, me.data.id)
          }
          if (!current()) return
          const registration = await apiClient.post(`/organizer/events/${selectedEventId}/scanner_devices`, {
            identifier: previousIdentity?.identifier || browserIdentifier(),
            name: `Scanner · ${navigator.platform || 'browser'}`,
          })
          networkPhase = false
          if (!current()) return
          await saveDevice(selectedEventId, { ...registration.data, organization_id: organizationId }, { isCurrent: current, context: failureContext })
          if (!current()) return
          const registeredDevice = await loadDevice(selectedEventId)
          if (current()) setRecoveryDevice(registeredDevice)
          await refreshPending(selectedEventId, registeredDevice)
          networkPhase = true
          failureContext = await captureAdmissionAccessContext(selectedEventId, { isCurrent: current })
          const downloaded = await apiClient.get(`/organizer/events/${selectedEventId}/scanner_devices/${registration.data.id}/manifest`)
          networkPhase = false
          if (!current()) return
          try {
            if (Number(downloaded.data?.payload?.event?.id) !== Number(selectedEventId)) throw new Error('The downloaded ticket list belongs to a different event. Ask a manager to check this device.')
            await saveVerifiedManifest(downloaded.data)
          } catch (verificationError) {
            if (!verificationError.manifestContextChanged) await invalidateManifestAccess(selectedEventId, { context: failureContext })
            throw verificationError
          }
          cached = await loadAuthorizedScanner(selectedEventId)
          if (current()) await fetchDashboard(selectedEventId).catch(() => {})
        } catch (connectionError) {
          // Explicit authorization failures invalidate local trust. Dependency outages do not.
          if (connectionError.response?.status >= 400 && connectionError.response.status < 500 && ![408, 429].includes(connectionError.response.status)) {
            if (!await purgeExpiredAdmissionAccess(selectedEventId, { context: failureContext }) || !current()) return
            if (current()) setRecoveryDevice(null)
            throw connectionError
          }
          if (!cached || !networkPhase || accessRefused || !safetyStorageReady) throw connectionError
          if (current()) setError('Connection unavailable. Using saved access; scans remain on this device until sync succeeds.')
        }
      }
      if (!cached) {
        if ((await loadDevice(selectedEventId))?.status === 'revoked') {
          throw new Error('This scanner device was revoked. Ask the event manager for help. Saved scans remain on this device.')
        }
        throw new Error('Connect once to authorize this scanner and download the event list. Expired saved access is removed from this device.')
      }
      if (!current()) return
      if (accessRefused || hasStoredRefusal(owner, selectedEventId)) {
        if (!online || !clearStoredRefusal(owner, selectedEventId, priorRefusalTokens)) throw new Error('Stay connected to verify scanner access. Saved refusal evidence could not be cleared.')
        refusedAccessRef.current.delete(refusedKey)
      }
      setDevice(cached.device)
      setManifest(cached.manifest)
      await refreshPending(selectedEventId, cached.device)
    } catch (setupError) {
      if (current()) {
        setDevice(null)
        setManifest(null)
        setError(setupError.response?.data?.error || setupError.message || 'Scanner setup failed.')
      }
    } finally {
      if (current()) setSetupBusy(false)
    }
  }, [fetchDashboard, refreshPending, online])

  useEffect(() => {
    const handleOnline = () => setOnline(!offlineOnly)
    const handleOffline = () => setOnline(false)
    window.addEventListener('online', handleOnline)
    window.addEventListener('offline', handleOffline)
    return () => {
      window.removeEventListener('online', handleOnline)
      window.removeEventListener('offline', handleOffline)
    }
  }, [offlineOnly])

  useEffect(() => {
    let active = true
    const restoreSaved = async () => {
      let saved = requestedEventId ?? offlineEventId
      try { saved ??= window.localStorage.getItem('hafapass_scanner_event_id') } catch { /* Missing storage cannot select another event. */ }
      const cached = saved ? await loadAuthorizedScanner(saved).catch(() => null) : null
      if (!active) return
      if (cached && Number(cached.manifest?.payload?.event?.id) === Number(saved)) {
        setEvents([{ ...cached.manifest.payload.event, id: Number(saved) }])
        setEventId(saved)
      } else {
        setError(requestedEventId !== null || offlineEventId !== null
          ? 'This event is not saved on this device. Connect to verify access and download its ticket list.'
          : 'Could not load assigned events. Connect once to authorize this scanner and download an event list.')
        setSetupBusy(false)
      }
    }
    if (offlineOnly) { void restoreSaved(); return () => { active = false } }
    const controller = new AbortController()
    const owner = currentScannerOwner()
    const authContext = getApiAuthContext()
    const organizationId = window.localStorage.getItem('hafapass_organization_id')
    const current = () => active && owner === currentScannerOwner() && authContext === getApiAuthContext()
      && organizationId === window.localStorage.getItem('hafapass_organization_id')
    const config = { signal: controller.signal, organizationId, ...(authContext ? { authContext } : {}) }
    setEventListLoading(true)
    setEventListError('')
    const preparedEventId = eventIdRef.current
    const generation = setupGenerationRef.current
    const readGeneration = privateReadGenerationRef.current
    eventListAccessRef.current?.abort()
    directEventAccessRef.current?.abort()
    eventListAccessRef.current = controller
    const scopeCurrent = () => current() && !controller.signal.aborted && eventListAccessRef.current === controller
      && preparedEventId === eventIdRef.current && readGeneration === privateReadGenerationRef.current
    const listAccess = { preparedEventId, scopeCurrent, current: () => scopeCurrent() && generation === setupGenerationRef.current }
    let listContexts = []
    let verification = null
    Promise.resolve().then(async () => {
      listContexts = await captureOrganizationAdmissionContexts(organizationId, { isCurrent: listAccess.current })
      if (!listAccess.current()) throw new DOMException('Scanner context changed', 'AbortError')
      return apiClient.get('/organizer/events', { ...config, params: { q: listing.q, page: listing.page, purpose: 'scan' } })
    }).then(async response => {
      if (!current()) return
      const accessible = (response.data.events || []).filter(event => event.permissions?.scan !== false)
      setEvents(accessible)
      setEventMeta(response.data.meta || null)
      const saved = window.localStorage.getItem('hafapass_scanner_event_id')
      // A saved draft only exists from the earlier first-in-list default; drafts
      // never issue manifests, so it cannot hold scans and should not win.
      const savedDraft = accessible.some(event => String(event.id) === String(saved) && event.status === 'draft')
      const fromSaved = !eventIdRef.current && requestedEventId === null
      const preferred = eventIdRef.current || (requestedEventId !== null ? requestedEventId : (savedDraft ? null : saved))
      let selected = accessible.find(event => String(event.id) === String(preferred))
      if (!selected && preferred) {
        // A page boundary is not an authorization decision. Resolve the exact
        // event through the authorized endpoint before preparing this device.
        verification = String(preferred) === eventIdRef.current ? beginPrivateRead(directEventAccessRef, String(preferred)) : null
        const accessContext = verification ? await captureAdmissionAccessContext(String(preferred), { isCurrent: verification.current }) : null
        if (!current() || (verification && !verification.current())) return
        try {
          const direct = await apiClient.get(`/organizer/events/${encodeURIComponent(preferred)}`, verification?.config || config)
          if (!current() || (verification && !verification.current())) return
          if (String(direct.data.id) === String(preferred) && direct.data.permissions?.scan === true
            && (organizationId == null || String(direct.data.organization_id) === organizationId)
            && !(fromSaved && direct.data.status === 'draft')) selected = direct.data
          else if (verification) { const refusal = new Error('Scanner permission was refused'); refusal.response = { status: 403 }; throw refusal }
        } catch (directError) {
          if (!current()) return
          if (![401, 403, 404].includes(directError.response?.status)) throw directError
          if (String(preferred) === eventIdRef.current) {
            if (!verification?.current()) return
            await handlePrivateReadError({ response: { status: 403, data: { error: 'This event is no longer available for scanning. Saved scans remain on this device.' } } }, verification, accessContext, 'Scanner access could not be verified.')
            return
          }
        }
      }
      if (!current()) return
      if (!selected && requestedEventId === null && !eventIdRef.current) {
        // The visible page is ordered by creation, so look up the best
        // published candidates across every page before choosing a default.
        const candidates = await scannerDefaultCandidates(config, listing.q)
        if (!current()) return
        selected = defaultScannerEvent([...candidates, ...accessible])
      }
      if (selected) {
        setResolvedEvent(selected)
        setEventId(String(selected.id))
      } else {
        if (requestedEventId !== null) setError('This event is not assigned to your account. Choose an assigned event or ask the event manager for access.')
        setSetupBusy(false)
      }
    }).catch(async listError => {
      if (!current()) return
      if ([401, 403].includes(listError.response?.status)) {
        await handleEventListRefusal(listError, listAccess, listContexts)
        return
      }
      setEventListError('Events could not be loaded. Retry while connected.')
      if (!eventIdRef.current) void restoreSaved()
    }).finally(() => { if (current()) setEventListLoading(false) })
    return () => { active = false; controller.abort(); verification?.controller.abort() }
  }, [offlineOnly, offlineEventId, requestedEventId, routeScope, setEventId, listing.q, listing.page, eventListRetry, bindingRevision, beginPrivateRead, handlePrivateReadError, handleEventListRefusal])

  useEffect(() => {
    if (!eventId) return
    window.localStorage.setItem('hafapass_scanner_event_id', eventId)
    configureEvent(eventId)
  }, [configureEvent, eventId])

  useEffect(() => {
    if (online && eventId && device && device.owner_user_id === currentScannerOwner()) syncQueue({ quiet: true })
  }, [device, eventId, online, syncQueue])

  const showResult = useCallback(result => {
    // Record ownership synchronously; a peer ACK need not wait for React to render.
    resultContextRef.current = result.actionUuid ? { uuid: result.actionUuid, kind: result.actionKind,
      ticketId: result.ticket?.ticket_id, deviceId: result.deviceId, owner: currentScannerOwner(), eventId: eventIdRef.current,
      generation: setupGenerationRef.current, presentation: presentationRef.current } : null
    setScanResult(result)
    if (result.type === 'success' || (result.type === 'pending' && result.actionKind === 'admit')) setSessionCount(count => count + 1)
    if (navigator.vibrate && result.type !== 'pending') navigator.vibrate(result.type === 'success' ? 80 : [100, 60, 100])
  }, [])

  const admitEntry = useCallback(async (ticket, hash, startedAt = performance.now(), clientStatus = 'locally_accepted', presentation = ++presentationRef.current) => {
    if (!device || !manifest || eventIdRef.current !== eventId || currentManifestRef.current?.digest !== manifest.digest) return
    const owner = currentScannerOwner()
    if (!owner || device.owner_user_id !== owner) return
    if (refusedAccessRef.current.has(JSON.stringify([owner, String(eventId)])) || hasStoredRefusal(owner, eventId)) {
      showResult({ type: 'error', message: 'Scanner access needs verification', detail: 'Reconnect and verify access before admitting another guest.' })
      return
    }
    const generation = setupGenerationRef.current
    const current = () => mountedRef.current && owner && device.owner_user_id === owner && owner === currentScannerOwner()
      && eventIdRef.current === eventId && generation === setupGenerationRef.current && presentation === presentationRef.current
    if (!device.effective || new Date(device.authorization_expires_at).getTime() <= Date.now() || new Date(manifest.payload.expires_at).getTime() <= Date.now()) {
      try {
        const context = await captureAdmissionAccessContext(eventId, { isCurrent: current,
          expectedDevice: device, expectedManifest: manifest })
        if (!await purgeExpiredAdmissionAccess(eventId, { context }) || !current()) return
      } catch (expiryError) {
        if (expiryError.manifestContextChanged) return
        throw expiryError
      }
      showResult({ type: 'error', message: 'Scanner access expired', detail: 'Reconnect before admitting another ticket.' })
      setDevice(null)
      setManifest(null)
      return
    }
    const savedDevice = await loadDevice(eventId)
    if (!current() || savedDevice?.id !== device.id || savedDevice.owner_user_id !== owner || !savedDevice.effective) return
    const localState = await localScanState(eventId, ticket.ticket_id)
    if (!current() || refusedAccessRef.current.has(JSON.stringify([owner, String(eventId)])) || hasStoredRefusal(owner, eventId)) return
    if (['pending', 'accepted', 'conflict', 'pending_reverse'].includes(localState?.status)) {
      showResult({ type: 'warning', message: 'Already scanned on this device', detail: 'This ticket is already admitted or waiting to sync.', ticket,
        ...(localState.status === 'pending' ? { actionUuid: localState.action_uuid, actionKind: 'admit', deviceId: device.id } : {}),
        latency: performance.now() - startedAt })
      return
    }
    if (ticket.state !== 'valid') {
      const labels = { admitted: 'Already admitted', cancelled: 'Cancelled ticket', transferred: 'Transferred ticket', payment_blocked: 'Payment blocked', refund_pending: 'Refund pending — do not admit' }
      showResult({ type: ticket.state === 'admitted' ? 'warning' : 'error', message: labels[ticket.state] || 'Ticket is not valid',
        detail: 'Sync the latest ticket list or ask a door manager for help.', ticket, latency: performance.now() - startedAt })
      return
    }

    const action = await queueAdmission({
      eventId,
      deviceId: device.id,
      manifestVersion: manifest.payload.version,
      ticket,
      credentialHash: hash,
      source: online ? 'online' : 'offline',
      clientStatus,
    })
    if (!current()) return
    if (!action) {
      showResult({ type: 'warning', message: 'Already scanned on this device', detail: 'This ticket is already admitted or waiting to sync.', ticket })
      return
    }
    // Own the result before count refresh yields to an already-running sync.
    showResult({ type: online ? 'pending' : 'success', message: online ? 'Waiting for server confirmation' : 'Admitted offline',
      actionUuid: action.action_uuid, actionKind: 'admit', deviceId: device.id,
      detail: online ? 'Saved on this device. Entry is not confirmed until the server responds.' : 'Saved on this device. Other offline scanners cannot see this admission until they sync.',
      ticket, latency: performance.now() - startedAt })
    await refreshPending(eventId, device)
    if (!current()) return
    // Another tab can acknowledge the transaction before queueAdmission returns.
    // Only this command's durable terminal receipt can resolve its presentation.
    const receipt = await localScanState(eventId, ticket.ticket_id)
    if (!current()) return
    if (receipt?.action_uuid === action.action_uuid && ['accepted', 'conflict', 'rejected'].includes(receipt.status)) {
      setScanResult(existing => current() && existing?.actionUuid === action.action_uuid && existing.actionKind === 'admit'
        ? admissionAcknowledgement(existing, receipt) : existing)
    }
    if (online && current()) syncQueue({ quiet: true })
  }, [device, eventId, manifest, refreshPending, showResult, syncQueue, online])

  const processCredential = useCallback(async raw => {
    const startedAt = performance.now()
    const presentation = ++presentationRef.current
    const owner = currentScannerOwner()
    if (!owner || device?.owner_user_id !== owner) return
    const generation = setupGenerationRef.current
    const current = () => mountedRef.current && owner && device?.owner_user_id === owner && owner === currentScannerOwner()
      && eventIdRef.current === eventId && generation === setupGenerationRef.current && presentation === presentationRef.current
    try {
      if (refusedAccessRef.current.has(JSON.stringify([owner, String(eventId)])) || hasStoredRefusal(owner, eventId)) throw new Error('Reconnect and verify scanner access before scanning.')
      if (!device?.effective || new Date(device.authorization_expires_at).getTime() <= Date.now()) {
        throw new Error('This scanner authorization expired. Reconnect before scanning.')
      }
      if (!manifest || new Date(manifest.payload.expires_at).getTime() <= Date.now()) {
        throw new Error('The saved ticket list is missing or expired. Reconnect before scanning.')
      }
      const hash = await sha256Hex(credentialValue(raw))
      if (!current() || currentManifestRef.current?.digest !== manifest.digest) return
      const ticket = ticketsByHash.get(hash)
      if (!ticket) {
        showResult({ type: 'error', message: 'Invalid ticket', detail: 'This QR code is not in the verified ticket list for this event.',
          latency: performance.now() - startedAt })
        return
      }
      await admitEntry(ticket, hash, startedAt, 'locally_accepted', presentation)
    } catch (scanError) {
      if (current()) showResult({ type: 'error', message: 'Scanner unavailable', detail: scanError.message, latency: performance.now() - startedAt })
    }
  }, [admitEntry, device, eventId, manifest, showResult, ticketsByHash])

  processCredentialRef.current = processCredential

  const handleDecoded = useCallback(code => {
    if (!code || scanCooldownRef.current) return
    scanCooldownRef.current = true
    processCredentialRef.current(code).finally(() => setTimeout(() => { scanCooldownRef.current = false }, 1800))
  }, [])

  const startCamera = useCallback(async () => {
    const generation = ++cameraGenerationRef.current
    setCameraError(null)
    setScanning(true)
    try {
      if ('BarcodeDetector' in window) {
        const stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: 'environment' } } })
        if (generation !== cameraGenerationRef.current) { stream.getTracks().forEach(track => track.stop()); return }
        streamRef.current = stream
        videoRef.current.srcObject = stream
        await videoRef.current.play()
        const detector = new window.BarcodeDetector({ formats: ['qr_code'] })
        detectorTimerRef.current = setInterval(async () => {
          if (!videoRef.current || scanCooldownRef.current) return
          const codes = await detector.detect(videoRef.current).catch(() => [])
          if (generation === cameraGenerationRef.current) handleDecoded(codes[0]?.rawValue)
        }, 250)
      } else {
        const { BrowserQRCodeReader } = await import('@zxing/browser')
        const reader = new BrowserQRCodeReader()
        const controls = await reader.decodeFromVideoDevice(undefined, videoRef.current, result => {
          if (result && generation === cameraGenerationRef.current) handleDecoded(result.getText())
        })
        if (generation !== cameraGenerationRef.current) { controls.stop(); return }
        zxingControlsRef.current = controls
      }
    } catch (cameraFailure) {
      stopCamera()
      setCameraError(cameraFailure.name === 'NotAllowedError'
        ? 'Camera permission was denied. Allow it in browser settings or use manual entry.'
        : `Camera could not start: ${cameraFailure.message}`)
    }
  }, [handleDecoded, stopCamera])

  // Keep the reader running across verified refreshes; its callback always reads current state.
  // Event/device changes and loss of authorization stop the old camera immediately.
  const manifestReady = Boolean(manifest)
  useEffect(() => { stopCamera(); return () => stopCamera() }, [eventId, device?.id, manifestReady, stopCamera])

  useEffect(() => {
    if (!device || !manifest) return
    const owner = currentScannerOwner()
    const generation = setupGenerationRef.current
    let active = true
    const current = () => active && mountedRef.current && owner === currentScannerOwner()
      && eventIdRef.current === eventId && generation === setupGenerationRef.current
      && currentManifestRef.current?.digest === manifest.digest
    const expiresAt = Math.min(new Date(device.authorization_expires_at).getTime(), new Date(manifest.payload.expires_at).getTime())
    const timer = window.setTimeout(async () => {
      try {
        const context = await captureAdmissionAccessContext(eventId, { isCurrent: current,
          expectedDevice: device, expectedManifest: manifest })
        if (!await purgeExpiredAdmissionAccess(eventId, { context }) || !current()) return
        stopCamera()
        setDevice(null)
        setManifest(null)
        setError('Saved scanner access has expired. Reconnect with the original staff account to renew access and sync saved scans.')
      } catch (expiryError) {
        if (current() && !expiryError.manifestContextChanged) setError('Saved scanner access could not be removed. Reload this device before admitting more guests.')
      }
    }, Math.max(0, expiresAt - Date.now()))
    return () => { active = false; window.clearTimeout(timer) }
  }, [device, eventId, manifest, stopCamera])

  const runSearch = event => {
    event.preventDefault()
    searchAttendees(searchQuery)
  }

  const searchAttendees = async query => {
    if (!eventId || !online || query.trim().length < 2) return
    const request = beginPrivateRead(searchRequestRef, eventId)
    setSearching(true)
    setError(null)
    let context
    try {
      context = await captureAdmissionAccessContext(request.selectedEventId, { isCurrent: request.current })
      if (!request.current()) return
      const response = await apiClient.get(`/organizer/events/${request.selectedEventId}/admissions/search`, { ...request.config, params: { q: query.trim() } })
      if (request.current()) setSearchResults(response.data)
    } catch (searchError) {
      await handlePrivateReadError(searchError, request, context, 'Attendee search failed. Please retry.')
    } finally {
      if (request.current()) setSearching(false)
    }
  }

  const reverseAdmission = async action => {
    if (!device || !manifest) return
    const owner = currentScannerOwner()
    const generation = setupGenerationRef.current
    const presentation = ++presentationRef.current
    const current = () => mountedRef.current && owner === currentScannerOwner()
      && eventIdRef.current === eventId && generation === setupGenerationRef.current && presentation === presentationRef.current
    try {
      const reversal = await queueReversal({ eventId, deviceId: device.id, manifestVersion: manifest.payload.version,
        ticketId: action.ticket_id, reversesActionUuid: action.action_uuid, source: online ? 'online' : 'offline' })
      if (!current()) return
      showResult({ type: 'pending', message: 'Reversal queued', actionUuid: reversal.action_uuid, actionKind: 'reverse', deviceId: device.id, detail: 'The admission reversal will be reconciled append-only.' })
      await refreshPending(eventId, device)
      if (!current()) return
      // Reversal deletion is not a success receipt; only offer a neutral refresh.
      await reconcileStoredResult(eventId)
      if (!current()) return
      if (online && current()) syncQueue()
    } catch (reversalError) {
      if (current()) setError(reversalError.message)
    }
  }

  const downloadDoorList = async () => {
    if (!eventId || !online || downloading) return
    const request = beginPrivateRead(downloadRequestRef, eventId)
    setDownloading(true)
    setError(null)
    let context
    try {
      context = await captureAdmissionAccessContext(request.selectedEventId, { isCurrent: request.current })
      if (!request.current()) return
      const response = await apiClient.get(`/organizer/events/${request.selectedEventId}/admissions/door_list`, { ...request.config, responseType: 'blob' })
      if (!request.current()) return
      const url = URL.createObjectURL(response.data)
      try {
        const link = document.createElement('a')
        link.href = url
        link.download = `hafapass-door-list-${request.selectedEventId}.pdf`
        if (request.current()) link.click()
      } finally { URL.revokeObjectURL(url) }
    } catch (downloadError) {
      await handlePrivateReadError(downloadError, request, context, 'Door list download failed. Please retry while connected.')
    } finally { if (request.current()) setDownloading(false) }
  }

  const resetScanner = async () => {
    if (!online) return setError('Reconnect before resetting this scanner.')
    if (syncingRef.current) return setError('Wait for synchronization to finish before resetting this scanner.')
    const identity = await loadPendingDeviceIdentity(eventId)
    const pending = identity ? await queuedActions(eventId, identity.device_id) : []
    if (pending.length) { setPendingCount(pending.length); return setError('Sync every queued action before resetting this scanner.') }
    if (!window.confirm('Reset this event scanner and trust a newly downloaded signing key?')) return
    stopCamera()
    currentManifestRef.current = null
    setDevice(null)
    setManifest(null)
    try {
      // The store checks inside the deletion transaction as well, so an overlapping scan is retained.
      await clearEventAdmissionData(eventId, { requireEmptyQueue: true })
      await configureEvent(eventId)
    } catch (resetError) {
      setError(resetError.message)
      const retainedIdentity = await loadPendingDeviceIdentity(eventId)
      await refreshPending(eventId, retainedIdentity ? { id: retainedIdentity.device_id } : null)
    }
  }

  const selectedEvent = events.find(event => String(event.id) === eventId) || (String(resolvedEvent?.id) === eventId ? resolvedEvent : null)
  const ready = Boolean(eventId && device && manifest && Number(manifest.payload?.event?.id) === Number(eventId))
  const searchAttendeesRef = useRef(searchAttendees)
  searchAttendeesRef.current = searchAttendees
  const handedOffLookupRef = useRef(null)
  useEffect(() => {
    // Wait for the trusted ticket list so the matching Admit button is usable.
    if (!requestedLookup || !ready || !online || eventId !== String(requestedEventId) || handedOffLookupRef.current === routeScope) return
    handedOffLookupRef.current = routeScope
    setSearchQuery(requestedLookup)
    searchAttendeesRef.current(requestedLookup)
    // One-shot: drop the hand-off from the address bar so a reload, Back or a
    // copied link does not repeat it. Rewriting history directly keeps the
    // router location (and with it this device's setup) unchanged.
    const address = new URL(window.location.href)
    if (address.searchParams.has('lookup')) {
      address.searchParams.delete('lookup')
      window.history.replaceState(window.history.state, '', address)
    }
    document.getElementById('attendee-lookup')?.scrollIntoView?.({ block: 'start' })
  }, [eventId, online, ready, requestedEventId, requestedLookup, routeScope])
  const expiresAt = Math.min(Date.parse(device?.authorization_expires_at || ''), Date.parse(manifest?.payload.expires_at || ''))
  const eventTimezone = manifest?.payload.event?.timezone || selectedEvent?.timezone || 'Pacific/Guam'
  const expiryLabel = Number.isFinite(expiresAt) ? formatEventDateTime(expiresAt, eventTimezone) : null

  // The DOM follows the phone order: event, door status, camera, door totals,
  // then the remaining tools. From the sm breakpoint explicit grid placement
  // restores the two-column desktop arrangement (rows 1-3 header, 4-6 status,
  // notices and tool links, 7-10 the camera and side column).
  return (
    <div className="mx-auto flex max-w-6xl flex-col gap-3 px-4 py-4 sm:grid sm:grid-cols-[minmax(0,1fr)_minmax(0,24rem)] sm:gap-x-4 sm:gap-y-0 sm:py-8 lg:grid-cols-[minmax(0,1.35fr)_minmax(0,.65fr)] lg:grid-rows-[repeat(8,auto)_1fr_auto] lg:gap-x-6">
      <div className="sm:col-start-1 sm:row-start-1 sm:min-w-0 sm:max-w-2xl sm:self-end">
        <div className="flex items-center justify-between gap-3 sm:flex-col-reverse sm:items-start sm:gap-0">
          <h1 className="font-display text-2xl font-bold text-neutral-950 sm:text-3xl">Check-in</h1>
          <Link to="/dashboard" className="inline-flex min-h-11 items-center text-sm font-medium text-brand-800">All events</Link>
        </div>
        {selectedEvent && <p className="mt-2 hidden break-words text-base font-semibold text-neutral-900 sm:block">{selectedEvent.title}</p>}
      </div>
      <div className="sm:col-start-2 sm:row-start-2">
        {!offlineOnly && eventListLoading && <p role="status" className="mb-2 text-sm">Loading events…</p>}
        {!offlineOnly && eventListError && <p role="alert" className="mb-2 text-sm text-red-800">{eventListError} <button type="button" className="min-h-11 underline" onClick={() => setEventListRetry(value => value + 1)}>Retry event search</button></p>}
        <label htmlFor="scanner-event" className="mb-1 block text-sm font-medium text-neutral-800">Event to scan</label>
        <select id="scanner-event" disabled={eventListLoading} value={eventId} onChange={event => setSearchParams(previous => { const next = new URLSearchParams(previous); next.set('event', event.target.value); next.delete('lookup'); return next })} className="input w-full">
          {!eventId && <option value="">{events.length ? 'Choose an assigned event' : 'No assigned events'}</option>}
          {selectedEvent && !events.some(event => String(event.id) === eventId) && <option value={eventId}>{selectedEvent.title} (selected)</option>}
          {events.map(event => <option key={event.id} value={event.id}>{event.title}</option>)}
        </select>
      </div>

      <div className="grid grid-cols-4 gap-2 sm:col-span-2 sm:row-start-4 sm:mb-4 sm:mt-5" aria-label="Check-in status">
        <div className={`flex items-center rounded-xl border p-2 sm:block sm:p-3 ${online ? 'border-emerald-200 bg-emerald-50' : 'border-amber-200 bg-amber-50'}`}>
          <p className="flex flex-col items-start gap-1 text-xs font-semibold sm:flex-row sm:items-center sm:gap-2 sm:text-sm">{online ? <ShieldCheck className="h-4 w-4" /> : <CloudOff className="h-4 w-4" />}{online ? 'Online' : 'Offline mode'}</p>
        </div>
        <div className="rounded-xl border border-neutral-200 bg-white p-2 sm:p-3"><p className="text-xs leading-tight text-neutral-700 sm:text-sm">Waiting to sync</p><p className="text-lg font-bold sm:text-xl" data-testid="scanner-pending-count">{pendingCount}</p></div>
        <div className="rounded-xl border border-neutral-200 bg-white p-2 sm:p-3"><p className="text-xs leading-tight text-neutral-700 sm:text-sm">Scans this session</p><p className="text-lg font-bold sm:text-xl">{sessionCount}</p></div>
        <button onClick={() => syncQueue()} disabled={!ready || !online || syncing} className="btn-secondary flex flex-col items-center justify-center gap-1 !px-2 !py-2 text-xs disabled:opacity-50 sm:flex-row sm:gap-2 sm:!px-6 sm:!py-3 sm:text-base">
          {syncing ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />} Sync now
        </button>
      </div>

      <div className="flex flex-col gap-3 empty:hidden sm:col-span-2 sm:row-start-5 sm:block">
        {pendingCount > 0 && <p className="rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950 sm:mb-4">Sync saved scans before switching accounts or signing out. Unconfirmed scans need the original staff account to recover online.</p>}
        {!online && <p className="rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950 sm:mb-4">Offline scans stay on this device. Other gates may have newer admissions. Sync when connected.</p>}
        {ready && <section aria-label="Ticket list readiness" className="rounded-xl border border-neutral-200 bg-white p-3 sm:mb-5 sm:p-4">
          <p className="font-semibold text-neutral-950">Ticket list ready · {manifest.payload.tickets.length} {manifest.payload.tickets.length === 1 ? 'ticket' : 'tickets'}</p>
          <p className="mt-1 text-sm text-neutral-700">{expiryLabel ? `Access expires ${expiryLabel} · ${eventTimezone}` : 'Reconnect to verify the access expiry.'}</p>
        </section>}
        {error && <div role="alert" className="rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-800 sm:mb-5"><p>{error}</p>{!ready && eventId && online && <button type="button" disabled={setupBusy} onClick={() => configureEvent(eventId)} className="mt-2 min-h-11 font-semibold underline">Verify scanner access</button>}</div>}
        {setupBusy && <div role="status" className="flex items-center gap-2 rounded-xl border bg-white p-4 text-sm sm:mb-5"><Loader2 aria-hidden="true" className="h-4 w-4 animate-spin" /> Preparing this device and verifying its ticket list…</div>}
      </div>

      <div className="flex flex-col gap-3 sm:col-span-2 sm:row-start-7 sm:mb-5 sm:block sm:space-y-5 sm:self-start lg:col-span-1 lg:col-start-1 lg:row-span-3">
        <ResultPanel result={scanResult} />
        <section id="scanner-camera" className="scroll-mt-24 overflow-hidden rounded-2xl bg-neutral-950">
          <button onClick={scanning ? stopCamera : startCamera} disabled={!ready}
            className="flex min-h-11 w-full items-center justify-center gap-2 bg-brand-800 px-4 py-4 font-semibold text-white enabled:hover:bg-brand-900 disabled:cursor-not-allowed disabled:bg-neutral-700">
            {scanning ? <><StopCircle className="h-5 w-5" /> Stop camera</> : <><Camera className="h-5 w-5" /> Start camera</>}
          </button>
          <div className="relative aspect-[4/3]">
            <video ref={videoRef} className={`h-full w-full object-cover ${scanning ? '' : 'hidden'}`} playsInline muted />
            {!scanning && (
              <div className="absolute inset-0 flex flex-col items-center justify-center text-neutral-200">
                <Camera aria-hidden="true" className="mb-3 h-12 w-12" /><p className="text-sm">Point the camera at the ticket QR code</p>
              </div>
            )}
            {scanning && <div className="pointer-events-none absolute inset-0 m-auto h-52 w-52 rounded-3xl border-4 border-white/80 shadow-[0_0_0_9999px_rgba(0,0,0,.28)]" />}
          </div>

        </section>
        {cameraError && <p role="alert" className="rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">{cameraError} You can enter the ticket QR code below or find the attendee online.</p>}
      </div>

      {dashboard && (
        <section className="rounded-2xl border border-neutral-200 bg-white p-3 sm:col-span-2 sm:row-start-10 sm:mb-5 sm:self-start sm:p-5 lg:col-span-1 lg:col-start-2 lg:row-start-8">
          <div className="mb-1 flex items-center justify-between sm:mb-4"><h2 className="font-semibold">Door totals</h2><button onClick={downloadDoorList} disabled={!online || downloading} className="flex min-h-11 min-w-11 items-center justify-center rounded-lg text-brand-800 disabled:opacity-50" aria-label="Download emergency door list" title="Download emergency door list">{downloading ? <Loader2 className="h-5 w-5 animate-spin" /> : <Download className="h-5 w-5" />}</button></div>
          <div className="grid grid-cols-4 gap-2 sm:grid-cols-2 sm:gap-3">
            {[['Admitted', dashboard.counts.admitted], ['Remaining', dashboard.counts.remaining], ['Conflicts', dashboard.counts.conflicts], ['Rejected', dashboard.counts.rejected]].map(([label, value]) => (
              <div key={label} className="rounded-xl bg-neutral-50 p-2 sm:p-3"><p className="text-xs text-neutral-500">{label}</p><p className="text-lg font-bold sm:text-2xl">{value}</p></div>
            ))}
          </div>
        </section>
      )}


      <nav aria-label="Check-in tools" className="flex flex-wrap gap-x-5 gap-y-1 text-sm font-semibold text-brand-800 sm:col-span-2 sm:row-start-6 sm:mb-4">
        <a href="#scanner-camera" className="inline-flex min-h-11 items-center underline underline-offset-4">Use camera</a>
        <a href="#manual-ticket-entry" className="inline-flex min-h-11 items-center underline underline-offset-4">Enter QR code</a>
        <a href="#attendee-lookup" className="inline-flex min-h-11 items-center underline underline-offset-4">Find attendee</a>
      </nav>

      <div className="flex flex-col gap-3 sm:col-span-2 sm:row-start-8 sm:mb-6 sm:block sm:space-y-5 sm:self-start lg:col-span-1 lg:col-start-1 lg:row-start-10 lg:mb-0">
        <section id="manual-ticket-entry" className="scroll-mt-24 rounded-2xl border border-neutral-200 bg-white p-5">
          <h2 className="font-semibold text-neutral-950">Enter a ticket QR code</h2>
          <p id="manual-ticket-help" className="mb-3 text-sm text-neutral-700">Camera not working? Paste the QR code or link from the ticket. For a ticket number such as HP-T123, use attendee lookup below.</p>
          <label htmlFor="manual-ticket-code" className="mb-1 block text-sm font-medium text-neutral-800">Ticket QR code</label>
          <form onSubmit={event => { event.preventDefault(); processCredential(manualCode); setManualCode('') }} className="flex flex-col gap-2 sm:flex-row">
            <input value={manualCode} onChange={event => setManualCode(event.target.value)} id="manual-ticket-code" className="input min-w-0 flex-1" aria-describedby="manual-ticket-help" placeholder="Paste ticket QR code or link" disabled={!ready} />
            <button className="btn-primary" disabled={!ready || !manualCode.trim()}>Check ticket</button>
          </form>
        </section>

        <section id="attendee-lookup" className="scroll-mt-24 rounded-2xl border border-neutral-200 bg-white p-5">
          <h2 className="font-semibold text-neutral-950">Find an attendee</h2>
          <p id="attendee-lookup-help" className="mb-3 text-sm text-neutral-700">Search online by name or HafaPass ticket number. Email addresses stay private.{!online && ' Reconnect to use this search.'}</p>
          <label htmlFor="attendee-query" className="mb-1 block text-sm font-medium text-neutral-800">Attendee name or ticket number</label>
          <form onSubmit={runSearch} className="flex flex-col gap-2 sm:flex-row">
            <input value={searchQuery} onChange={event => setSearchQuery(event.target.value)} id="attendee-query" className="input min-w-0 flex-1" aria-describedby="attendee-lookup-help" placeholder="Name or HP-T123" disabled={!online} />
            <button className="btn-secondary flex items-center gap-2" disabled={!online || searching || searchQuery.trim().length < 2}><Search className="h-4 w-4" /> Search</button>
          </form>
          <div className="mt-3 space-y-2">
            {searchResults.map(ticket => (
              <div key={ticket.id} className="flex flex-col items-start justify-between gap-3 rounded-xl bg-neutral-50 p-3 text-sm sm:flex-row sm:items-center">
                <div className="min-w-0 break-words"><p className="font-semibold text-neutral-950">{ticket.attendee_name || 'Guest'} · {ticket.code}</p><p className="text-neutral-700">{ticket.ticket_type} · {LOOKUP_STATUS_LABELS[ticket.status] || ticket.status?.replaceAll('_', ' ') || 'Status unavailable'}</p>
                  <p className="mt-1 text-neutral-700">{ticket.admission_allowed ? 'Available for check-in' : 'Entry unavailable — ask a door manager'}</p>
                  {ticket.admission_allowed && !ticketsById.has(Number(ticket.id)) && <p className="mt-1 text-amber-900">Sync the ticket list before admitting this guest.</p>}
                </div>
                <button className="btn-primary text-sm" disabled={!ticket.admission_allowed || !ticketsById.has(Number(ticket.id))}
                  onClick={() => { const entry = ticketsById.get(Number(ticket.id)); admitEntry(entry, entry.credential_hash, performance.now(), 'manual_lookup') }}>Admit</button>
              </div>
            ))}
          </div>
        </section>
      </div>

      <div className="sm:col-start-1 sm:row-span-2 sm:row-start-2 sm:max-w-2xl sm:self-start">
        <p className="text-sm text-neutral-700 sm:mt-2">Scan a ticket, check the result, then welcome the guest.</p>
        <p className="mt-2 text-sm text-neutral-600">Prepare this device online before the event.</p>
      </div>
      {!offlineOnly && <div className="sm:col-start-2 sm:row-start-1">
        <OperationalSearch label="Find an event" buttonLabel="Search events" hint="Search by event name, venue or event ID." query={listing.q} onSearch={listing.search} busy={eventListLoading} />
        {!eventListLoading && listing.q && events.length === 0 && <p role="status" className="mb-2 text-sm">No matching events. Try another search. Your selected event stays ready.</p>}
      </div>}
      {!offlineOnly && <div className="empty:hidden sm:col-start-2 sm:row-start-3"><OperationalPagination meta={eventMeta} page={listing.page} onPage={listing.goToPage} busy={eventListLoading} label="Event pages" /></div>}

      <section className="rounded-xl border border-neutral-200 bg-white p-5 sm:col-span-2 sm:row-start-9 sm:mb-5 sm:self-start lg:col-span-1 lg:col-start-2 lg:row-start-7">
        <div className="flex items-start gap-3"><Smartphone aria-hidden="true" className="mt-1 h-5 w-5 shrink-0 text-brand-800" /><div className="min-w-0 break-words">
          <h2 className="font-semibold text-neutral-950">{device?.name || 'Device not ready'}</h2>
          <p className="mt-1 text-sm text-neutral-700">{selectedEvent?.title}</p>
          {!ready && pendingCount > 0 && <p className="mt-3 text-sm text-amber-950">Saved scans are retained. Reconnect with the original staff account to confirm them before resetting this device. Ask a manager if authorization cannot be restored.</p>}
          {!ready && recoveryDevice && pendingCount > 0 && <button disabled={!online || syncing || setupBusy} onClick={() => syncQueue({ selectedDevice: recoveryDevice })} className="btn-secondary mt-3 text-sm">Sync saved scans</button>}
        </div></div>
        <details className="mt-3 border-t border-neutral-200 pt-1">
          <summary className="flex min-h-11 cursor-pointer items-center text-sm font-semibold text-neutral-700">Device details</summary>
          {manifest && <p className="text-sm text-neutral-700">Manifest v{manifest.payload.version} · {manifest.payload.tickets.length} {manifest.payload.tickets.length === 1 ? 'ticket' : 'tickets'}</p>}
          <p className="mt-2 text-sm text-neutral-700">Signing out removes saved access and attendee details. Sync before signing out; unconfirmed scans need the original staff account to recover online.</p>
          <p className="mt-2 text-sm text-neutral-700">Only reset after saved scans are confirmed. Resetting replaces this device’s trusted ticket-list access.</p>
          {eventId && <button disabled={!online || syncing || setupBusy} onClick={resetScanner} className="mt-2 block min-h-11 text-sm font-semibold text-red-800 underline underline-offset-2 disabled:opacity-50">Reset trusted device</button>}
        </details>
      </section>


      {dashboard?.permissions?.can_reverse && (
        <section className="rounded-2xl border border-neutral-200 bg-white p-5 sm:col-span-2 sm:row-start-11 sm:self-start lg:col-span-1 lg:col-start-2 lg:row-start-9 lg:row-span-2">
          <h2 className="mb-3 font-semibold">Recent admissions</h2>
          <div className="space-y-2">
            {dashboard.recent_actions.filter(action => action.kind === 'admit' && action.result === 'accepted').slice(0, 8).map(action => {
              const ticketCode = action.attendee?.code || `HP-T${action.ticket_id}`
              return (
                <div key={action.action_uuid} className="flex items-center justify-between gap-2 rounded-lg bg-neutral-50 p-2 text-xs">
                  <span className="min-w-0 break-words"><span className="block">{action.attendee?.attendee_name || 'Attendee'}</span><span className="block font-semibold text-neutral-600">{ticketCode}</span></span>
                  <button aria-label={`${action.reversed ? 'Reversed' : 'Undo'} admission for ${ticketCode}`} disabled={action.reversed} onClick={() => reverseAdmission(action)} className="flex min-h-11 min-w-11 shrink-0 items-center justify-center gap-1 rounded-lg px-3 font-semibold text-amber-700 disabled:cursor-default disabled:text-neutral-500"><RotateCcw className="h-3.5 w-3.5" /> {action.reversed ? 'Reversed' : 'Undo'}</button>
                </div>
              )
            })}
          </div>
        </section>
      )}
    </div>
  )
}
