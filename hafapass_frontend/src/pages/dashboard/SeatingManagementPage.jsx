import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { Accessibility, AlertTriangle, ArrowLeft, Loader2, PauseCircle, PlayCircle } from 'lucide-react'
import apiClient from '../../api/client'

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

export default function SeatingManagementPage() {
  const { id } = useParams()
  const [event, setEvent] = useState(null)
  const [seating, setSeating] = useState(null)
  const [layouts, setLayouts] = useState([])
  const [selectedLayoutId, setSelectedLayoutId] = useState('')
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

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const [eventResponse, seatingResponse, layoutsResponse] = await Promise.all([
        apiClient.get(`/organizer/events/${id}`),
        apiClient.get(`/organizer/events/${id}/seating`),
        apiClient.get('/organizer/venue_layouts'),
      ])
      setEvent(eventResponse.data)
      setSeating(seatingResponse.data)
      setLayouts(layoutsResponse.data.venue_layouts || [])
    } catch (err) {
      setError(err.response?.data?.error || 'Unable to load seating operations.')
    } finally {
      setLoading(false)
    }
  }, [id])

  useEffect(() => { load() }, [load])

  const selectedLayout = useMemo(
    () => layouts.find(layout => layout.id === Number(selectedLayoutId)),
    [layouts, selectedLayoutId],
  )

  useEffect(() => {
    if (!selectedLayoutId) return
    apiClient.get(`/organizer/venue_layouts/${selectedLayoutId}`).then(response => {
      setLayouts(current => current.map(layout => layout.id === response.data.id ? response.data : layout))
      const initial = {}
      response.data.price_zones.forEach(zone => { initial[zone.id] = event?.ticket_types?.[0]?.id || '' })
      setZoneMappings(initial)
    }).catch(() => setError('Unable to load that venue layout.'))
  }, [selectedLayoutId, event?.ticket_types])

  const createSimpleLayout = async () => {
    if (!event?.venue_id) {
      setError('Choose a verified venue on the event before creating a seat layout.')
      return
    }
    setSaving(true)
    setError(null)
    try {
      const rows = Array.from({ length: Number(rowCount) }, (_, rowIndex) => ({
        label: rowLabel(rowIndex),
        seats: Array.from({ length: Number(seatsPerRow) }, (_, seatIndex) => {
          const pairIndex = Math.floor(seatIndex / 2)
          const protectedSeat = rowIndex === 0 && pairIndex < Number(accessiblePairs) * 1 && seatIndex < Number(accessiblePairs) * 2
          return {
            label: String(seatIndex + 1),
            position: seatIndex,
            price_zone_code: 'MAIN',
            accessibility_kind: protectedSeat ? (seatIndex % 2 === 0 ? 'wheelchair' : 'companion') : 'standard',
            companion_group: protectedSeat ? `front-${pairIndex + 1}` : null,
          }
        }),
      }))
      const response = await apiClient.post('/organizer/venue_layouts', {
        venue_id: event.venue_id,
        name: layoutName,
        publish: true,
        price_zones: [{ name: 'Main price', code: 'MAIN', color: '#2563EB' }],
        sections: [{ name: 'Main floor', code: 'MAIN', rows }],
      })
      await load()
      setSelectedLayoutId(String(response.data.id))
    } catch (err) {
      setError(err.response?.data?.errors?.join(', ') || err.response?.data?.error || 'Could not create the layout.')
    } finally {
      setSaving(false)
    }
  }

  const activateLayout = async () => {
    setSaving(true)
    setError(null)
    try {
      await apiClient.post(`/organizer/events/${id}/seating`, {
        venue_layout_id: Number(selectedLayoutId),
        zone_ticket_types: zoneMappings,
      })
      await load()
    } catch (err) {
      setError(err.response?.data?.error || 'Could not activate assigned seating.')
    } finally {
      setSaving(false)
    }
  }

  const operation = async (action, payload = {}) => {
    setSaving(true)
    setError(null)
    try {
      await apiClient.post(`/organizer/events/${id}/seating/${action}`, payload)
      setSelectedSeatIds([])
      setReason('')
      await load()
    } catch (err) {
      setError(err.response?.data?.error || 'The seating operation failed.')
    } finally {
      setSaving(false)
    }
  }

  const toggleSeat = (seatId) => setSelectedSeatIds(current => current.includes(seatId)
    ? current.filter(idValue => idValue !== seatId)
    : [...current, seatId])

  if (loading) return <div className="flex justify-center py-20"><Loader2 className="h-8 w-8 animate-spin text-brand-600" /></div>

  return (
    <div className="mx-auto max-w-6xl px-4 py-8">
      <Link to={`/dashboard/events/${id}/edit`} className="mb-6 inline-flex items-center gap-1 text-sm font-medium text-brand-600">
        <ArrowLeft className="h-4 w-4" /> Back to event
      </Link>
      <div className="mb-8">
        <h1 className="font-display text-3xl font-bold text-neutral-950">Assigned seating</h1>
        <p className="mt-1 text-neutral-600">{event?.title} · reusable layouts, accessible inventory, and live seat controls</p>
      </div>
      {error && <p className="mb-6 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700" role="alert">{error}</p>}

      {!seating?.assigned_seating ? (
        <div className="grid gap-6 lg:grid-cols-2">
          <section className="card p-6">
            <h2 className="text-lg font-semibold text-neutral-900">Create a pilot layout</h2>
            <p className="mt-1 text-sm text-neutral-600">Generate a clean section-and-row map. Arena-grade diagrams can use the provider adapter later.</p>
            <div className="mt-5 space-y-4">
              <label className="block text-sm font-medium text-neutral-700">Layout name<input className="input mt-1" value={layoutName} onChange={eventValue => setLayoutName(eventValue.target.value)} /></label>
              <div className="grid grid-cols-3 gap-3">
                <label className="text-sm font-medium text-neutral-700">Rows<input className="input mt-1" type="number" min="1" max="50" value={rowCount} onChange={eventValue => setRowCount(eventValue.target.value)} /></label>
                <label className="text-sm font-medium text-neutral-700">Seats / row<input className="input mt-1" type="number" min="2" max="100" value={seatsPerRow} onChange={eventValue => setSeatsPerRow(eventValue.target.value)} /></label>
                <label className="text-sm font-medium text-neutral-700">Accessible pairs<input className="input mt-1" type="number" min="0" max="3" value={accessiblePairs} onChange={eventValue => setAccessiblePairs(eventValue.target.value)} /></label>
              </div>
              <button className="btn-secondary w-full" disabled={saving} onClick={createSimpleLayout}>Create reusable layout</button>
            </div>
          </section>

          <section className="card p-6">
            <h2 className="text-lg font-semibold text-neutral-900">Activate for this event</h2>
            <label className="mt-5 block text-sm font-medium text-neutral-700">Published venue layout
              <select className="input mt-1" value={selectedLayoutId} onChange={eventValue => setSelectedLayoutId(eventValue.target.value)}>
                <option value="">Choose a layout</option>
                {layouts.filter(layout => layout.status === 'published').map(layout => <option key={layout.id} value={layout.id}>{layout.name} · {layout.seat_count} seats</option>)}
              </select>
            </label>
            {selectedLayout?.price_zones?.map(zone => (
              <label key={zone.id} className="mt-4 block text-sm font-medium text-neutral-700">{zone.name} ticket type
                <select className="input mt-1" value={zoneMappings[zone.id] || ''} onChange={eventValue => setZoneMappings(current => ({ ...current, [zone.id]: Number(eventValue.target.value) }))}>
                  <option value="">Choose a ticket type</option>
                  {event?.ticket_types?.map(ticketType => <option key={ticketType.id} value={ticketType.id}>{ticketType.name} · ${(ticketType.price_cents / 100).toFixed(2)}</option>)}
                </select>
              </label>
            ))}
            <button className="btn-primary mt-5 w-full" disabled={saving || !selectedLayoutId || Object.values(zoneMappings).some(value => !value)} onClick={activateLayout}>Activate assigned seating</button>
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
              {seating.suspended ? <button className="btn-primary mt-3 flex w-full items-center justify-center gap-2" disabled={saving} onClick={() => operation('resume')}><PlayCircle className="h-4 w-4" />Resume sales</button>
                : <button className="mt-3 flex w-full items-center justify-center gap-2 rounded-xl border border-amber-300 bg-amber-50 px-4 py-2.5 font-semibold text-amber-900" disabled={saving || !reason.trim()} onClick={() => operation('suspend', { reason })}><PauseCircle className="h-4 w-4" />Pause all sales</button>}
            </section>
            <section className="card p-5">
              <h2 className="font-semibold text-neutral-900">Selected seats</h2>
              <p className="mt-1 text-sm text-neutral-600">{selectedSeatIds.length} selected. Sold and actively held seats cannot be blocked.</p>
              <div className="mt-3 grid grid-cols-2 gap-2">
                {['available', 'blocked', 'house_hold'].map(status => <button key={status} className="btn-secondary !px-2 !py-2 text-xs" disabled={saving || !reason.trim() || selectedSeatIds.length === 0} onClick={() => operation('update_seat_statuses', { event_seat_ids: selectedSeatIds, operational_status: status, reason })}>{status.replace('_', ' ')}</button>)}
              </div>
              <button className="mt-3 flex w-full items-center justify-center gap-2 rounded-xl border border-blue-200 bg-blue-50 px-3 py-2 text-sm font-semibold text-blue-900" disabled={saving || !reason.trim() || selectedSeatIds.length === 0} onClick={() => operation('release_accessible', { event_seat_ids: selectedSeatIds, reason })}><Accessibility className="h-4 w-4" />Controlled accessible release</button>
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

      <div className="mt-8 rounded-2xl border border-amber-200 bg-amber-50 p-5 text-sm text-amber-950">
        <p className="flex items-center gap-2 font-semibold"><AlertTriangle className="h-4 w-4" />Accessibility and provider boundary</p>
        <p className="mt-1">Do not ask buyers for medical documentation. This native map remains the accessible purchasing path even when a visual chart provider is enabled.</p>
      </div>
    </div>
  )
}
