import EventWorkspace from '../../components/EventWorkspace'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useParams } from 'react-router-dom'
import { Accessibility, AlertTriangle, Loader2, PauseCircle, PlayCircle } from 'lucide-react'
import apiClient from '../../api/client'
import EventAccessNotice from '../../components/EventAccessNotice'
import useLaunchCapabilities from '../../hooks/useLaunchCapabilities'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'

const rowLabel = (index) => {
  let value = index + 1
  let label = ''
  while (value > 0) {
    value -= 1
    label = String.fromCharCode(65 + (value % 26)) + label
    value = Math.floor(value / 26)
  }
  return label
}

function SeatingSession({ id, identity }) {
  const { current, beginRequest } = useOrganizerRequests(identity, `/dashboard/events/${id}/seating`)
  const capabilities = useLaunchCapabilities()
  const loadState = useRef({ generation: 0, request: null })
  const layoutState = useRef({ generation: 0, request: null })
  const initialized = useRef(false)
  const busyRef = useRef(false)
  const storageKey = `hafapass:seating-outcome:${identity.owner}:${identity.organizationId}:${id}`
  const [pending, setPending] = useState(() => { try { const raw = window.sessionStorage.getItem(storageKey); if (raw === null) return null; const value = JSON.parse(raw); return value && typeof value.label === 'string' ? value : { label: 'A previous seating change' } } catch { return { label: 'A previous seating change' } } })
  const pendingRef = useRef(pending)
  const [reviewed, setReviewed] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const [layoutBusy, setLayoutBusy] = useState(false)
  const [layoutReady, setLayoutReady] = useState(false)
  const [layoutAttempt, setLayoutAttempt] = useState(0)
  const [layoutError, setLayoutError] = useState(null)
  const [event, setEvent] = useState(null)
  const [seating, setSeating] = useState(null)
  const [layouts, setLayouts] = useState([])
  const [selectedLayoutId, setSelectedLayoutId] = useState('')
  const selectedLayoutRef = useRef(selectedLayoutId)
  selectedLayoutRef.current = selectedLayoutId
  const [zoneMappings, setZoneMappings] = useState({})
  const [selectedSeatIds, setSelectedSeatIds] = useState([])
  const [reason, setReason] = useState('')
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState(null)
  const [layoutName, setLayoutName] = useState('Main floor')
  const [rowCount, setRowCount] = useState(6)
  const [seatsPerRow, setSeatsPerRow] = useState(12)
  const [accessiblePairs, setAccessiblePairs] = useState(1)

  const clearPending = () => {
    try { window.sessionStorage.removeItem(storageKey); pendingRef.current = null; setPending(null); return true }
    catch { setError('The saved recovery record could not be cleared. Check browser storage before another change.'); return false }
  }
  const load = useCallback(async () => {
    const request = beginRequest()
    if (!request) return
    loadState.current.request?.controller.abort()
    const generation = ++loadState.current.generation
    loadState.current.request = request
    const canApply = () => request.current() && generation === loadState.current.generation
    if (!initialized.current) setLoading(true)
    setRefreshing(true); setError(null)
    if (pendingRef.current) setReviewed(false)
    try {
      const eventResponse = await apiClient.get(`/organizer/events/${id}`, request.config)
      if (!canApply()) return
      const saved = eventResponse.data
      if (String(saved.id) !== String(id) || (identity.organizationId != null && saved.organization_id != null && String(saved.organization_id) !== String(identity.organizationId))) throw new Error('Wrong event context')
      if (saved.permissions?.manage_inventory !== true) { setEvent(saved); setSeating(null); setLayouts([]); return }
      const seatingResponse = await apiClient.get(`/organizer/events/${id}/seating`, request.config)
      if (!canApply()) return
      const layoutsResponse = seatingResponse.data.assigned_seating || capabilities.assigned_seating !== true ? null : await apiClient.get('/organizer/venue_layouts', request.config)
      if (!canApply()) return
      setEvent(saved); setSeating(seatingResponse.data)
      setLayouts(layoutsResponse?.data.venue_layouts || [])
      initialized.current = true
      setReviewed(Boolean(pendingRef.current))
    } catch (requestError) {
      if (!canApply()) return
      if ([401, 403, 404].includes(requestError.response?.status)) setEvent(null)
      setError(requestError.response?.data?.error || 'Unable to load seating operations. Your layout and operational drafts are retained.')
    } finally {
      if (canApply()) { setLoading(false); setRefreshing(false) }
      request.release()
    }
  }, [id, beginRequest, identity.organizationId, capabilities.assigned_seating])
  useEffect(() => { load() }, [load])

  const selectedLayout = useMemo(
    () => layouts.find(layout => layout.id === Number(selectedLayoutId)),
    [layouts, selectedLayoutId],
  )

  useEffect(() => {
    setLayoutReady(false); setLayoutBusy(false)
    if (!selectedLayoutId || seating?.assigned_seating || capabilities.assigned_seating !== true || event?.permissions?.manage_inventory !== true) return
    const request = beginRequest()
    if (!request) return
    layoutState.current.request?.controller.abort()
    const generation = ++layoutState.current.generation
    layoutState.current.request = request
    const canApply = () => request.current() && generation === layoutState.current.generation && selectedLayoutRef.current === selectedLayoutId
    setLayoutBusy(true); setLayoutError(null)
    apiClient.get(`/organizer/venue_layouts/${selectedLayoutId}`, request.config).then(response => {
      if (!canApply() || String(response.data.id) !== String(selectedLayoutId)) return
      setLayouts(items => items.map(layout => layout.id === response.data.id ? response.data : layout))
      setZoneMappings(existing => Object.fromEntries((response.data.price_zones || []).map(zone => [zone.id, existing[zone.id] || event.ticket_types?.[0]?.id || ''])))
      setLayoutReady(true)
    }).catch(() => { if (canApply()) setLayoutError('Unable to load that venue layout. Your selection is retained; retry before activating it.') })
      .finally(() => { if (canApply()) setLayoutBusy(false); request.release() })
    return () => request.controller.abort()
  }, [selectedLayoutId, event?.ticket_types, event?.permissions?.manage_inventory, seating?.assigned_seating, capabilities.assigned_seating, beginRequest, layoutAttempt])

  const mutate = async (label, send, apply = () => {}) => {
    if (!current() || busyRef.current || pendingRef.current || event?.permissions?.manage_inventory !== true) return
    const request = beginRequest()
    if (!request) return
    const record = { label, started_at: new Date().toISOString() }
    try { window.sessionStorage.setItem(storageKey, JSON.stringify(record)) }
    catch { setError('The recovery record could not be saved. Enable browser storage before changing seating.'); request.release(); return }
    pendingRef.current = record; setPending(record); setReviewed(false)
    busyRef.current = true; setSaving(true); setError(null)
    try {
      const response = await send(request.config)
      if (!request.current()) return
      if (!clearPending()) return
      apply(response)
      await load()
    } catch (requestError) {
      if (!request.current()) return
      const uncertain = !requestError.response || requestError.response.status >= 500 || [408, 409, 429].includes(requestError.response.status)
      if (!uncertain) clearPending()
      if ([401, 403, 404].includes(requestError.response?.status)) setEvent(null)
      setError(uncertain ? 'The seating response was not confirmed. Refresh saved seating and verify the outcome before another change.' : requestError.response?.data?.errors?.join(', ') || requestError.response?.data?.error || 'The seating change failed. Your draft is retained.')
    } finally {
      if (request.current()) { busyRef.current = false; setSaving(false) }
      request.release()
    }
  }
  const createSimpleLayout = () => {
    if (capabilities.assigned_seating !== true) return
    if (!event?.venue_id) { setError('Choose a verified venue on the event before creating a seat layout.'); return }
    const rowTotal = Number(rowCount), width = Number(seatsPerRow), pairs = Number(accessiblePairs)
    if (!layoutName.trim() || !Number.isInteger(rowTotal) || rowTotal < 1 || rowTotal > 50 || !Number.isInteger(width) || width < 2 || width > 100 || !Number.isInteger(pairs) || pairs < 0 || pairs > Math.min(3, Math.floor(width / 2))) {
      setError('Enter a layout name, 1–50 rows, 2–100 seats per row, and up to three accessible pairs that fit the front row.'); return
    }
    const rows = Array.from({ length: rowTotal }, (_, rowIndex) => ({ label: rowLabel(rowIndex), seats: Array.from({ length: width }, (_, seatIndex) => {
      const pairIndex = Math.floor(seatIndex / 2)
      const protectedSeat = rowIndex === 0 && seatIndex < pairs * 2
      return { label: String(seatIndex + 1), position: seatIndex, price_zone_code: 'MAIN', accessibility_kind: protectedSeat ? (seatIndex % 2 === 0 ? 'wheelchair' : 'companion') : 'standard', companion_group: protectedSeat ? `front-${pairIndex + 1}` : null }
    }) }))
    return mutate('Create venue layout', config => apiClient.post('/organizer/venue_layouts', { venue_id: event.venue_id, name: layoutName, publish: true, price_zones: [{ name: 'Main price', code: 'MAIN', color: '#2563EB' }], sections: [{ name: 'Main floor', code: 'MAIN', rows }] }, config), response => { selectedLayoutRef.current = String(response.data.id); setSelectedLayoutId(String(response.data.id)); setZoneMappings({}); setLayoutReady(false) })
  }
  const mapped = layoutReady && selectedLayout?.price_zones?.length > 0 && selectedLayout.price_zones.every(zone => event?.ticket_types?.some(type => Number(type.id) === Number(zoneMappings[zone.id])))
  const activateLayout = () => {
    if (capabilities.assigned_seating !== true || !mapped) return
    return mutate('Activate assigned seating', config => apiClient.post(`/organizer/events/${id}/seating`, { venue_layout_id: Number(selectedLayoutId), zone_ticket_types: zoneMappings }, config))
  }
  const operation = (action, payload = {}) => mutate('Update seating operations', config => apiClient.post(`/organizer/events/${id}/seating/${action}`, payload, config), () => { setSelectedSeatIds([]); setReason('') })
  const acknowledge = () => {
    if (!current() || busyRef.current || !reviewed) return
    if (clearPending()) setError(null)
  }

  const toggleSeat = (seatId) => setSelectedSeatIds(current => current.includes(seatId)
    ? current.filter(idValue => idValue !== seatId)
    : [...current, seatId])

  if (loading) return <div role="status" aria-label="Loading seating operations" className="flex justify-center py-20"><Loader2 className="h-8 w-8 animate-spin text-brand-600" /></div>

  if (!event) return <div className="mx-auto max-w-3xl p-6"><p role="alert" className="text-red-700">{error || 'Seating operations could not be loaded.'}</p><button disabled={refreshing} onClick={load} className="btn-secondary mt-4">Retry seating operations</button></div>
  if (event.permissions?.manage_inventory !== true) return <EventAccessNotice event={event} message="Your event access does not include seating management." />
  if (!seating?.assigned_seating && capabilities.assigned_seating !== true) return <EventAccessNotice event={event} message="Assigned seating is not enabled for this platform." />
  const locked = saving || Boolean(pending)
  return (
    <EventWorkspace eventId={id} event={event}><div className="mx-auto max-w-6xl">
      <div className="mb-8">
        <h2 className="font-display text-3xl font-bold text-neutral-950">Assigned seating</h2>
        <p className="mt-1 text-neutral-600">{event?.title} · reusable layouts, accessible inventory, and live seat controls</p>
      </div>
      {error && <p className="mb-6 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700" role="alert">{error}</p>}

      <button disabled={saving || refreshing} onClick={load} className="btn-secondary mb-4">{refreshing ? 'Refreshing seating…' : 'Refresh saved seating'}</button>
      {pending && <div role="status" className="mb-4 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950"><p>{pending.label} may have completed. Check the saved layout and seat state before another change.</p><button disabled={saving || refreshing || !reviewed} onClick={acknowledge} className="btn-secondary mt-3">I verified the saved seating</button></div>}
      <fieldset disabled={locked} className="min-w-0"><legend className="sr-only">Seating management controls</legend>
      {!seating?.assigned_seating ? (
        <div className="grid gap-6 lg:grid-cols-2">
          <section className="card p-6">
            <h2 className="text-lg font-semibold text-neutral-900">Create a pilot layout</h2>
            <p className="mt-1 text-sm text-neutral-600">Generate a clean section-and-row map. Protected wheelchair and companion seats remain paired.</p>
            <div className="mt-5 space-y-4">
              <label className="block text-sm font-medium text-neutral-700">Layout name<input className="input mt-1" value={layoutName} onChange={eventValue => setLayoutName(eventValue.target.value)} /></label>
              <div className="grid grid-cols-3 gap-3">
                <label className="text-sm font-medium text-neutral-700">Rows<input className="input mt-1" type="number" min="1" max="50" value={rowCount} onChange={eventValue => setRowCount(eventValue.target.value)} /></label>
                <label className="text-sm font-medium text-neutral-700">Seats / row<input className="input mt-1" type="number" min="2" max="100" value={seatsPerRow} onChange={eventValue => setSeatsPerRow(eventValue.target.value)} /></label>
                <label className="text-sm font-medium text-neutral-700">Accessible pairs<input className="input mt-1" type="number" min="0" max="3" value={accessiblePairs} onChange={eventValue => setAccessiblePairs(eventValue.target.value)} /></label>
              </div>
              <button className="btn-secondary w-full" disabled={locked} onClick={createSimpleLayout}>Create reusable layout</button>
            </div>
          </section>

          <section className="card p-6">
            <h2 className="text-lg font-semibold text-neutral-900">Activate for this event</h2>
            <label className="mt-5 block text-sm font-medium text-neutral-700">Published venue layout
              <select className="input mt-1" value={selectedLayoutId} onChange={eventValue => { selectedLayoutRef.current = eventValue.target.value; setSelectedLayoutId(eventValue.target.value); setZoneMappings({}); setLayoutReady(false) }}>
                <option value="">Choose a layout</option>
                {layouts.filter(layout => layout.status === 'published').map(layout => <option key={layout.id} value={layout.id}>{layout.name} · {layout.seat_count} seats</option>)}
              </select>
            </label>
            {layoutBusy && <p role="status" className="mt-3 text-sm text-neutral-600">Loading layout details…</p>}
            {layoutError && <p role="alert" className="mt-3 text-sm text-red-700">{layoutError} <button type="button" onClick={() => setLayoutAttempt(value => value + 1)} className="min-h-11 font-semibold underline">Retry layout details</button></p>}
            {selectedLayout?.price_zones?.map(zone => (
              <label key={zone.id} className="mt-4 block text-sm font-medium text-neutral-700">{zone.name} ticket type
                <select className="input mt-1" value={zoneMappings[zone.id] || ''} onChange={eventValue => setZoneMappings(current => ({ ...current, [zone.id]: Number(eventValue.target.value) }))}>
                  <option value="">Choose a ticket type</option>
                  {event?.ticket_types?.map(ticketType => <option key={ticketType.id} value={ticketType.id}>{ticketType.name} · ${(ticketType.price_cents / 100).toFixed(2)}</option>)}
                </select>
              </label>
            ))}
            <button className="btn-primary mt-5 w-full" disabled={locked || layoutBusy || !mapped} onClick={activateLayout}>Activate assigned seating</button>
          </section>
        </div>
      ) : (
        <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_22rem]">
          <section className="card p-5">
            <div className="mb-5 flex flex-wrap items-start justify-between gap-3">
              <div><h2 className="text-lg font-semibold text-neutral-900">Live seat map</h2><p className="text-sm text-neutral-600">Select seats to block, hold, release, or move into general sale.</p></div>
              <span className={`rounded-full px-3 py-1 text-xs font-semibold ${seating.suspended ? 'bg-amber-100 text-amber-900' : 'bg-emerald-100 text-emerald-800'}`}>{seating.suspended ? 'Sales paused' : 'Sales open'}</span>
            </div>
            <div className="space-y-6 overflow-auto rounded-2xl bg-neutral-50 p-4">
              {seating.sections?.map(section => <section key={section.id}>
                <h3 className="mb-3 text-center text-sm font-semibold uppercase tracking-wide text-neutral-700">{section.name}</h3>
                <div className="space-y-3">{section.rows.map(row => <div key={row.id} className="flex items-center gap-3">
                  <span className="w-8 text-center text-xs font-semibold text-neutral-500">{row.label}</span>
                  <div className="flex flex-wrap gap-2">{row.seats.map(seat => <button key={seat.id} type="button" aria-pressed={selectedSeatIds.includes(seat.id)} aria-label={`${seat.display_label}, ${seat.status}`} onClick={() => toggleSeat(seat.id)} className={`relative h-10 min-w-10 rounded-full border px-2 text-xs font-semibold ${selectedSeatIds.includes(seat.id) ? 'border-brand-700 bg-brand-700 text-white' : seat.status === 'available' ? 'border-brand-400 bg-white text-brand-800' : 'border-neutral-300 bg-neutral-300 text-neutral-700'}`}>{seat.label}{seat.accessibility_kind !== 'standard' && <Accessibility className="absolute -right-1 -top-1 h-3.5 w-3.5 rounded-full bg-white text-blue-700" />}</button>)}</div>
                </div>)}</div>
              </section>)}
            </div>
          </section>

          <aside className="space-y-5">
            <section className="card p-5">
              <h2 className="font-semibold text-neutral-900">Emergency sales control</h2>
              <label className="mt-3 block text-sm font-medium text-neutral-700">Operational reason<textarea className="input mt-1" rows="3" value={reason} onChange={eventValue => setReason(eventValue.target.value)} /></label>
              {seating.suspended ? <button className="btn-primary mt-3 flex w-full items-center justify-center gap-2" disabled={locked} onClick={() => operation('resume')}><PlayCircle className="h-4 w-4" />Resume sales</button>
                : <button className="mt-3 flex w-full items-center justify-center gap-2 rounded-xl border border-amber-300 bg-amber-50 px-4 py-2.5 font-semibold text-amber-900" disabled={locked || !reason.trim()} onClick={() => operation('suspend', { reason })}><PauseCircle className="h-4 w-4" />Pause all sales</button>}
            </section>
            <section className="card p-5">
              <h2 className="font-semibold text-neutral-900">Selected seats</h2>
              <p className="mt-1 text-sm text-neutral-600">{selectedSeatIds.length} selected. Sold and actively held seats cannot be blocked.</p>
              <div className="mt-3 grid grid-cols-2 gap-2">
                {['available', 'blocked', 'house_hold'].map(status => <button key={status} className="btn-secondary !px-2 !py-2 text-xs" disabled={locked || !reason.trim() || selectedSeatIds.length === 0} onClick={() => operation('update_seat_statuses', { event_seat_ids: selectedSeatIds, operational_status: status, reason })}>{status.replace('_', ' ')}</button>)}
              </div>
              <button className="mt-3 flex w-full items-center justify-center gap-2 rounded-xl border border-blue-200 bg-blue-50 px-3 py-2 text-sm font-semibold text-blue-900" disabled={locked || !reason.trim() || selectedSeatIds.length === 0} onClick={() => operation('release_accessible', { event_seat_ids: selectedSeatIds, reason })}><Accessibility className="h-4 w-4" />Controlled accessible release</button>
              <p className="mt-2 text-xs text-neutral-500">Release is allowed only when standard seats are sold out in the same section, price zone, or venue.</p>
            </section>
            <section className="card p-5">
              <h2 className="font-semibold text-neutral-900">Audit trail</h2>
              <ol className="mt-3 max-h-72 space-y-3 overflow-auto text-xs text-neutral-600">
                {seating.audit_events?.map(entry => <li key={entry.id} className="border-l-2 border-neutral-200 pl-3"><p className="font-semibold text-neutral-800">{entry.action}</p><p>{new Date(entry.occurred_at).toLocaleString()}</p></li>)}
              </ol>
            </section>
          </aside>
        </div>
      )}

      </fieldset>
      <div className="mt-8 rounded-2xl border border-amber-200 bg-amber-50 p-5 text-sm text-amber-950">
        <p className="flex items-center gap-2 font-semibold"><AlertTriangle className="h-4 w-4" />Accessibility and provider boundary</p>
        <p className="mt-1">Do not ask buyers for medical documentation. This native map remains the accessible purchasing path even when a visual chart provider is enabled.</p>
      </div>
    </div></EventWorkspace>
  )
}

export default function SeatingManagementPage() {
  const { id } = useParams()
  const identity = useOrganizerIdentity()
  const visit = useOrganizerPageVisit(`/dashboard/events/${id}/seating`)
  if (!visit.active) return null
  if (!identity.ready) return <p role="status" className="p-6">Preparing your account…</p>
  return <SeatingSession key={`${identity.accountKey}:${identity.organizationId}:${id}:${visit.generation}`} id={id} identity={identity} />
}
