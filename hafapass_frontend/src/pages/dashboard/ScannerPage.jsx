import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  AlertTriangle, Camera, CheckCircle2, CloudOff, Download, Loader2, RefreshCw,
  RotateCcw, Search, ShieldCheck, Smartphone, StopCircle, XCircle,
} from 'lucide-react'
import { Link, useLocation, useSearchParams } from 'react-router-dom'
import apiClient, { getApiAuthContext, subscribeApiAuthContext } from '../../api/client'
import { formatEventDateTime } from '../../utils/eventTime'
import {
  applySyncResults, captureAdmissionAccessContext, currentScannerOwner, clearEventAdmissionData, loadAuthorizedScanner, loadPendingDeviceIdentity, localScanState, queueAdmission,
  queuedActions, queueReversal, loadDevice, invalidateManifestAccess, saveDevice, saveVerifiedManifest, sha256Hex, purgeExpiredAdmissionAccess,
} from '../../utils/admissionStore'

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

function admissionAcknowledgement(current, receipt) {
  const result = receipt.result || receipt.status
  if (result === 'accepted') return { ...current, type: 'success', message: 'Admission confirmed', detail: 'The server confirmed this entry.' }
  if (receipt.reason_code === 'refund_pending') return { ...current, type: 'error', message: 'Refund pending — do not admit', detail: 'Entry is paused while this ticket’s refund is unresolved. Ask a door manager to check its current status.' }
  return { ...current, type: result === 'conflict' ? 'warning' : 'error', message: receipt.reason_code === 'already_admitted' ? 'Already admitted on another device' : 'Do not admit — scan rejected', detail: 'The server refused this entry. Ask a door manager to check the ticket and saved scan.' }
}

