import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  AlertTriangle, Camera, CheckCircle2, CloudOff, Download, Loader2, RefreshCw,
  RotateCcw, Search, ShieldCheck, Smartphone, StopCircle, XCircle,
} from 'lucide-react'
import apiClient from '../../api/client'
import {
  applySyncResults, currentScannerOwner, clearEventAdmissionData, loadAuthorizedScanner, loadPendingDeviceIdentity, localScanState, queueAdmission,
  queuedActions, queueReversal, loadDevice, invalidateManifestAccess, saveDevice, saveVerifiedManifest, sha256Hex, purgeExpiredAdmissionAccess,
} from '../../utils/admissionStore'

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

function ResultPanel({ result }) {
  if (!result) return null
  const styles = {
    success: ['bg-emerald-50 border-emerald-300 text-emerald-900', CheckCircle2],
    warning: ['bg-amber-50 border-amber-300 text-amber-900', AlertTriangle],
    error: ['bg-red-50 border-red-300 text-red-900', XCircle],
  }
  const [classes, Icon] = styles[result.type]
  return (
    <div className={`rounded-2xl border-2 p-5 ${classes}`} role="status" aria-live="assertive">
      <div className="flex gap-3">
        <Icon className="h-8 w-8 shrink-0" />
        <div>
          <p className="text-lg font-bold">{result.message}</p>
          {result.detail && <p className="mt-1 text-sm">{result.detail}</p>}
          {result.ticket && (
            <p className="mt-2 text-sm font-medium">
              {result.ticket.attendee_name} · {result.ticket.ticket_type} · {result.ticket.code}
            </p>
          )}
          {result.latency != null && <p className="mt-1 text-xs opacity-70">Local response: {Math.round(result.latency)}ms</p>}
        </div>
      </div>
    </div>
  )
}

