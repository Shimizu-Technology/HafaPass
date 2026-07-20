import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  AlertTriangle, Camera, CheckCircle2, CloudOff, Download, Loader2, RefreshCw,
  RotateCcw, Search, ShieldCheck, Smartphone, StopCircle, XCircle,
} from 'lucide-react'
import apiClient from '../../api/client'
import {
  applySyncResults, clearEventAdmissionData, loadDevice, loadUsableManifest, localScanState, queueAdmission,
  queuedActions, queueReversal, saveDevice, saveVerifiedManifest, sha256Hex,
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

export default function ScannerPage() {
  const [events, setEvents] = useState([])
  const [eventId, setEventId] = useState('')
  const [device, setDevice] = useState(null)
  const [manifest, setManifest] = useState(null)
  const [dashboard, setDashboard] = useState(null)
  const [pendingCount, setPendingCount] = useState(0)
  const [online, setOnline] = useState(navigator.onLine)
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
    setPendingCount((await queuedActions(selectedEventId, selectedDevice.id)).length)
  }, [])

  const fetchDashboard = useCallback(async selectedEventId => {
    if (!selectedEventId || !navigator.onLine) return
    const response = await apiClient.get(`/organizer/events/${selectedEventId}/admissions`)
    setDashboard(response.data)
  }, [])

  const downloadManifest = useCallback(async (selectedEventId, selectedDevice) => {
    const response = await apiClient.get(`/organizer/events/${selectedEventId}/scanner_devices/${selectedDevice.id}/manifest`)
    await saveVerifiedManifest(response.data)
    setManifest(response.data)
    return response.data
  }, [])

  const syncQueue = useCallback(async ({ selectedEventId = eventId, selectedDevice = device, quiet = false } = {}) => {
    if (!selectedEventId || !selectedDevice || !navigator.onLine || syncing) return
    let remaining = await queuedActions(selectedEventId, selectedDevice.id)
    if (!remaining.length) {
      if (!quiet) await Promise.all([downloadManifest(selectedEventId, selectedDevice), fetchDashboard(selectedEventId)])
      return
    }
    setSyncing(true)
    try {
      let currentDevice = selectedDevice
      while (remaining.length) {
        const batch = remaining.slice(0, 500)
        const response = await apiClient.post(
          `/organizer/events/${selectedEventId}/scanner_devices/${currentDevice.id}/sync`,
          { actions: batch.map(({ event_id: _eventId, device_id: _deviceId, ...action }) => action) },
        )
        await applySyncResults(selectedEventId, response.data.device, response.data.results)
        currentDevice = response.data.device
        setDashboard(current => current ? { ...current, counts: response.data.summary } : current)
        remaining = await queuedActions(selectedEventId, currentDevice.id)
      }
      setDevice(currentDevice)
      await refreshPending(selectedEventId, currentDevice)
      await Promise.all([downloadManifest(selectedEventId, currentDevice), fetchDashboard(selectedEventId)])
    } catch (syncError) {
      if (!quiet) setError(syncError.response?.data?.error || 'Queued scans could not be synchronized.')
    } finally {
      setSyncing(false)
    }
  }, [device, downloadManifest, eventId, fetchDashboard, refreshPending, syncing])

  const configureEvent = useCallback(async selectedEventId => {
    if (!selectedEventId) return
    setSetupBusy(true)
    setError(null)
    setScanResult(null)
    try {
      let storedDevice = await loadDevice(selectedEventId)
      let storedManifest = await loadUsableManifest(selectedEventId)
      if (navigator.onLine) {
        const registration = await apiClient.post(`/organizer/events/${selectedEventId}/scanner_devices`, {
          identifier: browserIdentifier(),
          name: `Scanner · ${navigator.platform || 'browser'}`,
        })
        storedDevice = registration.data
        await saveDevice(selectedEventId, storedDevice)
        storedManifest = await downloadManifest(selectedEventId, storedDevice)
        await fetchDashboard(selectedEventId)
      }
      if (!storedDevice || !storedManifest) throw new Error('Connect once to authorize this scanner and download the event manifest.')
      if (!storedDevice.effective || new Date(storedDevice.authorization_expires_at).getTime() <= Date.now()) {
        throw new Error('This scanner authorization has expired. Reconnect and ask an event manager to renew access.')
      }
      setDevice(storedDevice)
      setManifest(storedManifest)
      await refreshPending(selectedEventId, storedDevice)
    } catch (setupError) {
      setDevice(null)
      setManifest(null)
      setDashboard(null)
      setError(setupError.response?.data?.error || setupError.message || 'Scanner setup failed.')
    } finally {
      setSetupBusy(false)
    }
  }, [downloadManifest, fetchDashboard, refreshPending])

  useEffect(() => {
    const handleOnline = () => setOnline(true)
    const handleOffline = () => setOnline(false)
    window.addEventListener('online', handleOnline)
    window.addEventListener('offline', handleOffline)
    return () => {
      window.removeEventListener('online', handleOnline)
      window.removeEventListener('offline', handleOffline)
    }
  }, [])

  useEffect(() => {
    apiClient.get('/organizer/events').then(response => {
      const accessible = response.data.events || []
      setEvents(accessible)
      const saved = window.localStorage.getItem('hafapass_scanner_event_id')
      const initial = accessible.find(event => String(event.id) === saved)?.id || accessible[0]?.id
      if (initial) setEventId(String(initial))
      else setSetupBusy(false)
    }).catch(async () => {
      const saved = window.localStorage.getItem('hafapass_scanner_event_id')
      const cached = saved ? await loadUsableManifest(saved).catch(() => null) : null
      if (cached) {
        setEvents([{ ...cached.payload.event, id: Number(saved) }])
        setEventId(saved)
      } else {
        setError('Could not load assigned events. Connect once to authorize this scanner and download a manifest.')
        setSetupBusy(false)
      }
    })
  }, [])

  useEffect(() => {
    if (!eventId) return
    window.localStorage.setItem('hafapass_scanner_event_id', eventId)
    configureEvent(eventId)
  }, [configureEvent, eventId])

  useEffect(() => {
    if (online && eventId && device) syncQueue({ quiet: true })
  }, [device, eventId, online, syncQueue])

  const showResult = useCallback(result => {
    setScanResult(result)
    if (result.type === 'success') setSessionCount(count => count + 1)
    if (navigator.vibrate) navigator.vibrate(result.type === 'success' ? 80 : [100, 60, 100])
  }, [])

  const admitEntry = useCallback(async (ticket, hash, startedAt = performance.now(), clientStatus = 'locally_accepted') => {
    if (!device || !manifest) return
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

    await queueAdmission({
      eventId,
      deviceId: device.id,
      manifestVersion: manifest.payload.version,
      ticket,
      credentialHash: hash,
      source: navigator.onLine ? 'online' : 'offline',
      clientStatus,
    })
    await refreshPending(eventId, device)
    showResult({ type: 'success', message: navigator.onLine ? 'Admitted — syncing' : 'Admitted offline',
      detail: navigator.onLine ? 'Local validation passed. Server confirmation is in progress.' : 'Saved safely on this device and queued for reconciliation.',
      ticket, latency: performance.now() - startedAt })
    if (navigator.onLine) syncQueue({ quiet: true })
  }, [device, eventId, manifest, refreshPending, showResult, syncQueue])

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
  }, [admitEntry, device, manifest, showResult, ticketsByHash])

  const stopCamera = useCallback(() => {
    if (detectorTimerRef.current) clearInterval(detectorTimerRef.current)
    detectorTimerRef.current = null
    zxingControlsRef.current?.stop()
    zxingControlsRef.current = null
    streamRef.current?.getTracks().forEach(track => track.stop())
    streamRef.current = null
    if (videoRef.current) videoRef.current.srcObject = null
    setScanning(false)
  }, [])

  const handleDecoded = useCallback(code => {
    if (!code || scanCooldownRef.current) return
    scanCooldownRef.current = true
    processCredential(code).finally(() => setTimeout(() => { scanCooldownRef.current = false }, 1800))
  }, [processCredential])

  const startCamera = useCallback(async () => {
    setCameraError(null)
    setScanning(true)
    try {
      if ('BarcodeDetector' in window) {
        const stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: 'environment' } } })
        streamRef.current = stream
        videoRef.current.srcObject = stream
        await videoRef.current.play()
        const detector = new window.BarcodeDetector({ formats: ['qr_code'] })
        detectorTimerRef.current = setInterval(async () => {
          if (!videoRef.current || scanCooldownRef.current) return
          const codes = await detector.detect(videoRef.current).catch(() => [])
          handleDecoded(codes[0]?.rawValue)
        }, 250)
      } else {
        const { BrowserQRCodeReader } = await import('@zxing/browser')
        const reader = new BrowserQRCodeReader()
        zxingControlsRef.current = await reader.decodeFromVideoDevice(undefined, videoRef.current, result => {
          if (result) handleDecoded(result.getText())
        })
      }
    } catch (cameraFailure) {
      stopCamera()
      setCameraError(cameraFailure.name === 'NotAllowedError'
        ? 'Camera permission was denied. Allow it in browser settings or use manual entry.'
        : `Camera could not start: ${cameraFailure.message}`)
    }
  }, [handleDecoded, stopCamera])

  useEffect(() => () => stopCamera(), [stopCamera])

  const runSearch = async event => {
    event.preventDefault()
    if (!online || searchQuery.trim().length < 2) return
    setSearching(true)
    try {
      const response = await apiClient.get(`/organizer/events/${eventId}/admissions/search`, { params: { q: searchQuery.trim() } })
      setSearchResults(response.data)
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
        ticketId: action.ticket_id, reversesActionUuid: action.action_uuid, source: navigator.onLine ? 'online' : 'offline' })
      await refreshPending(eventId, device)
      showResult({ type: 'success', message: 'Reversal queued', detail: 'The admission reversal will be reconciled append-only.' })
      if (navigator.onLine) syncQueue()
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
    if (pendingCount) return setError('Sync every queued action before resetting this scanner.')
    if (!window.confirm('Reset this event scanner and trust a newly downloaded signing key?')) return
    stopCamera()
    await clearEventAdmissionData(eventId)
    setDevice(null)
    setManifest(null)
    await configureEvent(eventId)
  }

  const selectedEvent = events.find(event => String(event.id) === eventId)
  const ready = Boolean(device && manifest)

  return (
    <div className="mx-auto max-w-6xl px-4 py-6 sm:py-8">
      <div className="mb-6 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[0.18em] text-brand-600">Event day</p>
          <h1 className="font-display text-3xl font-bold text-neutral-950">Admissions control</h1>
          <p className="mt-1 text-sm text-neutral-600">Signed offline manifests, local-first QR checks, and cross-device reconciliation.</p>
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
        <div className="rounded-xl border border-neutral-200 bg-white p-3"><p className="text-xs text-neutral-500">This session</p><p className="text-xl font-bold">{sessionCount}</p></div>
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
            <form onSubmit={event => { event.preventDefault(); processCredential(manualCode); setManualCode('') }} className="flex gap-2">
              <input value={manualCode} onChange={event => setManualCode(event.target.value)} className="input flex-1" placeholder="Ticket QR credential" disabled={!ready} />
              <button className="btn-primary" disabled={!ready || !manualCode.trim()}>Validate</button>
            </form>
          </section>

          <section className="rounded-2xl border border-neutral-200 bg-white p-5">
            <h2 className="font-semibold text-neutral-950">Attendee lookup</h2>
            <p className="mb-3 text-sm text-neutral-500">Online fallback by attendee name or HafaPass ticket number. Email addresses are never returned.</p>
            <form onSubmit={runSearch} className="flex gap-2">
              <input value={searchQuery} onChange={event => setSearchQuery(event.target.value)} className="input flex-1" placeholder="Name or HP-T123" disabled={!online} />
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
              {ready && <button onClick={resetScanner} className="mt-3 text-xs font-semibold text-neutral-500 hover:text-red-700">Reset trusted device</button>}
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