function ResultPanel({ result }) {
  if (!result) return null
  const styles = {
    pending: ['bg-neutral-50 border-neutral-300 text-neutral-900', Loader2],
    success: ['bg-emerald-50 border-emerald-300 text-emerald-900', CheckCircle2],
    warning: ['bg-amber-50 border-amber-300 text-amber-900', AlertTriangle],
    error: ['bg-red-50 border-red-300 text-red-900', XCircle],
  }
  const [classes, Icon] = styles[result.type]
  return (
    <div className={`rounded-2xl border-2 p-5 ${classes}`} role="status" aria-live="assertive" aria-atomic="true">
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

export default function ScannerPage({ offlineOnly = false }) {
  const [searchParams] = useSearchParams()
  const location = useLocation()
  const requestedEventId = searchParams.get('event')
  const [events, setEvents] = useState([])
  const [eventId, setEventId] = useState('')
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
  const [searchQuery, setSearchQuery] = useState('')
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
  const privateReadGenerationRef = useRef(0)
  const refusedAccessRef = useRef(new Set())

  useEffect(() => {
    const abortReads = () => {
      ++privateReadGenerationRef.current
      searchRequestRef.current?.abort()
      downloadRequestRef.current?.abort()
      dashboardRequestRef.current?.abort()
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
    const current = () => mountedRef.current && !controller.signal.aborted && requestRef.current === controller
      && owner === currentScannerOwner() && selectedEventId === eventIdRef.current
      && generation === setupGenerationRef.current && visit === visitRef.current
      && readGeneration === privateReadGenerationRef.current && authContext === getApiAuthContext()
      && organizationId === window.localStorage.getItem('hafapass_organization_id')
    return { selectedEventId, current, config: { signal: controller.signal, authContext, organizationId } }
  }, [])

  const handlePrivateReadError = useCallback(async (readError, request, context, fallback) => {
    if (!request.current() || readError.manifestContextChanged) return
    if ([401, 403].includes(readError.response?.status) && context) {
      let removed
      let message = readError.response?.data?.error || 'Scanner access was refused. Reload while connected to verify access. Saved scans remain on this device.'
      try { removed = await purgeExpiredAdmissionAccess(request.selectedEventId, { context }) }
      catch { removed = true; message = 'Scanner access could not be removed. Reload this device before admitting more guests. Saved scans remain on this device.' }
      // A peer renewal or a later visit owns its own access. An old refusal must
      // never erase that newer grant or its attendee records.
      if (!removed || !request.current()) return
      refusedAccessRef.current.add(JSON.stringify([currentScannerOwner(), String(request.selectedEventId)]))
      ++setupGenerationRef.current
      ++presentationRef.current
      currentManifestRef.current = null
      stopCamera()
      searchRequestRef.current?.abort()
      downloadRequestRef.current?.abort()
      dashboardRequestRef.current?.abort()
      setDevice(null); setManifest(null); setRecoveryDevice(null); setDashboard(null)
      setSearchResults([]); setSearchQuery(''); setManualCode(''); setScanResult(null)
      setSearching(false); setDownloading(false); setSetupBusy(false)
      setError(message)
      return
    }
    setError(readError.response?.data?.error || fallback)
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
    const current = () => generation === setupGenerationRef.current && eventIdRef.current === String(selectedEventId) && owner === currentScannerOwner()
    const refusedKey = JSON.stringify([owner, String(selectedEventId)])
    const accessRefused = refusedAccessRef.current.has(refusedKey)
    setSetupBusy(true)
    setError(null)
    setScanResult(null)
    setDevice(null)
    setRecoveryDevice(null)
    setManifest(null)
    setDashboard(null)
    setSearchResults([])
    try {
      if (!online && accessRefused) throw new Error('Scanner access was refused. Reconnect to verify access before admitting more guests.')
      const pendingIdentity = await loadPendingDeviceIdentity(selectedEventId)
      await refreshPending(selectedEventId, pendingIdentity ? { id: pendingIdentity.device_id } : null)
      let cached = await loadAuthorizedScanner(selectedEventId)
      if (online) {
        let networkPhase = true
        let failureContext = await captureAdmissionAccessContext(selectedEventId, { isCurrent: current })
        try {
          let previousIdentity = await loadPendingDeviceIdentity(selectedEventId)
          if (!previousIdentity) {
            const me = await apiClient.get('/me')
            previousIdentity = await loadPendingDeviceIdentity(selectedEventId, me.data.id)
          }
          const registration = await apiClient.post(`/organizer/events/${selectedEventId}/scanner_devices`, {
            identifier: previousIdentity?.identifier || browserIdentifier(),
            name: `Scanner · ${navigator.platform || 'browser'}`,
          })
          networkPhase = false
          if (!current()) return
          await saveDevice(selectedEventId, registration.data, { isCurrent: current, context: failureContext })
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
          if (!cached || !networkPhase || accessRefused) throw connectionError
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
      if (accessRefused) refusedAccessRef.current.delete(refusedKey)
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
      const saved = window.localStorage.getItem('hafapass_scanner_event_id')
      const cached = saved ? await loadAuthorizedScanner(saved).catch(() => null) : null
      if (!active) return
      if (cached) {
        setEvents([{ ...cached.manifest.payload.event, id: Number(saved) }])
        setEventId(saved)
      } else {
        setError('Could not load assigned events. Connect once to authorize this scanner and download an event list.')
        setSetupBusy(false)
      }
    }
    if (offlineOnly) { void restoreSaved(); return () => { active = false } }
    apiClient.get('/organizer/events').then(response => {
      if (!active) return
      const accessible = response.data.events || []
      setEvents(accessible)
      const saved = window.localStorage.getItem('hafapass_scanner_event_id')
      const initial = accessible.find(event => String(event.id) === requestedEventId)?.id || accessible.find(event => String(event.id) === saved)?.id || accessible[0]?.id
      if (initial) setEventId(String(initial))
      else setSetupBusy(false)
    }).catch(() => { if (active) void restoreSaved() })
    return () => { active = false }
  }, [offlineOnly, requestedEventId])

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
    const generation = setupGenerationRef.current
    const current = () => mountedRef.current && owner === currentScannerOwner()
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
    const localState = await localScanState(eventId, ticket.ticket_id)
    if (!current()) return
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
    const generation = setupGenerationRef.current
    const current = () => mountedRef.current && owner === currentScannerOwner()
      && eventIdRef.current === eventId && generation === setupGenerationRef.current && presentation === presentationRef.current
    try {
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

  const runSearch = async event => {
    event.preventDefault()
    if (!eventId || !online || searchQuery.trim().length < 2) return
    const request = beginPrivateRead(searchRequestRef, eventId)
    setSearching(true)
    setError(null)
    let context
    try {
      context = await captureAdmissionAccessContext(request.selectedEventId, { isCurrent: request.current })
      if (!request.current()) return
      const response = await apiClient.get(`/organizer/events/${request.selectedEventId}/admissions/search`, { ...request.config, params: { q: searchQuery.trim() } })
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

  const selectedEvent = events.find(event => String(event.id) === eventId)
  const ready = Boolean(device && manifest)
  const expiresAt = Math.min(Date.parse(device?.authorization_expires_at || ''), Date.parse(manifest?.payload.expires_at || ''))
  const eventTimezone = manifest?.payload.event?.timezone || selectedEvent?.timezone || 'Pacific/Guam'
  const expiryLabel = Number.isFinite(expiresAt) ? formatEventDateTime(expiresAt, eventTimezone) : null

  return (
    <div className="mx-auto max-w-6xl px-4 py-6 sm:py-8">
      <div className="mb-5 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div className="min-w-0 max-w-2xl">
          <Link to="/dashboard" className="inline-flex min-h-11 items-center text-sm font-medium text-brand-800">All events</Link>
          <h1 className="font-display text-3xl font-bold text-neutral-950">Check-in</h1>
          {selectedEvent && <p className="mt-2 break-words text-base font-semibold text-neutral-900">{selectedEvent.title}</p>}
          <p className="mt-2 text-sm text-neutral-700">Scan a ticket, check the result, then welcome the guest.</p>
          <p className="mt-2 text-sm text-neutral-600">Prepare this device online before the event.</p>
        </div>
        <div className="w-full sm:max-w-sm">
          <label htmlFor="scanner-event" className="mb-1 block text-sm font-medium text-neutral-800">Event to scan</label>
          <select id="scanner-event" value={eventId} onChange={event => setEventId(event.target.value)} className="input w-full">
            {!events.length && <option value="">No assigned events</option>}
            {events.map(event => <option key={event.id} value={event.id}>{event.title}</option>)}
          </select>
        </div>
      </div>

      <div className="mb-4 grid grid-cols-2 gap-2 sm:grid-cols-4" aria-label="Check-in status">
        <div className={`rounded-xl border p-3 ${online ? 'border-emerald-200 bg-emerald-50' : 'border-amber-200 bg-amber-50'}`}>
          <p className="flex items-center gap-2 text-sm font-semibold">{online ? <ShieldCheck className="h-4 w-4" /> : <CloudOff className="h-4 w-4" />}{online ? 'Online' : 'Offline mode'}</p>
        </div>
        <div className="rounded-xl border border-neutral-200 bg-white p-3"><p className="text-sm text-neutral-700">Waiting to sync</p><p className="text-xl font-bold" data-testid="scanner-pending-count">{pendingCount}</p></div>
        <div className="rounded-xl border border-neutral-200 bg-white p-3"><p className="text-sm text-neutral-700">Scans this session</p><p className="text-xl font-bold">{sessionCount}</p></div>
        <button onClick={() => syncQueue()} disabled={!ready || !online || syncing} className="btn-secondary flex items-center justify-center gap-2 disabled:opacity-50">
          {syncing ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />} Sync now
        </button>
      </div>

      {pendingCount > 0 && <p className="mb-4 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950">Sync saved scans before switching accounts or signing out. Unconfirmed scans need the original staff account to recover online.</p>}
      {!online && <p className="mb-4 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950">Offline scans stay on this device. Other gates may have newer admissions. Sync when connected.</p>}
      {ready && <section aria-label="Ticket list readiness" className="mb-5 rounded-xl border border-neutral-200 bg-white p-4">
        <p className="font-semibold text-neutral-950">Ticket list ready · {manifest.payload.tickets.length} {manifest.payload.tickets.length === 1 ? 'ticket' : 'tickets'}</p>
        <p className="mt-1 text-sm text-neutral-700">{expiryLabel ? `Access expires ${expiryLabel} · ${eventTimezone}` : 'Reconnect to verify the access expiry.'}</p>
      </section>}
      {error && <div role="alert" className="mb-5 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-800">{error}</div>}
      {setupBusy && <div role="status" className="mb-5 flex items-center gap-2 rounded-xl border bg-white p-4 text-sm"><Loader2 aria-hidden="true" className="h-4 w-4 animate-spin" /> Preparing this device and verifying its ticket list…</div>}

      <nav aria-label="Check-in tools" className="mb-4 flex flex-wrap gap-x-5 gap-y-1 text-sm font-semibold text-brand-800">
        <a href="#scanner-camera" className="inline-flex min-h-11 items-center underline underline-offset-4">Use camera</a>
        <a href="#manual-ticket-entry" className="inline-flex min-h-11 items-center underline underline-offset-4">Enter QR code</a>
        <a href="#attendee-lookup" className="inline-flex min-h-11 items-center underline underline-offset-4">Find attendee</a>
      </nav>
      <div className="grid gap-6 lg:grid-cols-[1.35fr_.65fr]">
        <div className="space-y-5">
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

        <aside className="space-y-5">
          <section className="rounded-xl border border-neutral-200 bg-white p-5">
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

          {dashboard && (
            <section className="rounded-2xl border border-neutral-200 bg-white p-5">
              <div className="mb-4 flex items-center justify-between"><h2 className="font-semibold">Door totals</h2><button onClick={downloadDoorList} disabled={!online || downloading} className="flex min-h-11 min-w-11 items-center justify-center rounded-lg text-brand-800 disabled:opacity-50" aria-label="Download emergency door list" title="Download emergency door list">{downloading ? <Loader2 className="h-5 w-5 animate-spin" /> : <Download className="h-5 w-5" />}</button></div>
              <div className="grid grid-cols-2 gap-3">
                {[['Admitted', dashboard.counts.admitted], ['Remaining', dashboard.counts.remaining], ['Conflicts', dashboard.counts.conflicts], ['Rejected', dashboard.counts.rejected]].map(([label, value]) => (
                  <div key={label} className="rounded-xl bg-neutral-50 p-3"><p className="text-xs text-neutral-500">{label}</p><p className="text-2xl font-bold">{value}</p></div>
                ))}
              </div>
            </section>
          )}

          {dashboard?.permissions?.can_reverse && (
            <section className="rounded-2xl border border-neutral-200 bg-white p-5">
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
        </aside>
      </div>
    </div>
  )
}