export default function ScannerPage({ offlineOnly = false }) {
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
  const eventIdRef = useRef(eventId)
  eventIdRef.current = eventId
  const processCredentialRef = useRef(null)
  const cameraGenerationRef = useRef(0)
  const currentManifestRef = useRef(manifest)
  currentManifestRef.current = manifest

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

  const fetchDashboard = useCallback(async selectedEventId => {
    if (!selectedEventId || !online) return
    const response = await apiClient.get(`/organizer/events/${selectedEventId}/admissions`)
    if (eventIdRef.current === String(selectedEventId)) setDashboard(response.data)
  }, [online])

  const downloadManifest = useCallback(async (selectedEventId, selectedDevice) => {
    const response = await apiClient.get(`/organizer/events/${selectedEventId}/scanner_devices/${selectedDevice.id}/manifest`)
    if (selectedDevice.owner_user_id !== currentScannerOwner()) return null
    try {
      if (Number(response.data?.payload?.event?.id) !== Number(selectedEventId)) throw new Error('The downloaded ticket list belongs to a different event.')
      await saveVerifiedManifest(response.data)
    } catch (verificationError) {
      await invalidateManifestAccess(selectedEventId)
      verificationError.manifestInvalid = true
      throw verificationError
    }
    if (eventIdRef.current === String(selectedEventId)) setManifest(response.data)
    return response.data
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
    try {
      if (!await ownsJournal()) return
      let remaining = await queuedActions(selectedEventId, selectedDevice.id)
      if (!remaining.length) {
        if (!quiet) await Promise.all([downloadManifest(selectedEventId, selectedDevice), fetchDashboard(selectedEventId)])
        return
      }
      let currentDevice = selectedDevice
      while (remaining.length) {
        if (!await ownsJournal()) return
        const batch = remaining.slice(0, 500)
        const response = await apiClient.post(
          `/organizer/events/${selectedEventId}/scanner_devices/${currentDevice.id}/sync`,
          { actions: batch.map(({ event_id: _eventId, device_id: _deviceId, owner_user_id: _ownerId, ...action }) => action) },
        )
        if (!await ownsJournal()) return
        const results = response.data?.results
        if (response.data?.device?.id !== currentDevice.id || !Array.isArray(results) || batch.some(action => !results.some(result => result.action_uuid === action.action_uuid && result.kind === action.kind && ['accepted', 'conflict', 'rejected'].includes(result.result)))) {
          throw new Error('The server did not confirm every saved scan. They remain on this device; please retry synchronization.')
        }
        await applySyncResults(selectedEventId, response.data.device, response.data.results, owner)
        if (!current()) return
        const pendingAfterSync = await queuedActions(selectedEventId, currentDevice.id)
        if (batch.some(action => pendingAfterSync.some(pending => pending.action_uuid === action.action_uuid))) {
          throw new Error('Saved scans could not be acknowledged on this device. They remain saved; reconnect and retry synchronization.')
        }
        if (eventIdRef.current === String(selectedEventId)) setScanResult(current => {
          if (!current?.ticket) return current
          const result = results.find(item => item.kind === 'admit' && Number(item.ticket_id) === Number(current.ticket.ticket_id))
          if (!result) return current
          if (result.result === 'accepted') return { ...current, type: 'success', message: 'Admission confirmed', detail: 'The server confirmed this entry.' }
          return { ...current, type: result.result === 'conflict' ? 'warning' : 'error', message: result.reason_code === 'already_admitted' ? 'Already admitted on another device' : 'Do not admit — scan rejected', detail: 'The server refused this entry. Ask a door manager to check the ticket and saved scan.' }
        })
        currentDevice = { ...currentDevice, ...response.data.device }
        if (eventIdRef.current === String(selectedEventId)) setDashboard(current => current ? { ...current, counts: response.data.summary } : current)
        remaining = pendingAfterSync
      }
      if (!await ownsJournal()) return
      await refreshPending(selectedEventId, currentDevice)
      const retainedAccess = await loadDevice(selectedEventId)
      if (!current()) return
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
      if ([401, 403, 404, 410, 422].includes(syncError.response?.status)) {
        await purgeExpiredAdmissionAccess(selectedEventId)
        if (eventIdRef.current === String(selectedEventId)) { setDevice(null); setManifest(null); setRecoveryDevice(null) }
        setError(syncError.response?.data?.error || 'Scanner authorization was refused. Saved scans remain available to the original staff account after access is restored.')
      } else if (syncError.manifestInvalid) {
        setDevice(null)
        setManifest(null)
        setError(syncError.message)
      } else if (!quiet) setError(syncError.response?.data?.error || syncError.message || 'Queued scans could not be synchronized. They remain saved on this device; reconnect and retry.')
    } finally {
      syncingRef.current = false
      setSyncing(false)
    }
  }, [device, downloadManifest, eventId, fetchDashboard, refreshPending, online])

  const configureEvent = useCallback(async selectedEventId => {
    if (!selectedEventId) return
    const generation = ++setupGenerationRef.current
    const owner = currentScannerOwner()
    const current = () => generation === setupGenerationRef.current && eventIdRef.current === String(selectedEventId) && owner === currentScannerOwner()
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
      let cached = await loadAuthorizedScanner(selectedEventId)
      if (online) {
        let networkPhase = true
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
          await saveDevice(selectedEventId, registration.data)
          const registeredDevice = await loadDevice(selectedEventId)
          if (current()) setRecoveryDevice(registeredDevice)
          await refreshPending(selectedEventId, registeredDevice)
          networkPhase = true
          const downloaded = await apiClient.get(`/organizer/events/${selectedEventId}/scanner_devices/${registration.data.id}/manifest`)
          networkPhase = false
          if (!current()) return
          try {
            if (Number(downloaded.data?.payload?.event?.id) !== Number(selectedEventId)) throw new Error('The downloaded ticket list belongs to a different event. Ask a manager to check this device.')
            await saveVerifiedManifest(downloaded.data)
          } catch (verificationError) {
            await invalidateManifestAccess(selectedEventId)
            throw verificationError
          }
          cached = await loadAuthorizedScanner(selectedEventId)
          if (current()) await fetchDashboard(selectedEventId).catch(() => {})
        } catch (connectionError) {
          // Explicit authorization failures invalidate local trust. Dependency outages do not.
          if (connectionError.response?.status >= 400 && connectionError.response.status < 500 && ![408, 429].includes(connectionError.response.status)) {
            await purgeExpiredAdmissionAccess(selectedEventId)
            if (current()) setRecoveryDevice(null)
            throw connectionError
          }
          if (!cached || !networkPhase) throw connectionError
          if (current()) setError('Connection unavailable. Using saved access; scans remain on this device until sync succeeds.')
        }
      }
      if (!cached) throw new Error('Connect once to authorize this scanner and download the event list. Expired saved access is removed from this device.')
      if (!current()) return
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
    const restoreSaved = async () => {
      const saved = window.localStorage.getItem('hafapass_scanner_event_id')
      const cached = saved ? await loadAuthorizedScanner(saved).catch(() => null) : null
      if (cached) {
        setEvents([{ ...cached.manifest.payload.event, id: Number(saved) }])
        setEventId(saved)
      } else {
        setError('Could not load assigned events. Connect once to authorize this scanner and download an event list.')
        setSetupBusy(false)
      }
    }
    if (offlineOnly) { void restoreSaved(); return }
    apiClient.get('/organizer/events').then(response => {
      const accessible = response.data.events || []
      setEvents(accessible)
      const saved = window.localStorage.getItem('hafapass_scanner_event_id')
      const initial = accessible.find(event => String(event.id) === saved)?.id || accessible[0]?.id
      if (initial) setEventId(String(initial))
      else setSetupBusy(false)
    }).catch(restoreSaved)
  }, [offlineOnly])

  useEffect(() => {
    if (!eventId) return
    window.localStorage.setItem('hafapass_scanner_event_id', eventId)
    configureEvent(eventId)
  }, [configureEvent, eventId])

  useEffect(() => {
    if (online && eventId && device && device.owner_user_id === currentScannerOwner()) syncQueue({ quiet: true })
  }, [device, eventId, online, syncQueue])

  const showResult = useCallback(result => {
    setScanResult(result)
    if (result.type === 'success') setSessionCount(count => count + 1)
    if (navigator.vibrate) navigator.vibrate(result.type === 'success' ? 80 : [100, 60, 100])
  }, [])

  const admitEntry = useCallback(async (ticket, hash, startedAt = performance.now(), clientStatus = 'locally_accepted') => {
    if (!device || !manifest || eventIdRef.current !== eventId || currentManifestRef.current?.digest !== manifest.digest) return
    if (!device.effective || new Date(device.authorization_expires_at).getTime() <= Date.now() || new Date(manifest.payload.expires_at).getTime() <= Date.now()) {
      showResult({ type: 'error', message: 'Scanner access expired', detail: 'Reconnect before admitting another ticket.' })
      await purgeExpiredAdmissionAccess(eventId)
      setDevice(null)
      setManifest(null)
      return
    }
    const localState = await localScanState(eventId, ticket.ticket_id)
    if (['pending', 'accepted', 'conflict', 'pending_reverse'].includes(localState?.status)) {
      showResult({ type: 'warning', message: 'Already scanned on this device', detail: 'This ticket is already admitted or waiting to sync.', ticket,
        latency: performance.now() - startedAt })
      return
    }
    if (ticket.state !== 'valid') {
      const labels = { admitted: 'Already admitted', cancelled: 'Cancelled ticket', transferred: 'Transferred ticket', payment_blocked: 'Payment blocked' }
      showResult({ type: ticket.state === 'admitted' ? 'warning' : 'error', message: labels[ticket.state] || 'Ticket is not valid',
        detail: 'Use the latest manifest or ask a door manager for help.', ticket, latency: performance.now() - startedAt })
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
    if (!action) {
      showResult({ type: 'warning', message: 'Already scanned on this device', detail: 'This ticket is already admitted or waiting to sync.', ticket })
      return
    }
    await refreshPending(eventId, device)
    showResult({ type: 'success', message: online ? 'Admitted — syncing' : 'Admitted offline',
      detail: online ? 'Saved on this device. Server confirmation follows a successful sync.' : 'Saved on this device. Other offline scanners cannot see this admission until they sync.',
      ticket, latency: performance.now() - startedAt })
    if (online) syncQueue({ quiet: true })
  }, [device, eventId, manifest, refreshPending, showResult, syncQueue, online])

  const processCredential = useCallback(async raw => {
    const startedAt = performance.now()
    try {
      if (!device?.effective || new Date(device.authorization_expires_at).getTime() <= Date.now()) {
        throw new Error('This scanner authorization expired. Reconnect before scanning.')
      }
      if (!manifest || new Date(manifest.payload.expires_at).getTime() <= Date.now()) {
        throw new Error('The offline manifest is missing or expired. Reconnect before scanning.')
      }
      const hash = await sha256Hex(credentialValue(raw))
      if (eventIdRef.current !== eventId || currentManifestRef.current?.digest !== manifest.digest) return
      const ticket = ticketsByHash.get(hash)
      if (!ticket) {
        showResult({ type: 'error', message: 'Invalid ticket', detail: 'This credential is not in the signed event manifest.',
          latency: performance.now() - startedAt })
        return
      }
      await admitEntry(ticket, hash, startedAt)
    } catch (scanError) {
      showResult({ type: 'error', message: 'Scanner unavailable', detail: scanError.message, latency: performance.now() - startedAt })
    }
  }, [admitEntry, device, eventId, manifest, showResult, ticketsByHash])

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
    const expiresAt = Math.min(new Date(device.authorization_expires_at).getTime(), new Date(manifest.payload.expires_at).getTime())
    const timer = window.setTimeout(() => {
      stopCamera()
      setDevice(null)
      setManifest(null)
      setError('Saved scanner access has expired. Reconnect with the original staff account to renew access and sync saved scans.')
      void purgeExpiredAdmissionAccess(eventId)
    }, Math.max(0, expiresAt - Date.now()))
    return () => window.clearTimeout(timer)
  }, [device, eventId, manifest, stopCamera])

  const runSearch = async event => {
    event.preventDefault()
    if (!online || searchQuery.trim().length < 2) return
    setSearching(true)
    const selectedEventId = eventId
    const generation = setupGenerationRef.current
    try {
      const response = await apiClient.get(`/organizer/events/${eventId}/admissions/search`, { params: { q: searchQuery.trim() } })
      if (eventIdRef.current === selectedEventId && setupGenerationRef.current === generation) setSearchResults(response.data)
    } catch (searchError) {
      setError(searchError.response?.data?.error || 'Attendee search failed.')
    } finally {
      setSearching(false)
    }
  }

  const reverseAdmission = async action => {
    if (!device || !manifest) return
    try {
      await queueReversal({ eventId, deviceId: device.id, manifestVersion: manifest.payload.version,
        ticketId: action.ticket_id, reversesActionUuid: action.action_uuid, source: online ? 'online' : 'offline' })
      await refreshPending(eventId, device)
      showResult({ type: 'success', message: 'Reversal queued', detail: 'The admission reversal will be reconciled append-only.' })
      if (online) syncQueue()
    } catch (reversalError) {
      setError(reversalError.message)
    }
  }

  const downloadDoorList = async () => {
    const response = await apiClient.get(`/organizer/events/${eventId}/admissions/door_list`, { responseType: 'blob' })
    const url = URL.createObjectURL(response.data)
    const link = document.createElement('a')
    link.href = url
    link.download = `hafapass-door-list-${eventId}.pdf`
    link.click()
    URL.revokeObjectURL(url)
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

  return (
    <div className="mx-auto max-w-6xl px-4 py-6 sm:py-8">
      <div className="mb-6 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[0.18em] text-brand-600">Event day</p>
          <h1 className="font-display text-3xl font-bold text-neutral-950">Admissions control</h1>
          <p className="mt-1 text-sm text-neutral-600">Scan tickets at the door. Prepare this device online before the event, then sync saved scans when connected.</p>
          <p className="mt-1 text-xs text-neutral-500">Sync saved scans before signing out or changing accounts. Signing out removes saved access and attendee details. Unsent scans can only be recovered by the original staff account after reconnecting.</p>
        </div>
        <select value={eventId} onChange={event => setEventId(event.target.value)} className="input max-w-sm" aria-label="Event to scan">
          {!events.length && <option value="">No assigned events</option>}
          {events.map(event => <option key={event.id} value={event.id}>{event.title}</option>)}
        </select>
      </div>

      <div className="mb-5 grid gap-3 sm:grid-cols-4">
        <div className={`rounded-xl border p-3 ${online ? 'border-emerald-200 bg-emerald-50' : 'border-amber-200 bg-amber-50'}`}>
          <p className="flex items-center gap-2 text-sm font-semibold">{online ? <ShieldCheck className="h-4 w-4" /> : <CloudOff className="h-4 w-4" />}{online ? 'Online' : 'Offline mode'}</p>
        </div>
        <div className="rounded-xl border border-neutral-200 bg-white p-3"><p className="text-xs text-neutral-500">Queued locally</p><p className="text-xl font-bold" data-testid="scanner-pending-count">{pendingCount}</p></div>
        <div className="rounded-xl border border-neutral-200 bg-white p-3"><p className="text-xs text-neutral-500">Scanned this session</p><p className="text-xl font-bold">{sessionCount}</p></div>
        <button onClick={() => syncQueue()} disabled={!ready || !online || syncing} className="btn-secondary flex items-center justify-center gap-2 disabled:opacity-50">
          {syncing ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />} Sync now
        </button>
      </div>

      {error && <div className="mb-5 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-800">{error}</div>}
      {setupBusy && <div className="mb-5 flex items-center gap-2 rounded-xl border bg-white p-4 text-sm"><Loader2 className="h-4 w-4 animate-spin" /> Authorizing device and verifying manifest…</div>}

      <div className="grid gap-6 lg:grid-cols-[1.35fr_.65fr]">
        <div className="space-y-5">
          <ResultPanel result={scanResult} />
          <section className="overflow-hidden rounded-2xl bg-neutral-950 shadow-lg">
            <div className="relative aspect-[4/3]">
              <video ref={videoRef} className={`h-full w-full object-cover ${scanning ? '' : 'hidden'}`} playsInline muted />
              {!scanning && (
                <div className="absolute inset-0 flex flex-col items-center justify-center text-neutral-400">
                  <Camera className="mb-3 h-14 w-14" /><p className="text-sm">Camera preview</p>
                </div>
              )}
              {scanning && <div className="pointer-events-none absolute inset-0 m-auto h-52 w-52 rounded-3xl border-4 border-white/80 shadow-[0_0_0_9999px_rgba(0,0,0,.28)]" />}
            </div>
            <button onClick={scanning ? stopCamera : startCamera} disabled={!ready}
              className="flex w-full items-center justify-center gap-2 bg-brand-600 px-4 py-4 font-semibold text-white disabled:bg-neutral-700">
              {scanning ? <><StopCircle className="h-5 w-5" /> Stop camera</> : <><Camera className="h-5 w-5" /> Start QR scanner</>}
            </button>
          </section>
          {cameraError && <p className="rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">{cameraError}</p>}

          <section className="rounded-2xl border border-neutral-200 bg-white p-5">
            <h2 className="font-semibold text-neutral-950">Manual credential</h2>
            <p className="mb-3 text-sm text-neutral-500">Paste the QR value when the camera cannot read a damaged screen or printout.</p>
            <form onSubmit={event => { event.preventDefault(); processCredential(manualCode); setManualCode('') }} className="flex flex-col gap-2 sm:flex-row">
              <input value={manualCode} onChange={event => setManualCode(event.target.value)} className="input flex-1" aria-label="Ticket QR credential" placeholder="Ticket QR credential" disabled={!ready} />
              <button className="btn-primary" disabled={!ready || !manualCode.trim()}>Validate</button>
            </form>
          </section>

          <section className="rounded-2xl border border-neutral-200 bg-white p-5">
            <h2 className="font-semibold text-neutral-950">Attendee lookup</h2>
            <p className="mb-3 text-sm text-neutral-500">Online fallback by attendee name or HafaPass ticket number. Email addresses are never returned.</p>
            <form onSubmit={runSearch} className="flex flex-col gap-2 sm:flex-row">
              <input value={searchQuery} onChange={event => setSearchQuery(event.target.value)} className="input flex-1" aria-label="Attendee name or ticket number" placeholder="Name or HP-T123" disabled={!online} />
              <button className="btn-secondary flex items-center gap-2" disabled={!online || searching || searchQuery.trim().length < 2}><Search className="h-4 w-4" /> Search</button>
            </form>
            <div className="mt-3 space-y-2">
              {searchResults.map(ticket => (
                <div key={ticket.id} className="flex items-center justify-between gap-3 rounded-xl bg-neutral-50 p-3 text-sm">
                  <div><p className="font-semibold">{ticket.attendee_name || 'Guest'} · {ticket.code}</p><p className="text-neutral-500">{ticket.ticket_type} · {ticket.status}</p></div>
                  <button className="btn-primary text-sm" disabled={!ticket.admission_allowed || !ticketsById.has(Number(ticket.id))}
                    onClick={() => { const entry = ticketsById.get(Number(ticket.id)); admitEntry(entry, entry.credential_hash, performance.now(), 'manual_lookup') }}>Admit</button>
                </div>
              ))}
            </div>
          </section>
        </div>

        <aside className="space-y-5">
          <section className="rounded-2xl border border-neutral-200 bg-white p-5">
            <div className="flex items-start gap-3"><Smartphone className="mt-1 h-5 w-5 text-brand-600" /><div>
              <h2 className="font-semibold">{device?.name || 'Device not authorized'}</h2>
              <p className="text-xs text-neutral-500">{selectedEvent?.title}</p>
              {manifest && <p className="mt-2 text-xs text-neutral-500">Manifest v{manifest.payload.version} · {manifest.payload.tickets.length} tickets<br />Expires {new Date(manifest.payload.expires_at).toLocaleString()}</p>}
              {!ready && pendingCount > 0 && <p className="mt-3 text-sm text-amber-950">Saved scans are retained. Reconnect with the original staff account to confirm them before resetting this device. Ask a manager if authorization cannot be restored.</p>}
              {!ready && recoveryDevice && pendingCount > 0 && <button disabled={!online || syncing || setupBusy} onClick={() => syncQueue({ selectedDevice: recoveryDevice })} className="btn-secondary mt-3 text-sm">Sync saved scans</button>}
              {eventId && <button disabled={!online || syncing || setupBusy} onClick={resetScanner} className="mt-3 block min-h-11 text-xs font-semibold text-neutral-500 hover:text-red-700 disabled:opacity-50">Reset trusted device</button>}
            </div></div>
          </section>

          {dashboard && (
            <section className="rounded-2xl border border-neutral-200 bg-white p-5">
              <div className="mb-4 flex items-center justify-between"><h2 className="font-semibold">Live doors</h2><button onClick={downloadDoorList} className="text-brand-700" title="Download emergency door list"><Download className="h-5 w-5" /></button></div>
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
                {dashboard.recent_actions.filter(action => action.kind === 'admit' && action.result === 'accepted').slice(0, 8).map(action => (
                  <div key={action.action_uuid} className="flex items-center justify-between gap-2 rounded-lg bg-neutral-50 p-2 text-xs">
                    <span>{action.attendee?.attendee_name || action.attendee?.code}</span>
                    <button onClick={() => reverseAdmission(action)} className="flex items-center gap-1 font-semibold text-amber-700"><RotateCcw className="h-3.5 w-3.5" /> Undo</button>
                  </div>
                ))}
              </div>
            </section>
          )}
        </aside>
      </div>
    </div>
  )
}
