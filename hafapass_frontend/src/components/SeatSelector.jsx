import { useEffect, useMemo, useState } from 'react'
import { Accessibility, EyeOff, Loader2 } from 'lucide-react'
import apiClient from '../api/client'

const money = (cents) => cents === 0 ? 'Free' : `$${(cents / 100).toFixed(2)}`

export default function SeatSelector({ event, onReserved, source = 'online', reserveLabel = 'Reserve selected seats' }) {
  const [map, setMap] = useState(null)
  const [selectedIds, setSelectedIds] = useState([])
  const [attested, setAttested] = useState(false)
  const [loading, setLoading] = useState(true)
  const [reserving, setReserving] = useState(false)
  const [error, setError] = useState(null)

  useEffect(() => {
    let active = true
    setLoading(true)
    apiClient.get(`/events/${event.slug}/seating`)
      .then(response => { if (active) { setMap(response.data); setLoading(false) } })
      .catch(err => {
        if (active) {
          setError(err.response?.data?.error || 'Unable to load the seat map.')
          setLoading(false)
        }
      })
    return () => { active = false }
  }, [event.slug])

  const seats = useMemo(() => map?.sections.flatMap(section =>
    section.rows.flatMap(row => row.seats.map(seat => ({ ...seat, section: section.name, row: row.label })))
  ) || [], [map])
  const selected = seats.filter(seat => selectedIds.includes(seat.id))
  const totalCents = selected.reduce((sum, seat) => sum + seat.price_cents, 0)
  const requiresAttestation = selected.some(seat => seat.requires_accessibility_attestation)

  const toggleSeat = (seat) => {
    if (seat.status !== 'available') return
    setError(null)
    setSelectedIds(current => current.includes(seat.id)
      ? current.filter(id => id !== seat.id)
      : [...current, seat.id])
  }

  const reserve = async () => {
    if (selected.length === 0 || (requiresAttestation && !attested)) return
    setReserving(true)
    setError(null)
    try {
      const response = await apiClient.post(`/events/${event.slug}/seat_holds`, {
        event_seat_ids: selected.map(seat => seat.id),
        accessibility_attested: attested,
        source,
      })
      const grouped = selected.reduce((lines, seat) => {
        lines[seat.ticket_type_id] = (lines[seat.ticket_type_id] || 0) + 1
        return lines
      }, {})
      onReserved({
        lineItems: Object.entries(grouped).map(([ticketTypeId, quantity]) => ({
          ticket_type_id: Number(ticketTypeId), quantity,
        })),
        seatHoldToken: response.data.token,
        seatHoldExpiresAt: response.data.expires_at,
        seats: selected,
      })
    } catch (err) {
      setError(err.response?.data?.error || 'Those seats could not be reserved. Refresh the map and try again.')
    } finally {
      setReserving(false)
    }
  }

  if (loading) return <div className="flex justify-center py-8"><Loader2 className="h-6 w-6 animate-spin text-brand-600" aria-label="Loading seat map" /></div>
  if (error && !map) return <p className="rounded-xl bg-red-50 p-4 text-sm text-red-700" role="alert">{error}</p>

  return (
    <div>
      <div className="mb-4">
        <h2 className="text-lg font-semibold text-neutral-900">Choose your seats</h2>
        <p className="mt-1 text-sm text-neutral-600">Every seat is available through the same keyboard-friendly list and row map.</p>
      </div>

      {map?.suspended && (
        <p className="mb-4 rounded-xl border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900" role="status">
          Sales are temporarily paused. {map.suspension_reason}
        </p>
      )}

      <div className="mb-4 flex flex-wrap gap-3 text-xs text-neutral-600" aria-label="Seat map legend">
        <span><span className="mr-1 inline-block h-3 w-3 rounded-full border border-brand-500 bg-white" />Available</span>
        <span><span className="mr-1 inline-block h-3 w-3 rounded-full bg-brand-600" />Selected</span>
        <span><span className="mr-1 inline-block h-3 w-3 rounded-full bg-neutral-300" />Unavailable</span>
        <span className="inline-flex items-center gap-1"><Accessibility className="h-3.5 w-3.5" />Accessible</span>
      </div>

      <div className="max-h-[32rem] space-y-6 overflow-auto rounded-2xl border border-neutral-200 bg-neutral-50 p-4">
        {map?.sections.map(section => (
          <section key={section.id} aria-labelledby={`seat-section-${section.id}`}>
            <h3 id={`seat-section-${section.id}`} className="mb-3 text-center text-sm font-semibold uppercase tracking-wide text-neutral-700">
              {section.name}
            </h3>
            <div className="space-y-3">
              {section.rows.map(row => (
                <div key={row.id} className="flex items-center gap-3">
                  <span className="w-8 shrink-0 text-center text-xs font-semibold text-neutral-500" aria-hidden="true">{row.label}</span>
                  <div className="flex flex-wrap gap-2" role="group" aria-label={`${section.name}, row ${row.label}`}>
                    {row.seats.map(seat => {
                      const isSelected = selectedIds.includes(seat.id)
                      const unavailable = seat.status !== 'available' || map.suspended
                      const accessible = seat.accessibility_kind !== 'standard'
                      const description = [
                        `${section.name}, row ${row.label}, seat ${seat.label}`,
                        seat.ticket_type_name,
                        money(seat.price_cents),
                        accessible ? seat.accessibility_kind.replace('_', ' ') : null,
                        seat.obstructed_view ? `obstructed view${seat.view_note ? `: ${seat.view_note}` : ''}` : null,
                        unavailable ? seat.status : 'available',
                      ].filter(Boolean).join(', ')
                      return (
                        <button
                          key={seat.id}
                          type="button"
                          onClick={() => toggleSeat(seat)}
                          disabled={unavailable}
                          aria-label={description}
                          aria-pressed={isSelected}
                          title={description}
                          className={`relative flex h-11 min-w-11 items-center justify-center rounded-full border px-3 text-xs font-semibold transition focus:outline-none focus:ring-2 focus:ring-brand-500 focus:ring-offset-2 ${
                            isSelected
                              ? 'border-brand-700 bg-brand-700 text-white'
                              : unavailable
                                ? 'cursor-not-allowed border-neutral-300 bg-neutral-300 text-neutral-600'
                                : 'border-brand-500 bg-white text-brand-800 hover:bg-brand-50'
                          }`}
                        >
                          {seat.label}
                          {accessible && <Accessibility className="absolute -right-1 -top-1 h-3.5 w-3.5 rounded-full bg-white text-blue-700" aria-hidden="true" />}
                          {seat.obstructed_view && <EyeOff className="absolute -bottom-1 -right-1 h-3.5 w-3.5 rounded-full bg-white text-amber-700" aria-hidden="true" />}
                        </button>
                      )
                    })}
                  </div>
                </div>
              ))}
            </div>
          </section>
        ))}
      </div>

      {selected.length > 0 && (
        <div className="mt-4 rounded-xl border border-neutral-200 bg-white p-4" aria-live="polite">
          <div className="flex items-start justify-between gap-4">
            <div>
              <p className="font-semibold text-neutral-900">{selected.length} seat{selected.length === 1 ? '' : 's'} selected</p>
              <ul className="mt-1 text-sm text-neutral-600">
                {selected.map(seat => <li key={seat.id}>{seat.display_label} · {money(seat.price_cents)}</li>)}
              </ul>
            </div>
            <p className="font-semibold text-neutral-900">{money(totalCents)}</p>
          </div>
          {requiresAttestation && (
            <label className="mt-4 flex items-start gap-3 rounded-xl bg-blue-50 p-3 text-sm text-blue-950">
              <input type="checkbox" checked={attested} onChange={event => setAttested(event.target.checked)} className="mt-1 h-4 w-4" />
              <span>I attest that an accessible seating location is needed for this party. No medical proof is required.</span>
            </label>
          )}
          {error && <p className="mt-3 text-sm text-red-700" role="alert">{error}</p>}
          <button
            type="button"
            onClick={reserve}
            disabled={reserving || map?.suspended || (requiresAttestation && !attested)}
            className="btn-primary mt-4 w-full disabled:cursor-not-allowed disabled:opacity-50"
          >
            {reserving ? 'Reserving seats…' : reserveLabel}
          </button>
          <p className="mt-2 text-center text-xs text-neutral-500">Seats are held for {Math.round((map?.hold_duration_seconds || 600) / 60)} minutes after reservation.</p>
        </div>
      )}
      {error && selected.length === 0 && <p className="mt-3 text-sm text-red-700" role="alert">{error}</p>}
    </div>
  )
}
