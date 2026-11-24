import { OFFLINE_SCANNER_ACCESS_NOTE } from '../../utils/roles'
import useOperationalListing from '../../hooks/useOperationalListing'
import OperationalSearch from '../../components/OperationalSearch'
import OperationalPagination from '../../components/OperationalPagination'
import JournalRecovery from '../../components/admissions/JournalRecovery'
import SavedJournalExports from '../../components/admissions/SavedJournalExports'
import { useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react'
import {
  AlertTriangle, Camera, CheckCircle2, CloudOff, Download, Loader2, LogIn, LogOut, RefreshCw,
  RotateCcw, Search, ShieldCheck, Smartphone, StopCircle, Users, Volume2, VolumeX, XCircle,
} from 'lucide-react'
import { Link, useLocation, useSearchParams } from 'react-router-dom'
import { WORKSPACE_WIDTHS } from '../../utils/workspace'
import apiClient, { getApiAuthContext, subscribeApiAuthContext } from '../../api/client'
import { DEFAULT_EVENT_TIME_ZONE, formatEventDateTime } from '../../utils/eventTime'
import {
  applySyncResults, captureAdmissionAccessContext, captureOrganizationAdmissionContexts, currentScannerOwner, clearEventAdmissionData, loadAuthorizedScanner, loadPendingDeviceIdentity, localScanState, queueAdmission, queueExit,
  queuedActions, queueReversal, loadDevice, invalidateManifestAccess, saveDevice, saveVerifiedManifest, sha256Hex, purgeExpiredAdmissionAccess, verifyLegacyJournalOwner,
} from '../../utils/admissionStore'
import { evaluateLocalReEntry, formatGateTime, formatReEntryFeedback, serviceDayString } from '../../utils/reEntryRules'
import { scannerBindingRevision, scannerWithdrawalRevision, subscribeScannerBinding } from '../../utils/scannerAccountBinding'
import useScreenWakeLock from '../../hooks/useScreenWakeLock'
import useCameraRecovery from '../../hooks/useCameraRecovery'
import useScanSound from '../../hooks/useScanSound'
import DoorScanCard from '../../components/admissions/DoorScanCard'
import VerificationOverlay from '../../components/admissions/VerificationOverlay'
import ReEntryLeadOverride from '../../components/admissions/ReEntryLeadOverride'

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
const SCAN_PREVIEW_TIMEOUT_MS = 3000
const UNKNOWN_REFRESH_INTERVAL_MS = 5000
const scannerPolicyMessages = {
  refused: 'Reconnect and verify scanner access before scanning.',
  authorizationExpired: 'This scanner authorization expired. Reconnect before scanning.',
  manifestExpired: 'The saved ticket list is missing or expired. Reconnect before scanning.',
}
const scannerPolicyError = policy => Object.assign(new Error(scannerPolicyMessages[policy]), { scannerPolicy: policy })

function retryDelayMs(error) {
  const value = error.response?.headers?.['retry-after'] ?? error.response?.data?.retry_after
  const seconds = value == null || value === '' ? NaN : Number(value)
  const date = typeof value === 'string' && !Number.isFinite(seconds) ? Date.parse(value) : NaN
  const delay = Number.isFinite(seconds) ? seconds * 1000 : Number.isFinite(date) ? date - Date.now() : 15_000
  return Math.min(300_000, Math.max(5000, delay))
}

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

const HEADCOUNT_FORMAT = new Intl.NumberFormat('en-US')

function admissionAcknowledgement(current, receipt, timezone = DEFAULT_EVENT_TIME_ZONE) {
  const result = receipt.result || receipt.status
  const { buyer_name: _cachedBuyer, ...priorTicket } = current.ticket || {}
  const mergedTicket = receipt.ticket ? { ...priorTicket, ...receipt.ticket } : current.ticket
  let next
  if (receipt.kind === 'exit') {
    if (result === 'accepted') {
      next = {
        type: 'exit_success',
        soundKind: 'exit',
        message: 'Exit confirmed',
        detail: 'The server recorded this guest’s exit.',
        ticket: mergedTicket,
      }
    } else {
      const formatted = formatReEntryFeedback(receipt.reason_code, receipt.details, timezone)
      next = formatted
        ? { ...formatted, ticket: mergedTicket }
        : { type: result === 'conflict' ? 'warning' : 'error', message: 'Exit not recorded', detail: 'Ask a door manager to check the ticket status.', ticket: mergedTicket }
    }
  } else if (result === 'accepted') {
    const isReEntry = receipt.reason_code === 're_entered' || receipt.details?.re_entry === true
    const reEntryNum = receipt.details?.re_entry_number
    next = {
      type: 'success',
      badge: isReEntry ? (reEntryNum ? `Re-entered (#${reEntryNum})` : 'Re-entered') : null,
      message: isReEntry ? 'Re-entry confirmed' : 'Admission confirmed',
      detail: isReEntry ? 'The server confirmed this re-entry.' : 'The server confirmed this entry.',
      ticket: mergedTicket,
    }
  } else if (receipt.reason_code === 'verification_required') {
    next = { type: 'warning', message: 'This ticket needs door verification', detail: 'Scan the ticket again to review the current door instructions.' }
  } else if (receipt.reason_code === 'refund_pending') {
    next = { type: 'error', message: 'Refund pending — do not admit', detail: 'Entry is paused while this ticket’s refund is unresolved. Ask a door manager to check its current status.' }
  } else {
    const formatted = formatReEntryFeedback(receipt.reason_code, receipt.details, timezone)
    next = formatted
      ? { ...formatted, ticket: mergedTicket }
      : {
          type: result === 'conflict' ? 'warning' : 'error',
          message: receipt.reason_code === 'already_admitted' ? 'Already admitted on another device' : 'Do not admit — scan rejected',
          detail: 'The server refused this entry. Ask a door manager to check the ticket and saved scan.',
        }
  }
  // A verdict that arrives while the guest waits is the door decision. Later
  // receipts for an already-decided scan update the panel, not the overlay,
  // except a confirmation: an amber "Already scanned" overlay must not keep
  // contradicting a panel that now says "Admission confirmed", so it clears.
  const isSuccess = next.type === 'success' || next.type === 'exit_success'
  if (current.type === 'pending') return { ...current, ...next, alertType: next.type }
  return { ...current, ...next, alertType: isSuccess && current.alertType !== next.type ? undefined : current.alertType }
}

// Full-screen door feedback, readable at arm's length in a dark, loud venue.
// The result panel stays the live announcement; a held refusal is also a modal
// alert dialog so keyboard and screen-reader users meet the verdict first.
const OVERLAY_STYLES = {
  warning: ['bg-amber-500 text-neutral-950', AlertTriangle, 'Check ticket'],
  error: ['bg-red-700 text-white', XCircle, 'Do not admit'],
}
export const ADMITTED_OVERLAY_MS = 1200
// Camera reads of a code that was just decided are ignored this long after its
// result (and while it stays in view), so a guest who keeps holding up an
// admitted ticket does not trigger "Already scanned on this device".
export const SAME_CREDENTIAL_QUIET_MS = 5000
// A tap or key meant for the previous result must not clear the one that just
// replaced it, so a newly shown overlay ignores dismissal this long.
export const OVERLAY_TAP_GUARD_MS = 400
export const SCAN_RESULT_MESSAGE_ID = 'scan-result-message'

function ScanResultOverlay({ id, type, ticket, headline: customHeadline, subtext, badge, onDismiss, onGesture }) {
  const dialogRef = useRef(null)
  const buttonRef = useRef(null)
  const headlineId = useId()
  const armedRef = useRef(false)
  const [armed, setArmed] = useState(false)
  const isTransient = type === 'success' || type === 'exit_success'
  const persistent = !isTransient
  const dismiss = useCallback(() => {
    if (!armedRef.current) return
    // Each dismissal is a tap or key press, which lets iOS resume audio.
    onGesture?.()
    onDismiss(id)
  }, [id, onDismiss, onGesture])
  useEffect(() => {
    const timer = window.setTimeout(() => { armedRef.current = true; setArmed(true) }, OVERLAY_TAP_GUARD_MS)
    return () => window.clearTimeout(timer)
  }, [])
  useEffect(() => {
    if (!persistent) {
      const timer = window.setTimeout(() => onDismiss(id), ADMITTED_OVERLAY_MS)
      return () => window.clearTimeout(timer)
    }
    // Refusals wait for a tap. Keep focus inside the dialog so Enter, Space or
    // Escape dismisses it, then return focus to where staff were working.
    const button = buttonRef.current
    const previous = document.activeElement
    button?.focus({ preventScroll: true })
    const onKey = event => {
      if (event.key === 'Escape') { event.preventDefault(); dismiss() }
      else if (event.key === 'Tab') { event.preventDefault(); button?.focus({ preventScroll: true }) }
    }
    const onFocusIn = event => { if (!dialogRef.current?.contains(event.target)) button?.focus({ preventScroll: true }) }
    document.addEventListener('keydown', onKey)
    document.addEventListener('focusin', onFocusIn)
    return () => {
      document.removeEventListener('keydown', onKey)
      document.removeEventListener('focusin', onFocusIn)
      const active = document.activeElement
      if ((active === button || active === document.body || !active) && previous instanceof HTMLElement && previous.isConnected) {
        previous.focus({ preventScroll: true })
      }
    }
  }, [dismiss, id, onDismiss, persistent])
  const layout = 'flex flex-col items-center justify-center gap-4 overflow-y-auto px-6 py-8 text-center [overflow-wrap:anywhere]'
  if (!persistent) {
    const isExit = type === 'exit_success'
    // The admitted/exited flash is visual only (the panel announces it) and clears itself.
    return (
      <div aria-hidden="true" onClick={dismiss} data-testid="scan-result-overlay" data-result={type} data-armed={armed}
        className={`fixed inset-0 z-[60] overflow-y-auto ${isExit ? 'bg-sky-800' : 'bg-emerald-800'}`}>
        <div className="flex min-h-full items-center justify-center">
          <DoorScanCard ticket={ticket} exitMode={isExit} badge={badge} />
        </div>
      </div>
    )
  }
  const [classes, Icon, defaultHeadline] = OVERLAY_STYLES[type]
  const headline = customHeadline || defaultHeadline
  return (
    <div ref={dialogRef} role="alertdialog" aria-modal="true" aria-labelledby={headlineId} aria-describedby={SCAN_RESULT_MESSAGE_ID}
      data-testid="scan-result-overlay" data-result={type} data-armed={armed}
      className={`fixed inset-0 z-[60] ${classes}`}>
      <button ref={buttonRef} type="button" onClick={dismiss} aria-label={`${headline}. Dismiss scan result`}
        className={`h-full w-full focus:outline-none ${layout}`}>
        <Icon aria-hidden="true" className="h-24 w-24 shrink-0" strokeWidth={2.5} />
        <span id={headlineId} className="font-display text-4xl font-bold sm:text-6xl">{headline}</span>
        {customHeadline && subtext && <span className="max-w-lg text-xl font-bold sm:text-2xl">{subtext}</span>}
        {customHeadline && ticket?.attendee_name && <span className="max-w-lg text-lg font-semibold opacity-90">{ticket.attendee_name}</span>}
        <span aria-hidden="true" className="text-lg font-semibold">Tap to continue</span>
      </button>
    </div>
  )
}

function ResultPanel({ result, className = '', panelRef, canOverride = false, online = false, overrideBusy = false, onOverride }) {
  if (!result) return null
  const styles = {
    pending: ['bg-neutral-50 border-neutral-300 text-neutral-900', Loader2],
    success: ['bg-emerald-50 border-emerald-300 text-emerald-900', CheckCircle2],
    exit_success: ['bg-sky-50 border-sky-300 text-sky-950', LogOut],
    warning: ['bg-amber-50 border-amber-300 text-amber-900', AlertTriangle],
    verify: ['bg-amber-50 border-amber-300 text-amber-900', AlertTriangle],
    error: ['bg-red-50 border-red-300 text-red-900', XCircle],
  }
  const [classes, Icon] = styles[result.type] || styles.warning
  return (
    <div ref={panelRef} className={`rounded-2xl border-2 p-5 ${classes} ${className}`} role="status" aria-live="assertive" aria-atomic="true">
      <div className="flex gap-3">
        <Icon aria-hidden="true" className="h-7 w-7 shrink-0" />
        <div className="min-w-0 flex-1 break-words [overflow-wrap:anywhere]">
          <p id={SCAN_RESULT_MESSAGE_ID} className="text-lg font-bold">{result.message}</p>
          {result.detail && <p className="mt-1 text-sm">{result.detail}</p>}
          {result.ticket && (
            <p className="mt-2 text-sm font-medium">
              {result.ticket.attendee_name} · {result.ticket.ticket_type} · {result.ticket.code}
            </p>
          )}
          {result.type === 'success' && result.ticket?.door_fields?.length > 0 && (
            <dl className="mt-2 text-base">
              {result.ticket.door_fields.map(({ label, value }, index) => <div key={index}><dt className="inline">{label}: </dt><dd className="inline font-semibold">{value}</dd></div>)}
            </dl>
          )}
          {result.type === 'success' && result.ticket?.buyer_name && <p className="mt-2">Bought by {result.ticket.buyer_name}</p>}
          {result.type === 'success' && result.ticket?.door_instructions && <p className="mt-2">{result.ticket.door_instructions}</p>}
          {canOverride && online && result.overridable && result.ticket && onOverride && (
            <ReEntryLeadOverride
              ticket={result.ticket}
              busy={overrideBusy}
              onSubmit={onOverride}
              defaultAction="admit"
            />
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
  const [scanDirection, setScanDirection] = useState('admit')
  const [overrideBusy, setOverrideBusy] = useState(false)
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
  const [credentialBusy, setCredentialBusy] = useState(false)
  const [cameraError, setCameraError] = useState(null)
  const [sessionCount, setSessionCount] = useState(0)
  const [dismissedFeedback, setDismissedFeedback] = useState(0)
  const wakeLock = useScreenWakeLock(scanning)
  const { soundOn, toggleSound, primeSound, playScanSound } = useScanSound()

  const videoRef = useRef(null)
  const streamRef = useRef(null)
  const detectorTimerRef = useRef(null)
  const zxingControlsRef = useRef(null)
  const scanCooldownRef = useRef(false)
  // The camera read the guest is still holding up, and until when a repeat read
  // of it is ignored (Infinity while it is being checked).
  const lastDecodedRef = useRef({ code: null, until: 0 })
  const decodePausedRef = useRef(false)
  const resultPanelRef = useRef(null)
  const scanningRef = useRef(false)
  const feedbackSequenceRef = useRef(0)
  const syncingRef = useRef(false)
  const credentialInFlightRef = useRef(false)
  const unknownRefreshRef = useRef({ scope: null, after: 0 })
  const syncRetryAfterRef = useRef(0)
  const syncRetryTimerRef = useRef(null)
  const syncQueueRef = useRef(null)
  const onlineRef = useRef(online)
  onlineRef.current = online
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
  const scanRequestRef = useRef(null)
  const verificationRef = useRef(null)
  const downloadRequestRef = useRef(null)
  const dashboardRequestRef = useRef(null)
  const eventListAccessRef = useRef(null)
  const directEventAccessRef = useRef(null)
  const privateReadGenerationRef = useRef(0)
  const refusedAccessRef = useRef(new Set())
  const routeScopeRef = useRef(null)
  routeScopeRef.current = JSON.stringify([routeScope, selectionVisit])
  const cancelSyncRetry = useCallback(() => {
    window.clearTimeout(syncRetryTimerRef.current)
    syncRetryTimerRef.current = null
    syncRetryAfterRef.current = 0
  }, [])

  useEffect(() => {
    const abortReads = () => {
      cancelSyncRetry()
      ++privateReadGenerationRef.current
      searchRequestRef.current?.abort()
      scanRequestRef.current?.abort()
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
  }, [eventId, location.key, cancelSyncRetry])

  useEffect(() => {
    mountedRef.current = true
    return () => { mountedRef.current = false; setupGenerationRef.current += 1; cancelSyncRetry() }
  }, [cancelSyncRetry])

  useEffect(() => cancelSyncRetry, [eventId, device?.id, online, cancelSyncRetry])

  const ticketsByHash = useMemo(
    () => new Map((manifest?.payload?.tickets || []).map(ticket => [ticket.credential_hash, ticket])),
    [manifest],
  )
  const ticketsById = useMemo(
    () => new Map((manifest?.payload?.tickets || []).map(ticket => [Number(ticket.ticket_id), ticket])),
    [manifest],
  )

  const refreshPending = useCallback(async (selectedEventId, selectedDevice) => {
    if (!selectedEventId || !selectedDevice) {
      setPendingCount(0)
      return
    }
    const items = await queuedActions(selectedEventId, selectedDevice.id)
    if (eventIdRef.current === String(selectedEventId)) {
      setPendingCount(items.length)
    }
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
    cancelSyncRetry()
    credentialInFlightRef.current = false
    setCredentialBusy(false)
    ++setupGenerationRef.current
    ++presentationRef.current
    ++privateReadGenerationRef.current
    searchRequestRef.current?.abort()
    scanRequestRef.current?.abort()
    verificationRef.current = null
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
    setScanDirection('admit')
    setError(null)
    setSetupBusy(true)
  }, [stopCamera, cancelSyncRetry])

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
      for (const ref of [searchRequestRef, scanRequestRef, downloadRequestRef, dashboardRequestRef, eventListAccessRef, directEventAccessRef]) {
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
    for (const ref of [searchRequestRef, scanRequestRef, downloadRequestRef, dashboardRequestRef, directEventAccessRef]) ref.current?.abort()
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
      response = await apiClient.get(`/organizer/events/${selectedEventId}/scanner_devices/${selectedDevice.id}/manifest`, { timeout: 8000 })
    } catch (manifestError) {
      manifestError.manifestUnavailable = manifestError.response?.status === 422
      if ([401, 403, 404, 410].includes(manifestError.response?.status)) {
        const removed = await purgeExpiredAdmissionAccess(selectedEventId, { context })
        manifestError.scannerAccessRefused = true
        manifestError.scannerAccessPurged = removed && current()
        if (manifestError.scannerAccessPurged) { currentManifestRef.current = null; setDevice(null); setManifest(null); setRecoveryDevice(null) }
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
    if (current()) { currentManifestRef.current = verified; setManifest(verified) }
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
    if (!['admit', 'exit'].includes(context.kind) || !context.ticketId) return
    // Queue deletion and the terminal admit/exit receipt commit atomically. Re-read
    // after observing empty, including an ACK from a different browser tab.
    const receipt = await localScanState(selectedEventId, context.ticketId)
    if (!current() || receipt?.action_uuid !== context.uuid || !['accepted', 'exited', 'conflict', 'rejected'].includes(receipt.status)) return
    const normalized = receipt.status === 'exited' ? { ...receipt, status: 'accepted', kind: 'exit' } : { ...receipt, kind: context.kind }
    const tz = currentManifestRef.current?.payload?.event?.timezone || DEFAULT_EVENT_TIME_ZONE
    setScanResult(existing => current() && existing?.actionUuid === context.uuid && existing.actionKind === context.kind
      ? admissionAcknowledgement(existing, normalized, tz) : existing)
  }, [])

  const syncQueue = useCallback(async ({ selectedEventId = eventId, selectedDevice = device, quiet = false, automaticRetry = false } = {}) => {
    if (!selectedEventId || !selectedDevice || selectedDevice.owner_user_id !== currentScannerOwner() || !online || syncingRef.current || (quiet && Date.now() < syncRetryAfterRef.current)) return
    const owner = currentScannerOwner()
    const generation = setupGenerationRef.current
    const auth = getApiAuthContext()
    const organizationId = window.localStorage.getItem('hafapass_organization_id')
    const current = () => mountedRef.current && owner === currentScannerOwner() && eventIdRef.current === String(selectedEventId)
      && generation === setupGenerationRef.current && auth === getApiAuthContext()
      && organizationId === window.localStorage.getItem('hafapass_organization_id')
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
      let refreshRequired = false
      while (remaining.length) {
        if (!await ownsJournal()) return
        const batch = remaining.slice(0, 500)
        refreshRequired ||= batch.some(action => action.kind === 'reverse')
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
        refreshRequired ||= results.some(result => result.result === 'rejected' && result.reason_code === 'verification_required')
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
          const tz = currentManifestRef.current?.payload?.event?.timezone || DEFAULT_EVENT_TIME_ZONE
          return admissionAcknowledgement(current, result, tz)
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
        if (eventIdRef.current === String(selectedEventId)) setDashboard(current => {
          if (!current) return current
          const reversed = new Set(batch.filter(action => action.kind === 'reverse' && results.some(result =>
            result.action_uuid === action.action_uuid && (result.result === 'accepted' || result.reason_code === 'already_reversed')))
            .map(action => action.reverses_action_uuid))
          const recent = new Map((current.recent_actions || []).map(action => [action.action_uuid,
            reversed.has(action.action_uuid) ? { ...action, reversed: true } : action]))
          for (const result of results) recent.set(result.action_uuid, { ...recent.get(result.action_uuid), ...result, device_name: currentDevice.name })
          return { ...current, counts: response.data.summary,
            recent_actions: [...recent.values()].sort((a, b) => String(b.received_at || '').localeCompare(String(a.received_at || ''))).slice(0, 50) }
        })
        remaining = pendingAfterSync
      }
      if (!await ownsJournal()) return
      cancelSyncRetry()
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
      if (!quiet || refreshRequired) await Promise.all([downloadManifest(selectedEventId, currentDevice), fetchDashboard(selectedEventId)])
    } catch (syncError) {
      if (!current()) return
      if (syncError.response?.status === 429 || !syncError.response || syncError.response.status >= 500) {
        const delay = retryDelayMs(syncError)
        window.clearTimeout(syncRetryTimerRef.current)
        syncRetryTimerRef.current = null
        syncRetryAfterRef.current = Date.now() + delay
        // One automatic follow-up per user/connectivity attempt. A continuing
        // outage retains the journal for manual retry rather than polling.
        if (!automaticRetry) syncRetryTimerRef.current = window.setTimeout(async () => {
          syncRetryTimerRef.current = null
          if (!current() || !onlineRef.current || hasStoredRefusal(owner, selectedEventId)) return
          try {
            const access = await loadAuthorizedScanner(selectedEventId)
            if (!current() || !onlineRef.current || access?.device.id !== selectedDevice.id) return
            void syncQueueRef.current?.({ selectedEventId, selectedDevice: access.device, quiet: true, automaticRetry: true })
          } catch { /* Keep the journal if storage or access cannot be verified. */ }
        }, delay)
      }
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
      } else if ([401, 403, 404, 410, 422].includes(syncError.response?.status) && !syncError.manifestUnavailable) {
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
  }, [device, downloadManifest, eventId, fetchDashboard, refreshPending, online, reconcileStoredResult, cancelSyncRetry])
  syncQueueRef.current = syncQueue

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
        let manifestRequest = false
        let failureContext = await captureAdmissionAccessContext(selectedEventId, { isCurrent: current })
        try {
          if (!current()) return
          let previousIdentity = await loadPendingDeviceIdentity(selectedEventId)
          if (!current()) return
          if (!previousIdentity) {
            await verifyLegacyJournalOwner({ isCurrent: current })
            if (!current()) return
            previousIdentity = await loadPendingDeviceIdentity(selectedEventId)
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
          manifestRequest = true
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
          if ([401, 403, 404, 410].includes(connectionError.response?.status)
            || (connectionError.response?.status === 422 && !manifestRequest)) {
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
    verificationRef.current = result.verification || null
    // Record ownership synchronously; a peer ACK need not wait for React to render.
    resultContextRef.current = result.actionUuid ? { uuid: result.actionUuid, kind: result.actionKind,
      ticketId: result.ticket?.ticket_id, deviceId: result.deviceId, owner: currentScannerOwner(), eventId: eventIdRef.current,
      generation: setupGenerationRef.current, presentation: presentationRef.current } : null
    // Every shown result is a new door decision; a pending admission gets its
    // alert when the verdict arrives (admissionAcknowledgement).
    const alertType = result.type !== 'pending' && result.actionKind !== 'reverse' ? result.type : undefined
    setScanResult({ ...result, feedbackId: ++feedbackSequenceRef.current, alertType })
    if (result.type === 'success' || result.type === 'exit_success' || (result.type === 'pending' && ['admit', 'exit'].includes(result.actionKind))) setSessionCount(count => count + 1)
  }, [])

  // Sound and vibration fire once per door decision (iOS has no vibration).
  const alertKey = scanResult?.alertType ? `${scanResult.feedbackId}:${scanResult.alertType}:${scanResult.soundKind || ''}` : null
  useEffect(() => {
    if (!alertKey) return
    const soundKind = scanResult?.soundKind
    if (soundKind === 'already_inside') {
      playScanSound('already_inside')
      if (navigator.vibrate) navigator.vibrate([120, 50, 120, 50, 180])
      return
    }
    if (soundKind === 'exit' || scanResult?.alertType === 'exit_success') {
      playScanSound('exit')
      if (navigator.vibrate) navigator.vibrate([50, 40, 50])
      return
    }
    const success = scanResult?.alertType === 'success'
    playScanSound(success ? 'admit' : scanResult?.alertType === 'verify' ? 'verify' : 'refuse')
    if (navigator.vibrate) navigator.vibrate(success ? 80 : [100, 60, 100])
  }, [alertKey, playScanSound, scanResult?.alertType, scanResult?.soundKind])
  const overlay = scanResult?.alertType && scanResult.feedbackId !== dismissedFeedback
    ? { id: scanResult.feedbackId, type: scanResult.alertType, headline: scanResult.headline, subtext: scanResult.headline ? scanResult.message : null, badge: scanResult.badge } : null
  const verification = scanResult?.verification
  useLayoutEffect(() => {
    if (!verification || !device || !manifest) verificationRef.current = null
    if (verification && (!device || !manifest)) setScanResult(null)
  }, [verification, device, manifest])

  // While a refusal or warning holds the screen, the camera stops deciding, so
  // the next guest cannot be admitted unseen behind it. If the held result came
  // from a code still in front of the camera, it stays ignored for a few
  // seconds after the dismissal tap too.
  const holdsDoor = Boolean(overlay && overlay.type !== 'success' && overlay.type !== 'exit_success')
  useEffect(() => {
    if (!holdsDoor) return undefined
    decodePausedRef.current = true
    const recent = lastDecodedRef.current
    const live = Boolean(recent.code) && recent.until > Date.now()
    return () => {
      decodePausedRef.current = false
      if (live && lastDecodedRef.current === recent) recent.until = Math.max(recent.until, Date.now() + SAME_CREDENTIAL_QUIET_MS)
    }
  }, [holdsDoor])

  // In landscape the result panel can sit below the camera; bring it into view
  // when a camera scan produces a result.
  scanningRef.current = scanning
  const feedbackId = scanResult?.feedbackId
  useEffect(() => {
    if (!feedbackId || !scanningRef.current) return
    resultPanelRef.current?.scrollIntoView?.({ block: 'nearest', behavior: 'instant' })
  }, [feedbackId])

  const admitEntry = useCallback(async (ticket, hash, startedAt, clientStatus, presentation, scanManifest, { confirmed = false, forceOffline = false } = {}) => {
    if (!device || !scanManifest || eventIdRef.current !== eventId || currentManifestRef.current?.digest !== scanManifest.digest) return
    const owner = currentScannerOwner()
    if (!owner || device.owner_user_id !== owner) return
    const accessRefused = () => refusedAccessRef.current.has(JSON.stringify([owner, String(eventId)])) || hasStoredRefusal(owner, eventId)
    if (accessRefused()) {
      showResult({ type: 'error', message: 'Scanner access needs verification', detail: 'Reconnect and verify access before admitting another guest.' })
      return
    }
    const generation = setupGenerationRef.current
    const current = () => mountedRef.current && owner && device.owner_user_id === owner && owner === currentScannerOwner()
      && eventIdRef.current === eventId && generation === setupGenerationRef.current && presentation === presentationRef.current
    const accessExpired = () => !device.effective || Date.parse(device.authorization_expires_at) <= Date.now()
      || Date.parse(scanManifest.payload.expires_at) <= Date.now()
    if (accessExpired()) {
      try {
        const context = await captureAdmissionAccessContext(eventId, { isCurrent: current,
          expectedDevice: device, expectedManifest: scanManifest })
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
    if (!current() || accessRefused()) return

    const manifestEvent = scanManifest.payload?.event || {}
    const reEntryMode = manifestEvent.re_entry_mode || 'off'
    const tz = manifestEvent.timezone || DEFAULT_EVENT_TIME_ZONE
    const effectiveKind = reEntryMode === 'exit_scan' && scanDirection === 'exit' ? 'exit' : 'admit'

    if (reEntryMode === 'off' && ['pending', 'accepted', 'conflict', 'pending_reverse'].includes(localState?.status)) {
      showResult({ type: 'warning', message: 'Already scanned on this device', detail: 'This ticket is already admitted or waiting to sync.', ticket,
        ...(localState.status === 'pending' ? { actionUuid: localState.action_uuid, actionKind: 'admit', deviceId: device.id } : {}),
        latency: performance.now() - startedAt })
      return
    }
    if (reEntryMode !== 'off' && localState?.status === 'pending_reverse') {
      showResult({ type: 'warning', message: 'Undo pending on this device', detail: 'Wait for the pending Undo to sync before scanning this ticket again.', ticket,
        latency: performance.now() - startedAt })
      return
    }

    let doorTicket = ticket
    let source = online && !forceOffline ? 'online' : 'offline'
    let needsManifestState = !confirmed || source === 'offline'
    let isReEntry = false
    let reEntryNumber = 0
    if (source === 'online' && !confirmed && scanManifest.payload.schema_version === 2) {
      const request = beginPrivateRead(scanRequestRef, eventId)
      const accessOptions = {
        isCurrent: request.current, expectedDevice: device, expectedManifest: scanManifest,
      }
      const context = await captureAdmissionAccessContext(eventId, accessOptions)
      if (!current() || !request.current()) return
      let preview
      try {
        const response = await apiClient.post(`/organizer/events/${eventId}/scanner_devices/${device.id}/scan`, {
          ticket_id: ticket.ticket_id,
          credential_hash: hash,
          manifest_version: scanManifest.payload.version,
          ...(effectiveKind === 'exit' ? { kind: 'exit' } : {}),
        }, { ...request.config, timeout: SCAN_PREVIEW_TIMEOUT_MS })
        preview = response.data
      } catch (scanError) {
        if (!current() || !request.current() || scanError.code === 'ERR_CANCELED' || scanError.name === 'AbortError') return
        const status = scanError.response?.status
        if (status >= 400 && status < 500 && status !== 408 && status !== 429) {
          await handlePrivateReadError(scanError, request, context, 'The server refused this scan. Ask a door manager to check the ticket.')
          throw scanError
        }
        // Error responses can refuse a scan, but only a successful response can
        // supply an online approval or verification instruction.
        if (scanError.response?.data?.status === 'rejected') preview = scanError.response.data
      }
      if (!current() || !request.current()) return
      if (preview?.status === 'rejected') {
        const reason = preview.reason_code
        const reEntryFeedback = formatReEntryFeedback(reason, preview.details, tz)
        if (reEntryFeedback) {
          showResult({ ...reEntryFeedback, ticket: preview.ticket || ticket, latency: performance.now() - startedAt })
          return
        }
        const labels = { already_admitted: 'Already admitted', cancelled: 'Cancelled ticket', credential_revoked: 'Ticket credential is no longer valid',
          transferred: 'Transferred ticket', payment_blocked: 'Payment blocked', refund_pending: 'Refund pending — do not admit' }
        showResult({ type: reason === 'already_admitted' ? 'warning' : 'error', message: labels[reason] || 'Invalid ticket',
          detail: 'Ask a door manager to check the ticket before admitting.', ticket: preview.ticket || ticket, latency: performance.now() - startedAt })
        return
      }
      const modeByStatus = { ready: 'instant', verification_required: 'verify' }
      const mode = modeByStatus[preview?.status]
      if (mode && preview.ticket?.ticket_id === ticket.ticket_id && (effectiveKind === 'exit' || preview.ticket.door_check_mode === mode)) {
        doorTicket = preview.ticket
        needsManifestState = false
        isReEntry = preview.re_entry === true
        reEntryNumber = Number(preview.re_entry_number || 0)
      } else {
        // Re-check the same grant and signed list after the network wait.
        await captureAdmissionAccessContext(eventId, accessOptions)
        if (!request.current()) return
        source = 'offline'
      }
    }
    if (!current() || accessRefused()) return
    if (source === 'offline' && accessExpired()) throw scannerPolicyError('manifestExpired')

    if (needsManifestState) {
      if (reEntryMode === 'off') {
        if (ticket.state !== 'valid') {
          const labels = { admitted: 'Already admitted', cancelled: 'Cancelled ticket', transferred: 'Transferred ticket', payment_blocked: 'Payment blocked', refund_pending: 'Refund pending — do not admit' }
          showResult({ type: ticket.state === 'admitted' ? 'warning' : 'error', message: labels[ticket.state] || 'Ticket is not valid',
            detail: 'Sync the latest ticket list or ask a door manager for help.', ticket, latency: performance.now() - startedAt })
          return
        }
      } else {
        const localEval = evaluateLocalReEntry({
          kind: effectiveKind,
          manifestTicket: ticket,
          localState,
          eventMeta: manifestEvent,
        })
        if (!localEval.allowed) {
          const formatted = formatReEntryFeedback(localEval.reasonCode, localEval.details, tz)
          if (formatted) {
            showResult({ ...formatted, ticket, latency: performance.now() - startedAt })
            return
          }
          const labels = { cancelled: 'Cancelled ticket', transferred: 'Transferred ticket', payment_blocked: 'Payment blocked', refund_pending: 'Refund pending — do not admit' }
          showResult({ type: 'error', message: labels[localEval.reasonCode] || 'Ticket is not valid',
            detail: 'Sync the latest ticket list or ask a door manager for help.', ticket, latency: performance.now() - startedAt })
          return
        }
        isReEntry = localEval.isReEntry
        reEntryNumber = localEval.reEntryNumber
      }
    }

    if (currentManifestRef.current?.digest !== scanManifest.digest) {
      showResult({ type: 'warning', message: 'Ticket list updated', detail: 'Scan this ticket again to use the updated event list.' })
      return
    }
    if (effectiveKind === 'admit' && !confirmed && !isReEntry && doorTicket.door_check_mode === 'verify') {
      showResult({ type: 'verify', message: 'Verify this ticket before admitting', ticket: doorTicket,
        verification: { ticket: { ...doorTicket, state: ticket.state }, hash, clientStatus, presentation, scanManifest, source } })
      return
    }

    if (effectiveKind === 'exit') {
      const action = await queueExit({
        eventId,
        deviceId: device.id,
        manifestVersion: scanManifest.payload.version,
        ticket,
        credentialHash: hash,
        source,
        clientStatus: source === 'online' ? 'online_exit' : 'locally_exited',
        eventTimezone: tz,
        eventMeta: scanManifest.payload.event,
        reEntryCount: Number(ticket.re_entry_count || 0),
      })
      if (!current()) return
      showResult({
        type: source === 'online' ? 'pending' : 'exit_success',
        soundKind: source === 'online' ? undefined : 'exit',
        message: source === 'online' ? 'Recording exit…' : 'Exited offline',
        actionUuid: action.action_uuid,
        actionKind: 'exit',
        deviceId: device.id,
        detail: source === 'online'
          ? 'Saved on this device. Waiting for server confirmation.'
          : 'Saved on this device. Sync when connected so other gates see this exit.',
        ticket: doorTicket,
        latency: performance.now() - startedAt,
      })
      await refreshPending(eventId, device)
      if (!current()) return
      const receipt = await localScanState(eventId, ticket.ticket_id)
      if (!current()) return
      if (receipt?.action_uuid === action.action_uuid && ['exited', 'conflict', 'rejected'].includes(receipt.status)) {
        const normalized = receipt.status === 'exited' ? { ...receipt, status: 'accepted', kind: 'exit' } : { ...receipt, kind: 'exit' }
        setScanResult(existing => current() && existing?.actionUuid === action.action_uuid && existing.actionKind === 'exit'
          ? admissionAcknowledgement(existing, normalized, tz) : existing)
      }
      if (online && current()) syncQueue({ quiet: true })
      return
    }

    const action = await queueAdmission({
      eventId,
      deviceId: device.id,
      manifestVersion: scanManifest.payload.version,
      ticket,
      credentialHash: hash,
      source,
      clientStatus,
      reEntryMode,
      eventTimezone: tz,
      eventMeta: scanManifest.payload.event,
      isReEntry,
      reEntryNumber,
      ...(confirmed ? { confirmed: true } : {}),
    })
    if (!current()) return
    if (!action) {
      showResult({ type: 'warning', message: 'Already scanned on this device', detail: 'This ticket is already admitted or waiting to sync.', ticket })
      return
    }
    // Own the result before count refresh yields to an already-running sync.
    showResult({
      type: source === 'online' ? 'pending' : 'success',
      badge: isReEntry ? (reEntryNumber ? `Re-entered (#${reEntryNumber})` : 'Re-entered') : null,
      message: source === 'online' ? 'Waiting for server confirmation' : (isReEntry ? 'Re-entered offline' : 'Admitted offline'),
      actionUuid: action.action_uuid,
      actionKind: 'admit',
      deviceId: device.id,
      detail: source === 'online' ? 'Saved on this device. Entry is not confirmed until the server responds.' : 'Saved on this device. Other offline scanners cannot see this admission until they sync.',
      ticket: doorTicket,
      latency: performance.now() - startedAt,
    })
    await refreshPending(eventId, device)
    if (!current()) return
    // Another tab can acknowledge the transaction before queueAdmission returns.
    // Only this command's durable terminal receipt can resolve its presentation.
    const receipt = await localScanState(eventId, ticket.ticket_id)
    if (!current()) return
    if (receipt?.action_uuid === action.action_uuid && ['accepted', 'conflict', 'rejected'].includes(receipt.status)) {
      setScanResult(existing => current() && existing?.actionUuid === action.action_uuid && existing.actionKind === 'admit'
        ? admissionAcknowledgement(existing, receipt, tz) : existing)
    }
    if (online && current()) syncQueue({ quiet: true })
  }, [device, eventId, refreshPending, showResult, syncQueue, online, beginPrivateRead, handlePrivateReadError, scanDirection])

  const processCredential = useCallback(async (raw, lookupTicket) => {
    if (credentialInFlightRef.current || verificationRef.current) return
    const startedAt = performance.now()
    const presentation = ++presentationRef.current
    const owner = currentScannerOwner()
    if (!owner || device?.owner_user_id !== owner) return
    const generation = setupGenerationRef.current
    const current = () => mountedRef.current && owner && device?.owner_user_id === owner && owner === currentScannerOwner()
      && eventIdRef.current === eventId && generation === setupGenerationRef.current && presentation === presentationRef.current
    const credentialOwner = Symbol('credential')
    credentialInFlightRef.current = credentialOwner
    setCredentialBusy(true)
    try {
      if (lookupTicket) {
        await admitEntry(lookupTicket, lookupTicket.credential_hash, startedAt, 'manual_lookup', presentation, manifest)
        return
      }
      if (refusedAccessRef.current.has(JSON.stringify([owner, String(eventId)])) || hasStoredRefusal(owner, eventId)) throw scannerPolicyError('refused')
      if (!device?.effective || new Date(device.authorization_expires_at).getTime() <= Date.now()) {
        throw scannerPolicyError('authorizationExpired')
      }
      if (!manifest || new Date(manifest.payload.expires_at).getTime() <= Date.now()) {
        throw scannerPolicyError('manifestExpired')
      }
      const hash = await sha256Hex(credentialValue(raw))
      if (!current() || currentManifestRef.current?.digest !== manifest.digest) return
      let ticket = ticketsByHash.get(hash)
      let scanManifest = manifest
      if (!ticket && online) {
        const scope = JSON.stringify([owner, eventId, device.id])
        if (unknownRefreshRef.current.scope === scope && Date.now() < unknownRefreshRef.current.after) {
          showResult({ type: 'warning', message: 'Ticket not verified yet', detail: 'Ticket-list refresh is paused briefly. Wait a few seconds and retry, or use Sync now. Do not admit until verified.' })
          return
        }
        unknownRefreshRef.current = { scope, after: Date.now() + UNKNOWN_REFRESH_INTERVAL_MS }
        showResult({ type: 'pending', message: 'Checking the latest ticket list', detail: 'Keep this guest at the gate while this ticket is verified.' })
        try {
          scanManifest = await downloadManifest(eventId, device)
        } catch (refreshError) {
          unknownRefreshRef.current.after = Date.now() + retryDelayMs(refreshError)
          throw refreshError
        }
        if (!current() || !scanManifest || currentManifestRef.current?.digest !== scanManifest.digest) return
        ticket = scanManifest.payload.tickets.find(entry => entry.credential_hash === hash)
      }
      if (!ticket) {
        showResult({ type: 'error', message: 'Invalid ticket', detail: 'This QR code is not in the verified ticket list for this event.',
          latency: performance.now() - startedAt })
        return
      }
      await admitEntry(ticket, hash, startedAt, 'locally_accepted', presentation, scanManifest)
    } catch (scanError) {
      const policyMessage = Object.hasOwn(scannerPolicyMessages, scanError.scannerPolicy) ? scannerPolicyMessages[scanError.scannerPolicy] : null
      if (current()) showResult({ type: 'error', message: policyMessage ? 'Scanner access needs verification' : 'Scanner unavailable', detail: policyMessage || 'Ticket could not be verified. Do not admit yet. Retry while connected or ask a door manager. Saved scans remain on this device.', latency: performance.now() - startedAt })
    } finally {
      if (credentialInFlightRef.current === credentialOwner) {
        credentialInFlightRef.current = false
        if (mountedRef.current) setCredentialBusy(false)
      }
    }
  }, [admitEntry, device, downloadManifest, eventId, manifest, online, showResult, ticketsByHash])

  const cancelVerification = () => {
    if (!verificationRef.current || credentialInFlightRef.current) return
    verificationRef.current = null
    ++presentationRef.current
    setScanResult(null)
  }

  const confirmVerification = async () => {
    const held = verificationRef.current
    if (!held || credentialInFlightRef.current) return
    primeSound()
    const credentialOwner = Symbol('confirmation')
    credentialInFlightRef.current = credentialOwner
    setCredentialBusy(true)
    try {
      await admitEntry(held.ticket, held.hash, performance.now(), held.clientStatus, held.presentation, held.scanManifest, {
        confirmed: true, forceOffline: held.source === 'offline',
      })
      if (verificationRef.current === held) {
        showResult({ type: 'warning', message: 'Scan the ticket again', detail: 'The ticket list or scanner access changed during verification.' })
      }
    } catch {
      if (verificationRef.current === held) showResult({ type: 'error', message: 'Could not confirm entry', detail: 'Check the ticket status before trying again.' })
    } finally {
      if (credentialInFlightRef.current === credentialOwner) {
        credentialInFlightRef.current = false
        if (mountedRef.current) setCredentialBusy(false)
      }
    }
  }

  processCredentialRef.current = processCredential

  const handleDecoded = useCallback(code => {
    if (!code || decodePausedRef.current || verificationRef.current) return
    const recent = lastDecodedRef.current
    if (recent.code === code && Date.now() < recent.until) {
      // Same guest still holding the code up: keep ignoring it until it has
      // been out of view for SAME_CREDENTIAL_QUIET_MS. Manual entry is unaffected.
      if (recent.until !== Infinity) recent.until = Date.now() + SAME_CREDENTIAL_QUIET_MS
      return
    }
    if (scanCooldownRef.current) return
    scanCooldownRef.current = true
    const entry = { code, until: Infinity }
    lastDecodedRef.current = entry
    processCredentialRef.current(code).finally(() => {
      if (lastDecodedRef.current === entry) entry.until = Date.now() + SAME_CREDENTIAL_QUIET_MS
      setTimeout(() => { scanCooldownRef.current = false }, 1800)
    })
  }, [])

  const startCamera = useCallback(async () => {
    const generation = ++cameraGenerationRef.current
    lastDecodedRef.current = { code: null, until: 0 }
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
          if (!videoRef.current || scanCooldownRef.current || decodePausedRef.current || verificationRef.current) return
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

  useCameraRecovery({
    scanning, videoRef,
    restart: () => { stopCamera(); startCamera() },
    onGiveUp: () => {
      stopCamera()
      setCameraError('The camera stopped. Tap Start camera to try again, or use manual entry.')
    },
  })

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

  const submitLeadOverride = async ({ ticketId, overrideAction, reason }) => {
    if (!eventId || !online || overrideBusy) return false
    setOverrideBusy(true)
    setError(null)
    try {
      const response = await apiClient.post(`/organizer/events/${eventId}/admissions/override`, {
        ticket_id: ticketId,
        override_action: overrideAction,
        reason,
        scanner_device_id: device?.id,
        action_uuid: crypto.randomUUID(),
      })
      const updatedSummary = response.data?.summary
      const updatedTicket = response.data?.ticket
      setDashboard(current => current ? {
        ...current,
        counts: updatedSummary || current.counts,
        flagged_conflicts: (current.flagged_conflicts || []).filter(item => Number(item.id) !== Number(ticketId)),
      } : current)
      if (device) await downloadManifest(eventId, device).catch(() => {})
      showResult({
        type: overrideAction === 'clear' ? 'exit_success' : 'success',
        soundKind: overrideAction === 'clear' ? 'exit' : undefined,
        badge: overrideAction === 'admit' ? 'Lead override' : null,
        message: overrideAction === 'admit' ? 'Lead override: admitted' : 'Lead override: inside status cleared',
        detail: `Recorded in audit log (${reason}).`,
        ticket: updatedTicket || scanResult?.ticket,
      })
      return true
    } catch (overrideError) {
      setError(overrideError.response?.data?.error || 'Could not record lead override. Check your permissions and try again.')
      return false
    } finally {
      setOverrideBusy(false)
    }
  }

  const selectedEvent = events.find(event => String(event.id) === eventId) || (String(resolvedEvent?.id) === eventId ? resolvedEvent : null)
  const ready = Boolean(eventId && device && manifest && Number(manifest.payload?.event?.id) === Number(eventId))
  const reEntryMode = manifest?.payload?.event?.re_entry_mode || dashboard?.event?.re_entry_mode || selectedEvent?.re_entry_mode || 'off'
  const reEntryEnabled = reEntryMode !== 'off'
  const isExitScanMode = reEntryMode === 'exit_scan'
  const isCooldownMode = reEntryMode === 'cooldown'
  const effectiveDirection = isExitScanMode ? scanDirection : 'admit'
  const canOverride = reEntryEnabled && dashboard?.permissions?.can_override === true
  const baseHeadcount = reEntryEnabled ? (dashboard?.counts?.live_headcount ?? dashboard?.counts?.currently_inside ?? null) : null
  const untrackedPreReEntry = reEntryEnabled ? Number(dashboard?.counts?.untracked_pre_re_entry_admits || 0) : 0
  const liveHeadcount = baseHeadcount != null ? Math.max(0, Number(baseHeadcount)) : null
  const headcountByDay = reEntryEnabled ? (dashboard?.counts?.headcount_by_day || []) : []
  const currentServiceDay = serviceDayString(Date.now(), manifest?.payload?.event || dashboard?.event || selectedEvent)
  const flaggedConflicts = reEntryEnabled ? (dashboard?.flagged_conflicts || []) : []
  useEffect(() => {
    if (!isExitScanMode && scanDirection !== 'admit') setScanDirection('admit')
  }, [isExitScanMode, scanDirection])
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
  // Only this exact API refusal describes missing team membership. Other
  // authorization failures remain errors, and still use the refusal path above.
  const membershipRequired = error === 'Organization membership required'
  const noAssignedEvents = !eventListLoading && !setupBusy && !error && !eventListError && !events.length && !eventId

  // This is presentation only: the refusal pipeline above still withdraws and
  // quarantines access. An event selection or verified offline grant must not be
  // hidden just because the current search page has no matching assignments.
  const noScanAuthority = !ready && !events.length && !resolvedEvent
    && (membershipRequired || (noAssignedEvents && !listing.q && !offlineOnly))

  if (noScanAuthority) return (
    <div className={`mx-auto w-full min-w-0 ${WORKSPACE_WIDTHS.standard} space-y-4 px-4 py-4 sm:px-6 sm:py-8 lg:px-8`}>
      <h1 className="font-display text-2xl font-bold text-neutral-950 sm:text-3xl">Check-in</h1>
      <section role="status" className="max-w-2xl rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-sm text-neutral-700">
        <h2 className="font-semibold text-neutral-900">{membershipRequired ? 'Join the event’s door team' : 'No events are assigned to this account.'}</h2>
        <p className="mt-1">Scanning is for an organizer’s team and door staff.</p>
        <p className="mt-1">Ask the event’s organizer to add you as door staff. If they send an invitation, accept it using this account.</p>
        <Link to="/dashboard" className="mt-2 inline-flex min-h-11 items-center font-semibold text-brand-700 underline">Open organizer workspace</Link>
      </section>
      <SavedJournalExports owner={currentScannerOwner()} pendingCount={pendingCount} eventId={eventId} recovery />
      <p className="flex items-center gap-2 text-sm font-semibold text-neutral-700">{online ? <ShieldCheck aria-hidden="true" className="h-4 w-4" /> : <CloudOff aria-hidden="true" className="h-4 w-4" />}{online ? 'Online' : 'Offline mode'}</p>
    </div>
  )

  // The DOM follows the phone order: event, door status, camera, door totals,
  // then the remaining tools. From the sm breakpoint explicit grid placement
  // restores the two-column desktop arrangement (rows 1-3 header, 4-6 status,
  // notices and tool links, 7-10 the camera and side column).
  return (
    <div className={`mx-auto flex w-full min-w-0 ${WORKSPACE_WIDTHS.standard} flex-col gap-3 px-4 py-4 sm:grid sm:px-6 lg:px-8 sm:grid-cols-[minmax(0,1fr)_minmax(0,24rem)] sm:gap-x-4 sm:gap-y-0 sm:py-8 lg:grid-cols-[minmax(0,1.35fr)_minmax(0,.65fr)] lg:grid-rows-[repeat(8,auto)_1fr_auto] lg:gap-x-6`}>
      <div className={`${isExitScanMode ? 'order-1 sm:order-none ' : ''}sm:col-start-1 sm:row-start-1 sm:min-w-0 sm:max-w-2xl sm:self-end`}>
        <div className="flex items-center justify-between gap-3 sm:flex-col-reverse sm:items-start sm:gap-0">
          <h1 className="font-display text-2xl font-bold text-neutral-950 sm:text-3xl">Check-in</h1>
          <Link to="/dashboard" className="inline-flex min-h-11 items-center text-sm font-medium text-brand-800">All events</Link>
        </div>
        {selectedEvent && <p className="mt-2 hidden break-words text-base font-semibold text-neutral-900 sm:block">{selectedEvent.title}</p>}
      </div>
      <div className={`${isExitScanMode ? 'order-2 sm:order-none ' : ''}sm:col-start-2 sm:row-start-2`}>
        {!offlineOnly && eventListLoading && <p role="status" className="mb-2 text-sm">Loading events…</p>}
        {!offlineOnly && eventListError && <p role="alert" className="mb-2 text-sm text-red-800">{eventListError} <button type="button" className="min-h-11 underline" onClick={() => setEventListRetry(value => value + 1)}>Retry event search</button></p>}
        <label htmlFor="scanner-event" className="mb-1 block text-sm font-medium text-neutral-800">Event to scan</label>
        <select id="scanner-event" disabled={eventListLoading} value={eventId} onChange={event => setSearchParams(previous => { const next = new URLSearchParams(previous); next.set('event', event.target.value); next.delete('lookup'); return next })} className="input w-full">
          {!eventId && <option value="">{events.length ? 'Choose an assigned event' : 'No assigned events'}</option>}
          {selectedEvent && !events.some(event => String(event.id) === eventId) && <option value={eventId}>{selectedEvent.title} (selected)</option>}
          {events.map(event => <option key={event.id} value={event.id}>{event.title}</option>)}
        </select>
      </div>

      <div className={`${isExitScanMode ? 'order-4 sm:order-none ' : ''}grid gap-2 sm:col-span-2 sm:row-start-4 sm:mb-4 sm:mt-5 ${liveHeadcount != null ? 'grid-cols-2 sm:grid-cols-5' : 'grid-cols-4'}`} aria-label="Check-in status">
        <div className={`flex items-center rounded-xl border p-2 sm:block sm:p-3 ${online ? 'border-emerald-200 bg-emerald-50' : 'border-amber-200 bg-amber-50'}`}>
          <p className="flex flex-col items-start gap-1 text-xs font-semibold sm:flex-row sm:items-center sm:gap-2 sm:text-sm">{online ? <ShieldCheck className={liveHeadcount != null ? 'h-4 w-4 shrink-0' : 'h-4 w-4'} /> : <CloudOff className={liveHeadcount != null ? 'h-4 w-4 shrink-0' : 'h-4 w-4'} />}{online ? 'Online' : 'Offline mode'}</p>
        </div>
        {liveHeadcount != null && (
          <div className="rounded-xl border border-brand-200 bg-brand-50/70 p-2 sm:p-3">
            <p className="flex items-center gap-1 text-xs leading-tight font-medium text-brand-950 sm:text-sm">
              <Users aria-hidden="true" className="h-3.5 w-3.5 shrink-0" /> {isCooldownMode ? 'Entered' : 'Inside now'}
            </p>
            <p className="text-lg font-bold tabular-nums text-brand-950 sm:text-xl" data-testid="scanner-live-headcount">{HEADCOUNT_FORMAT.format(liveHeadcount)}</p>
            {(!online || pendingCount > 0 || untrackedPreReEntry > 0) && (
              <p className="text-[11px] leading-tight text-brand-900">
                {untrackedPreReEntry > 0 ? `+${HEADCOUNT_FORMAT.format(untrackedPreReEntry)} earlier check-ins` : 'At last sync'}
              </p>
            )}
          </div>
        )}
        <div className="rounded-xl border border-neutral-200 bg-white p-2 sm:p-3"><p className="text-xs leading-tight text-neutral-700 sm:text-sm">Waiting to sync</p><p className={`text-lg font-bold sm:text-xl${liveHeadcount != null ? ' tabular-nums' : ''}`} data-testid="scanner-pending-count">{liveHeadcount != null ? HEADCOUNT_FORMAT.format(pendingCount) : pendingCount}</p></div>
        <div className="rounded-xl border border-neutral-200 bg-white p-2 sm:p-3"><p className="text-xs leading-tight text-neutral-700 sm:text-sm">Scans this session</p><p className={`text-lg font-bold sm:text-xl${liveHeadcount != null ? ' tabular-nums' : ''}`}>{liveHeadcount != null ? HEADCOUNT_FORMAT.format(sessionCount) : sessionCount}</p></div>
        <button onClick={() => syncQueue()} disabled={!ready || !online || syncing} className={`btn-secondary flex flex-col items-center justify-center gap-1 !px-2 !py-2 text-xs disabled:opacity-50 sm:flex-row sm:gap-2 sm:!px-6 sm:!py-3 sm:text-base ${liveHeadcount != null ? 'col-span-2 sm:col-span-1' : ''}`}>
          {syncing ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />} Sync now
        </button>
      </div>

      <div className={`${isExitScanMode ? 'order-5 sm:order-none ' : ''}flex flex-col gap-3 empty:hidden sm:col-span-2 sm:row-start-5 sm:block`}>
        {headcountByDay.length > 1 && (
          <div className="flex flex-wrap items-center gap-2 rounded-xl border border-neutral-200 bg-white px-3 py-2 text-xs sm:mb-4" aria-label="Live headcount by day">
            <span className="font-semibold text-neutral-700">By day:</span>
            {headcountByDay.map(day => {
              const isPastDay = Boolean(day.day && currentServiceDay && day.day < currentServiceDay)
              const countText = isPastDay || isCooldownMode
                ? `${HEADCOUNT_FORMAT.format(day.entries ?? day.headcount ?? 0)} entered`
                : `${HEADCOUNT_FORMAT.format(day.headcount ?? 0)} inside`
              return (
                <span key={`${day.event_id || 'e'}-${day.day}`} className="rounded-full bg-neutral-100 px-2.5 py-1 font-semibold tabular-nums text-neutral-900">
                  {day.event_title || day.label || day.day}: {countText}
                </span>
              )
            })}
          </div>
        )}
        {pendingCount > 0 && <p className="rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950 sm:mb-4">Sync saved scans before switching accounts or signing out. Unconfirmed scans need the original staff account to recover online.</p>}
        {!online && <p className="rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950 sm:mb-4">{ready ? (isExitScanMode ? 'Offline scans stay on this device. Offline exit scans keep tickets marked inside at other gates until this phone reconnects and syncs.' : 'Offline scans stay on this device. Other gates may have newer admissions. Sync when connected.') : 'Connect to prepare this device before scanning. Offline check-in needs saved event access and a verified ticket list.'}</p>}
        {ready && <section aria-label="Ticket list readiness" className="rounded-xl border border-neutral-200 bg-white p-3 sm:mb-5 sm:p-4">
          <p className="font-semibold text-neutral-950">Ticket list ready · {manifest.payload.tickets.length} {manifest.payload.tickets.length === 1 ? 'ticket' : 'tickets'}</p>
          <p className="mt-1 text-sm text-neutral-700">{expiryLabel ? `Access expires ${expiryLabel} · ${eventTimezone}` : 'Reconnect to verify the access expiry.'}</p>
        </section>}
        {membershipRequired && <section role="status" className="rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-sm text-neutral-700 sm:mb-5">
          <h2 className="font-semibold text-neutral-900">Join the event’s door team</h2>
          <p className="mt-1">Scanning is for an organizer’s team and door staff.</p>
          <p className="mt-1">Ask the event’s organizer to add you as door staff. If they send an invitation, accept it using this account.</p>
          <Link to="/dashboard" className="mt-2 inline-flex min-h-11 items-center font-semibold text-brand-700 underline">Open organizer workspace</Link>
        </section>}
        {noAssignedEvents && <section role="status" className="rounded-xl border border-neutral-200 bg-white p-4 text-sm text-neutral-700 sm:mb-5">
          <h2 className="font-semibold text-neutral-900">No events are assigned to this account.</h2>
          <p className="mt-1">Ask the event’s organizer to assign you to the event as door staff. If you searched for an event, try clearing the search below.</p>
        </section>}
        {error && !membershipRequired && <div role="alert" className="rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-800 sm:mb-5"><p>{error}</p>{!ready && eventId && online && <button type="button" disabled={setupBusy} onClick={() => configureEvent(eventId)} className="mt-2 min-h-11 font-semibold underline">Verify scanner access</button>}</div>}
        {setupBusy && <div role="status" className="flex items-center gap-2 rounded-xl border bg-white p-4 text-sm sm:mb-5"><Loader2 aria-hidden="true" className="h-4 w-4 animate-spin" /> Preparing this device and verifying its ticket list…</div>}
      </div>

      <div className={`${isExitScanMode ? 'order-3 sm:order-none ' : ''}flex flex-col gap-3 sm:col-span-2 sm:row-start-7 sm:mb-5 sm:block sm:space-y-5 sm:self-start lg:col-span-1 lg:col-start-1 lg:row-span-3`}>
        {isExitScanMode && (
          <div
            data-testid="re-entry-mode-toggle"
            role="group"
            aria-label="Scan direction"
            className="grid grid-cols-2 gap-2 rounded-2xl border-2 border-neutral-300 bg-neutral-100 p-1.5"
          >
            <button
              type="button"
              aria-pressed={effectiveDirection === 'admit'}
              onClick={() => { primeSound(); setScanDirection('admit') }}
              className={`flex min-h-14 items-center justify-center gap-2 rounded-xl px-4 py-3 text-base font-extrabold tracking-wide transition-colors ${
                effectiveDirection === 'admit'
                  ? 'bg-emerald-800 text-white shadow-sm ring-2 ring-emerald-950'
                  : 'bg-white text-neutral-800 hover:bg-neutral-50'
              }`}
            >
              <LogIn aria-hidden="true" className="h-5 w-5 shrink-0" />
              <span>ENTRY</span>
            </button>
            <button
              type="button"
              aria-pressed={effectiveDirection === 'exit'}
              onClick={() => { primeSound(); setScanDirection('exit') }}
              className={`flex min-h-14 items-center justify-center gap-2 rounded-xl px-4 py-3 text-base font-extrabold tracking-wide transition-colors ${
                effectiveDirection === 'exit'
                  ? 'bg-sky-800 text-white shadow-sm ring-2 ring-sky-950'
                  : 'bg-white text-neutral-800 hover:bg-neutral-50'
              }`}
            >
              <LogOut aria-hidden="true" className="h-5 w-5 shrink-0" />
              <span>EXIT</span>
            </button>
          </div>
        )}
        <section id="scanner-camera" className={`scroll-mt-24 overflow-hidden rounded-2xl bg-neutral-950 ${effectiveDirection === 'exit' ? 'ring-4 ring-sky-600' : ''}`}>
          <div className="flex">
            {/* The tap that starts the camera also unlocks audio on iOS. */}
            <button onClick={scanning ? stopCamera : () => { primeSound(); startCamera() }} disabled={!ready}
              className={`flex min-h-11 flex-1 items-center justify-center gap-2 px-4 py-4 font-semibold text-white disabled:cursor-not-allowed disabled:bg-neutral-700 ${
                effectiveDirection === 'exit' ? 'bg-sky-800 enabled:hover:bg-sky-900' : 'bg-brand-800 enabled:hover:bg-brand-900'
              }`}>
              {scanning ? <><StopCircle className="h-5 w-5" /> Stop camera</> : <><Camera className="h-5 w-5" /> Start camera</>}
            </button>
            <button type="button" onClick={toggleSound} aria-pressed={soundOn}
              className={`flex min-h-11 shrink-0 items-center justify-center gap-2 border-l border-white/20 px-4 font-semibold text-white ${
                effectiveDirection === 'exit' ? 'bg-sky-800 hover:bg-sky-900' : 'bg-brand-800 hover:bg-brand-900'
              }`}>
              {soundOn ? <Volume2 aria-hidden="true" className="h-5 w-5" /> : <VolumeX aria-hidden="true" className="h-5 w-5" />} Sound
            </button>
          </div>
          <div className="relative aspect-[4/3] max-h-[60dvh] landscape:max-h-[45dvh]">
            {effectiveDirection === 'exit' && (
              <div className="pointer-events-none absolute top-3 left-3 z-10 inline-flex items-center gap-1.5 rounded-full bg-sky-800 px-3 py-1 text-xs font-extrabold tracking-wide text-white shadow">
                <LogOut aria-hidden="true" className="h-3.5 w-3.5" /> EXIT MODE
              </div>
            )}
            <video ref={videoRef} className={`h-full max-h-[60dvh] w-full object-cover landscape:max-h-[45dvh] ${scanning ? '' : 'hidden'}`} playsInline muted />
            {!scanning && (
              <div className="absolute inset-0 flex flex-col items-center justify-center px-4 text-center text-neutral-200">
                <Camera aria-hidden="true" className="mb-3 h-12 w-12" /><p className="text-sm">{ready ? (effectiveDirection === 'exit' ? 'Point the camera at the ticket QR code to scan EXIT' : 'Point the camera at the ticket QR code') : setupBusy ? 'Preparing this scanner…' : 'Choose an assigned event and prepare this device to enable the camera.'}</p>
              </div>
            )}
            {scanning && <div className="pointer-events-none absolute inset-0 m-auto h-52 max-h-[85%] w-52 max-w-[85%] rounded-3xl border-4 border-white/80 shadow-[0_0_0_9999px_rgba(0,0,0,.28)]" />}
          </div>

        </section>
        <ResultPanel result={scanResult} panelRef={resultPanelRef} canOverride={canOverride} online={online} overrideBusy={overrideBusy} onOverride={submitLeadOverride} />
        {scanning && (!wakeLock.supported || wakeLock.failed) && <p className="rounded-xl border border-neutral-200 bg-neutral-50 p-3 text-sm text-neutral-800">This browser can’t keep the screen on. Set Auto-Lock or Screen timeout to Never while scanning.</p>}
        {cameraError && <p role="alert" className="rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">{cameraError} You can enter the ticket QR code below or find the attendee online.</p>}
      </div>

      {dashboard && (
        <section className={`${isExitScanMode ? 'order-8 sm:order-none ' : ''}rounded-2xl border border-neutral-200 bg-white p-3 sm:col-span-2 sm:row-start-10 sm:mb-5 sm:self-start sm:p-5 lg:col-span-1 lg:col-start-2 lg:row-start-8`}>
          <div className="mb-1 flex items-center justify-between sm:mb-4"><h2 className="font-semibold">Door totals</h2><button onClick={downloadDoorList} disabled={!online || downloading} className="flex min-h-11 min-w-11 items-center justify-center rounded-lg text-brand-800 disabled:opacity-50" aria-label="Download emergency door list" title="Download emergency door list">{downloading ? <Loader2 className="h-5 w-5 animate-spin" /> : <Download className="h-5 w-5" />}</button></div>
          <p className="mb-3 text-xs text-neutral-600">Server totals at the last sync. Issued includes tickets blocked from entry. These totals do not measure saleable stock or people inside; offline scans are pending.</p>
          <div className="grid grid-cols-2 gap-2 sm:gap-3">
            {[['Server check-ins', dashboard.counts.admitted], ['Eligible, not checked in', dashboard.counts.eligible_unadmitted ?? '—'], ['Issued, not checked in', dashboard.counts.issued ?? dashboard.counts.remaining], ['Conflicts', dashboard.counts.conflicts]].map(([label, value]) => (
              <div key={label} className="rounded-xl bg-neutral-50 p-2 sm:p-3"><p className="text-xs text-neutral-500">{label}</p><p className="text-lg font-bold sm:text-2xl">{value}</p></div>
            ))}
          </div>
        </section>
      )}


      <nav aria-label="Check-in tools" className={`${isExitScanMode ? 'order-6 sm:order-none ' : ''}flex flex-wrap gap-x-5 gap-y-1 text-sm font-semibold text-brand-800 sm:col-span-2 sm:row-start-6 sm:mb-4`}>
        <a href="#scanner-camera" className="inline-flex min-h-11 items-center underline underline-offset-4">Use camera</a>
        <a href="#manual-ticket-entry" className="inline-flex min-h-11 items-center underline underline-offset-4">Enter QR code</a>
        <a href="#attendee-lookup" className="inline-flex min-h-11 items-center underline underline-offset-4">Find attendee</a>
      </nav>

      <div className={`${isExitScanMode ? 'order-7 sm:order-none ' : ''}flex flex-col gap-3 sm:col-span-2 sm:row-start-8 sm:mb-6 sm:block sm:space-y-5 sm:self-start lg:col-span-1 lg:col-start-1 lg:row-start-10 lg:mb-0`}>
        <section id="manual-ticket-entry" className="scroll-mt-24 rounded-2xl border border-neutral-200 bg-white p-5">
          <h2 className="font-semibold text-neutral-950">Enter a ticket QR code</h2>
          <p id="manual-ticket-help" className="mb-3 text-sm text-neutral-700">Paste the QR code or link from the ticket. Some tickets ask you to check details before admitting. For a ticket number such as HP-T123, use attendee lookup below.</p>
          <label htmlFor="manual-ticket-code" className="mb-1 block text-sm font-medium text-neutral-800">Ticket QR code</label>
          <form onSubmit={event => { event.preventDefault(); primeSound(); if (credentialInFlightRef.current) return; processCredential(manualCode); setManualCode('') }} className="flex flex-col gap-2 sm:flex-row">
            <input value={manualCode} onChange={event => setManualCode(event.target.value)} id="manual-ticket-code" className="input min-w-0 flex-1" aria-describedby="manual-ticket-help" placeholder="Paste ticket QR code or link" disabled={!ready} />
            <button className="btn-primary" disabled={!ready || !manualCode.trim() || credentialBusy || !!verification}>
              {credentialBusy ? 'Checking ticket…' : effectiveDirection === 'exit' ? 'Scan exit' : 'Check in ticket'}
            </button>
          </form>
        </section>

        <section id="attendee-lookup" className="scroll-mt-24 rounded-2xl border border-neutral-200 bg-white p-5">
          <h2 className="font-semibold text-neutral-950">Find an attendee</h2>
          <p id="attendee-lookup-help" className="mb-3 text-sm text-neutral-700">Search online by name or HåfaPass ticket number. Email addresses stay private.{!online && ' Reconnect to use this search.'}</p>
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
                <button className="btn-primary text-sm" disabled={!ticket.admission_allowed || !ticketsById.has(Number(ticket.id)) || credentialBusy || !!verification}
                  onClick={() => { primeSound(); processCredential(null, ticketsById.get(Number(ticket.id))) }}>Admit</button>
              </div>
            ))}
          </div>
        </section>
      </div>

      <div className={`${isExitScanMode ? 'order-9 sm:order-none ' : ''}sm:col-start-1 sm:row-span-2 sm:row-start-2 sm:max-w-2xl sm:self-start`}>
        <p className="text-sm text-neutral-700 sm:mt-2">Scan a ticket, check the result, then welcome the guest.</p>
        <p className="mt-2 text-sm text-neutral-600">Prepare this device online before the event.</p>
      </div>
      {!offlineOnly && <div className={`${isExitScanMode ? 'order-9 sm:order-none ' : ''}sm:col-start-2 sm:row-start-1`}>
        <OperationalSearch label="Find an event" buttonLabel="Search events" hint="Search by event name, venue or event ID." query={listing.q} onSearch={listing.search} busy={eventListLoading} />
        {!eventListLoading && listing.q && events.length === 0 && <p role="status" className="mb-2 text-sm">No matching events. Try another search. Your selected event stays ready.</p>}
      </div>}
      {!offlineOnly && <div className={`${isExitScanMode ? 'order-9 sm:order-none ' : ''}empty:hidden sm:col-start-2 sm:row-start-3`}><OperationalPagination meta={eventMeta} page={listing.page} onPage={listing.goToPage} busy={eventListLoading} label="Event pages" /></div>}

      <section className={`${isExitScanMode ? 'order-10 sm:order-none ' : ''}rounded-xl border border-neutral-200 bg-white p-5 sm:col-span-2 sm:row-start-9 sm:mb-5 sm:self-start lg:col-span-1 lg:col-start-2 lg:row-start-7`}>
        <div className="flex items-start gap-3"><Smartphone aria-hidden="true" className="mt-1 h-5 w-5 shrink-0 text-brand-800" /><div className="min-w-0 break-words">
          <h2 className="font-semibold text-neutral-950">{device?.name || (ready ? 'Device ready' : 'Device not ready')}</h2>
          <p className="mt-2 text-sm text-neutral-700">{ready ? 'This device is ready to scan. Sync saved scans while connected.' : 'Connect and choose an assigned event to prepare this device for scanning.'}</p>
          <p className="mt-1 text-sm text-neutral-700">{selectedEvent?.title}</p>
          {!ready && pendingCount > 0 && <p className="mt-3 text-sm text-amber-950">Saved scans are safe on this device. Connect with the same staff account to sync them. Ask the door manager for help before resetting.</p>}
          {!ready && recoveryDevice && pendingCount > 0 && <button disabled={!online || syncing || setupBusy} onClick={() => syncQueue({ selectedDevice: recoveryDevice })} className="btn-secondary mt-3 text-sm">Sync saved scans</button>}
        </div></div>
        <details className="mt-3 border-t border-neutral-200 pt-1">
          <summary className="flex min-h-11 cursor-pointer items-center text-sm font-semibold text-neutral-700">Device details</summary>
          <p className="text-sm text-neutral-700">{OFFLINE_SCANNER_ACCESS_NOTE} Offline access lasts at most 24 hours and ends sooner when the event or your access ends.</p>
          <p className="mt-2 text-sm text-neutral-700">If this phone is lost or the account is compromised, ask an organizer to revoke its scanner registration, sign out its staff sessions, and remove its event and team access. Revoking a device alone does not prevent someone with scan access from registering another device.</p>
          <SavedJournalExports owner={currentScannerOwner()} pendingCount={pendingCount} eventId={eventId} />
          {dashboard?.permissions?.can_recover && <JournalRecovery key={eventId} eventId={eventId} onRecovered={counts => setDashboard(current => current ? { ...current, counts } : current)} />}
          {manifest && <p className="text-sm text-neutral-700">Saved ticket list · version {manifest.payload.version} · {manifest.payload.tickets.length} {manifest.payload.tickets.length === 1 ? 'ticket' : 'tickets'}</p>}
          <p className="mt-2 text-sm text-neutral-700">Signing out removes saved access and attendee details. Sync before signing out; unconfirmed scans need the original staff account to recover online.</p>
          <p className="mt-2 text-sm text-neutral-700">Only reset after saved scans are confirmed. Resetting replaces this device’s trusted ticket-list access.</p>
          {eventId && <button disabled={!online || syncing || setupBusy} onClick={resetScanner} className="mt-2 block min-h-11 text-sm font-semibold text-red-800 underline underline-offset-2 disabled:opacity-50">Reset trusted device</button>}
        </details>
      </section>


      {canOverride && flaggedConflicts.length > 0 && (
        <section className={`${isExitScanMode ? 'order-11 sm:order-none ' : ''}rounded-2xl border-2 border-amber-300 bg-amber-50 p-5 sm:col-span-2 lg:col-span-1 lg:col-start-2`}>
          <h2 className="mb-2 font-semibold text-amber-950">Flagged offline conflicts ({flaggedConflicts.length})</h2>
          <p className="mb-3 text-xs text-amber-900">Two gates admitted these tickets while offline. Review and clear or override with a reason.</p>
          <div className="space-y-3">
            {flaggedConflicts.map(conflict => (
              <div key={conflict.id} className="rounded-xl border border-amber-200 bg-white p-3 text-xs">
                <p className="break-words font-bold text-neutral-950 [overflow-wrap:anywhere]">{conflict.attendee_name || 'Guest'} · {conflict.code}</p>
                <p className="mt-0.5 text-neutral-700">
                  {conflict.last_entry_gate ? `First gate: ${conflict.last_entry_gate}` : 'Conflict recorded'}
                  {conflict.last_entry_at ? ` at ${formatGateTime(conflict.last_entry_at, eventTimezone)}` : ''}
                </p>
                {online && <ReEntryLeadOverride ticket={conflict} busy={overrideBusy} onSubmit={submitLeadOverride} defaultAction="clear" compact />}
              </div>
            ))}
          </div>
        </section>
      )}
      {dashboard?.permissions?.can_reverse && (
        <section className={`${isExitScanMode ? 'order-12 sm:order-none ' : ''}rounded-2xl border border-neutral-200 bg-white p-5 sm:col-span-2 sm:row-start-11 sm:self-start lg:col-span-1 lg:col-start-2 lg:row-start-9 lg:row-span-2`}>
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
      {verification && ready && <VerificationOverlay ticket={scanResult.ticket} onConfirm={confirmVerification} onCancel={cancelVerification} busy={credentialBusy} />}
      {overlay && overlay.type !== 'verify' && (
        <ScanResultOverlay
          key={`${overlay.id}:${overlay.type}`}
          id={overlay.id}
          type={overlay.type}
          ticket={scanResult.ticket}
          headline={overlay.headline}
          subtext={overlay.subtext}
          badge={overlay.badge}
          onDismiss={setDismissedFeedback}
          onGesture={primeSound}
        />
      )}
    </div>
  )
}
