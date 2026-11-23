import { useState, useRef, useCallback, useEffect, useLayoutEffect } from 'react'
import { Plus, Pencil, Trash2, ChevronDown, Loader2, RefreshCw, Sparkles, Lock } from 'lucide-react'
import apiClient from '../api/client'
import { useLocation } from 'react-router-dom'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../hooks/useOrganizerContext'
import SupportLink from './SupportLink'
import PricingTiersCRUD from './PricingTiersCRUD'
import DoorScannerSettings from './admissions/DoorScannerSettings'
import { compareLocalDateTimes, DEFAULT_EVENT_TIME_ZONE, formatEventDate, formatEventDateTime, toEventLocalInput } from '../utils/eventTime'

const readPendingInventory = key => {
  try {
    const raw = window.sessionStorage.getItem(key)
    if (raw === null) return null
    const value = JSON.parse(raw)
    return value && typeof value.operation === 'string' ? value : { operation: 'unverified inventory change' }
  } catch { return { operation: 'unverified inventory change' } }
}
const uncertainInventoryResponse = error => !error.response || error.response.status >= 500
  || [408, 409, 429].includes(error.response.status) || error.response.data?.reconciliation_required === true

function useInventoryRequests(identity, resourcePath, parentBeginRequest) {
  const { current, beginRequest: fallbackBeginRequest } = useOrganizerRequests(identity, resourcePath)
  const requests = useRef(new Set())
  useLayoutEffect(() => {
    const owned = requests.current
    return () => { owned.forEach(controller => controller.abort()); owned.clear() }
  }, [])
  const beginRequest = useCallback(() => {
    if (!current()) return null
    const request = (parentBeginRequest || fallbackBeginRequest)()
    if (!request) return null
    requests.current.add(request.controller)
    return { ...request, current: () => current() && request.current(), release: () => {
      requests.current.delete(request.controller); request.release()
    } }
  }, [current, fallbackBeginRequest, parentBeginRequest])
  return { current, beginRequest }
}

// Plain-English choices for what checkout asks about each ticket's attendee.
const ATTENDEE_INFO_OPTIONS = [
  ['none', 'None — buyer name only'],
  ['name_only', "Ask for each attendee's name"],
  ['name_and_email', "Ask for each attendee's name and email"],
]
const EMPTY_FORM = { name: '', description: '', price: '0.00', quantity_available: '', door_allocation: '', max_per_order: '', max_per_buyer: '', attendee_info_mode: 'none', sales_start_at: '', sales_end_at: '',
  door_check_mode: 'instant', door_alert_label: '', door_instructions: '', scanner_show_buyer: false }

function TicketTypeForm({
  initial,
  editingTicketType = null,
  eventId,
  assignedSeating = false,
  beginRequest,
  onSave,
  onCancel,
  saving,
  eventTimezone,
  defaultQuantity,
  scannerQuestions,
}) {
  const [form, setForm] = useState(() => initial || { ...EMPTY_FORM, quantity_available: Number.isInteger(defaultQuantity) && defaultQuantity > 0 ? String(defaultQuantity) : '' })
  const wasPass = Boolean(editingTicketType?.is_pass)
  const hasSales = Number(editingTicketType?.quantity_sold || 0) > 0
  const lockedEventIds = wasPass && hasSales
    ? new Set((editingTicketType?.included_event_ids || []).map(Number))
    : new Set()
  const [isPass, setIsPass] = useState(wasPass)
  const [selectedEventIds, setSelectedEventIds] = useState(() => (editingTicketType?.included_event_ids || []).map(Number))
  const [eligibleEvents, setEligibleEvents] = useState(() => editingTicketType?.included_events || [])
  const [seriesList, setSeriesList] = useState([])
  const [selectedSeriesId, setSelectedSeriesId] = useState('')
  const [loadingOptions, setLoadingOptions] = useState(false)
  const [optionsError, setOptionsError] = useState(null)
  const [eventsTruncated, setEventsTruncated] = useState(false)
  const optionsLoadedRef = useRef(false)
  const [error, setError] = useState(null)

  const cannotConvertSoldNonPass = Boolean(editingTicketType && !wasPass && hasSales)
  const cannotDisableSoldPass = Boolean(wasPass && hasSales)
  const passCheckboxDisabled = saving || assignedSeating || cannotConvertSoldNonPass || cannotDisableSoldPass

  useEffect(() => {
    if (!isPass || assignedSeating || optionsLoadedRef.current) return undefined
    let active = true
    const request = beginRequest?.()
    const config = request?.config || {}
    setLoadingOptions(true)
    setOptionsError(null)
    Promise.all([
      apiClient.get('/organizer/events', { ...config, params: { per_page: 100, order: 'starts_at' } }),
      apiClient.get('/organizer/event_series', config).catch(() => ({ data: { event_series: [] } })),
    ])
      .then(([eventsRes, seriesRes]) => {
        if (!active || (request && !request.current())) return
        const currentId = Number(eventId)
        const lockedIds = new Set((editingTicketType?.included_event_ids || []).map(Number))
        const rawEvents = eventsRes.data?.events || []
        const headerTotal = Number(eventsRes.headers?.['x-total-count'] ?? eventsRes.headers?.['X-Total-Count'])
        const metaTotal = Number(eventsRes.data?.meta?.total_count ?? eventsRes.data?.meta?.total)
        const totalEvents = Number.isFinite(headerTotal) && headerTotal > 0
          ? headerTotal
          : (Number.isFinite(metaTotal) && metaTotal > 0 ? metaTotal : rawEvents.length)
        const fetched = rawEvents.filter(ev => {
          const evId = Number(ev.id)
          if (evId === currentId) return false
          if (lockedIds.has(evId)) return true
          if (ev.assigned_seating) return false
          if ((ev.ticket_types || []).some(t => t.is_pass)) return false
          if (['archived', 'cancelled'].includes(ev.status)) return false
          if (ev.permissions && ev.permissions.manage_inventory === false) return false
          return true
        })
        const byId = new Map(fetched.map(ev => [Number(ev.id), ev]))
        ;(editingTicketType?.included_events || []).forEach(ev => {
          const evId = Number(ev.id)
          if (evId !== currentId && !byId.has(evId)) byId.set(evId, ev)
        })
        const merged = Array.from(byId.values()).sort((a, b) => {
          const aTime = a.starts_at ? new Date(a.starts_at).getTime() : Number.MAX_SAFE_INTEGER
          const bTime = b.starts_at ? new Date(b.starts_at).getTime() : Number.MAX_SAFE_INTEGER
          if (aTime !== bTime) return aTime - bTime
          return Number(a.id) - Number(b.id)
        })
        optionsLoadedRef.current = true
        setEventsTruncated(totalEvents > rawEvents.length)
        setEligibleEvents(merged)
        setSeriesList(seriesRes.data?.event_series || [])
        setLoadingOptions(false)
      })
      .catch(() => {
        if (!active || (request && !request.current())) return
        setOptionsError('Could not load eligible events for this pass. Try again before saving.')
        setLoadingOptions(false)
      })
      .finally(() => {
        request?.release()
      })
    return () => {
      active = false
      request?.controller?.abort()
    }
  }, [isPass, assignedSeating, beginRequest, eventId, editingTicketType])

  const toggleIncludedEvent = (targetId) => {
    const numId = Number(targetId)
    if (lockedEventIds.has(numId)) return
    setSelectedEventIds(prev => (prev.includes(numId) ? prev.filter(id => id !== numId) : [...prev, numId]))
  }

  const eligibleIdSet = new Set(eligibleEvents.map(ev => Number(ev.id)))
  const availableSeries = seriesList
    .map(series => {
      const matchingIds = (series.events || [])
        .map(ev => Number(ev.event_id ?? ev.id))
        .filter(id => id !== Number(eventId) && eligibleIdSet.has(id))
      return { ...series, matchingIds }
    })
    .filter(series => series.matchingIds.length > 0)

  const handleAddSeriesNights = () => {
    if (!selectedSeriesId) return
    const series = availableSeries.find(item => String(item.id) === String(selectedSeriesId))
    if (!series) return
    setSelectedEventIds(prev => {
      const merged = new Set(prev)
      series.matchingIds.forEach(id => merged.add(id))
      return Array.from(merged)
    })
  }

  const handleSubmit = (e) => {
    e.preventDefault()
    const invalid = (message, field) => {
      setError(message)
      const input = document.getElementById(field)
      const options = input?.closest('details')
      if (options) options.open = true
      input?.focus()
    }
    if (!form.name.trim()) { invalid('Give this ticket type a name.', 'ticket-type-name'); return }
    const quantity = Number(form.quantity_available)
    if (!form.quantity_available.trim() || !Number.isSafeInteger(quantity) || quantity <= 0) {
      invalid('Enter a positive whole number of tickets available.', 'ticket-type-quantity')
      return
    }
    const price = Number(form.price)
    if (!form.price.trim() || !Number.isFinite(price) || price < 0 || !/^\d+(?:\.\d{1,2})?$/.test(form.price)) {
      invalid('Enter a price in dollars and cents, or 0 for free tickets.', 'ticket-type-price')
      return
    }
    for (const [field, label] of [['door_allocation', 'Door allocation'], ['max_per_order', 'Tickets per order'], ['max_per_buyer', 'Tickets per buyer']]) {
      const value = form[field]
      const number = Number(value)
      if (value !== '' && (!Number.isSafeInteger(number) || number < (field === 'door_allocation' ? 0 : 1))) {
        invalid(`${label} must be a ${field === 'door_allocation' ? 'non-negative' : 'positive'} whole number.`, `ticket-type-${field === 'door_allocation' ? 'door-allocation' : field === 'max_per_order' ? 'max-order' : 'max-buyer'}`)
        return
      }
    }
    const salesStartChanged = !editingTicketType || form.sales_start_at !== (initial?.sales_start_at || '')
    const salesEndChanged = !editingTicketType || form.sales_end_at !== (initial?.sales_end_at || '')
    if ((salesStartChanged || salesEndChanged) && form.sales_start_at && form.sales_end_at && compareLocalDateTimes(form.sales_end_at, form.sales_start_at) <= 0) {
      invalid('Sales end must be after sales start.', 'ticket-type-sales-end')
      return
    }
    if (isPass && selectedEventIds.length === 0) {
      invalid('Select at least one included event for this multi-night pass.', 'ticket-type-is-pass')
      return
    }
    setError(null)
    const payload = {
      name: form.name.trim(),
      description: form.description.trim() || null,
      price_cents: Math.round(price * 100),
      quantity_available: quantity,
      door_allocation: form.door_allocation === '' ? null : parseInt(form.door_allocation, 10),
      max_per_order: form.max_per_order ? parseInt(form.max_per_order, 10) : null,
      max_per_buyer: form.max_per_buyer ? parseInt(form.max_per_buyer, 10) : null,
      attendee_info_mode: form.attendee_info_mode || 'none',
      door_check_mode: form.door_check_mode,
      door_alert_label: form.door_alert_label.trim() || null,
      door_instructions: form.door_instructions.trim() || null,
      scanner_show_buyer: form.scanner_show_buyer,
      sales_start_at: salesStartChanged ? (form.sales_start_at || null) : (editingTicketType.sales_start_at || null),
      sales_end_at: salesEndChanged ? (form.sales_end_at || null) : (editingTicketType.sales_end_at || null)
    }
    if (isPass) {
      const orderedIds = [
        ...eligibleEvents.map(ev => Number(ev.id)).filter(id => selectedEventIds.includes(id)),
        ...selectedEventIds.filter(id => !eligibleIdSet.has(id)),
      ]
      payload.included_event_ids = orderedIds
    } else if (wasPass) {
      payload.included_event_ids = []
    }
    onSave(payload)
  }

  return (
    <form onSubmit={handleSubmit} noValidate className="p-4 bg-neutral-50 rounded-xl border border-neutral-200 space-y-3">
      {error && <p role="alert" className="text-sm text-red-600">{error}</p>}
      <div>
        <label htmlFor="ticket-type-name" className="block text-sm font-medium text-neutral-700 mb-1">Name <span aria-hidden="true" className="text-red-500">*</span></label>
        <input id="ticket-type-name" required value={form.name} onChange={e => setForm(f => ({...f, name: e.target.value}))} className="input" placeholder="e.g. General Admission" disabled={saving} />
      </div>
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div>
          <label htmlFor="ticket-type-price" className="block text-sm font-medium text-neutral-700 mb-1">Price ($) <span aria-hidden="true" className="text-red-500">*</span></label>
          <input id="ticket-type-price" type="number" step="0.01" min="0" required value={form.price} onChange={e => setForm(f => ({ ...f, price: e.target.value }))} className="input" placeholder="0.00" aria-describedby="ticket-type-price-help" disabled={saving} />
          <p id="ticket-type-price-help" className="mt-1 text-xs text-neutral-500">Enter 0 for free tickets.</p>
        </div>
        <div>
          <label htmlFor="ticket-type-quantity" className="block text-sm font-medium text-neutral-700 mb-1">Tickets available <span aria-hidden="true" className="text-red-500">*</span></label>
          <input id="ticket-type-quantity" type="number" min="1" step="1" required value={form.quantity_available} onChange={e => setForm(f => ({ ...f, quantity_available: e.target.value }))} className="input" placeholder="e.g. 30" aria-describedby="ticket-type-quantity-help" disabled={saving} />
          <p id="ticket-type-quantity-help" className="mt-1 text-xs text-neutral-500">Total tickets for this type, including any already sold.{!initial && defaultQuantity != null && ` ${Math.max(0, defaultQuantity)} places remain in the event capacity.`}</p>
        </div>
      </div>

      {/* Multi-Night Pass Builder */}
      <div className="rounded-xl border border-neutral-200 bg-white p-3.5 space-y-3">
        <div className="flex items-start gap-2.5">
          <input
            id="ticket-type-is-pass"
            type="checkbox"
            checked={isPass}
            disabled={passCheckboxDisabled}
            onChange={e => setIsPass(e.target.checked)}
            className="mt-0.5 h-4 w-4 rounded border-neutral-300 text-brand-700 focus:ring-brand-500 disabled:opacity-50"
          />
          <div className="min-w-0 flex-1">
            <label htmlFor="ticket-type-is-pass" className="block text-sm font-semibold text-neutral-900 cursor-pointer">
              This ticket is a multi-night pass (grants entry to multiple events)
            </label>
            {assignedSeating && (
              <p className="mt-1 text-xs text-neutral-600">
                Multi-night passes are available for general admission events only.
              </p>
            )}
            {!assignedSeating && cannotConvertSoldNonPass && (
              <p className="mt-1 text-xs text-amber-800">
                Ticket types with existing sales cannot be converted into a multi-night pass.
              </p>
            )}
            {!assignedSeating && cannotDisableSoldPass && (
              <p className="mt-1 text-xs text-neutral-600">
                Existing included nights are locked because passes have been sold. You can still add new nights and sync pass holders.
              </p>
            )}
          </div>
        </div>

        {isPass && !assignedSeating && (
          <div className="space-y-3 border-t border-neutral-100 pt-3">
            {availableSeries.length > 0 && (
              <div className="flex flex-col gap-2 sm:flex-row sm:items-end">
                <div className="flex-1 min-w-0">
                  <label htmlFor="pass-series-quick-select" className="block text-xs font-medium text-neutral-700 mb-1">
                    Add all nights from series...
                  </label>
                  <select
                    id="pass-series-quick-select"
                    value={selectedSeriesId}
                    onChange={e => setSelectedSeriesId(e.target.value)}
                    disabled={saving || loadingOptions}
                    className="input text-sm"
                  >
                    <option value="">Choose a series</option>
                    {availableSeries.map(series => (
                      <option key={series.id} value={series.id}>
                        {series.name} ({series.matchingIds.length} {series.matchingIds.length === 1 ? 'night' : 'nights'})
                      </option>
                    ))}
                  </select>
                </div>
                <button
                  type="button"
                  disabled={!selectedSeriesId || saving || loadingOptions}
                  onClick={handleAddSeriesNights}
                  className="btn-secondary min-h-11 shrink-0 text-sm px-3"
                >
                  Add series nights
                </button>
              </div>
            )}

            {loadingOptions && (
              <p role="status" className="flex items-center gap-2 text-xs text-neutral-600">
                <Loader2 aria-hidden="true" className="h-3.5 w-3.5 animate-spin" />
                Loading eligible events…
              </p>
            )}
            {optionsError && (
              <p role="alert" className="text-xs text-red-700">{optionsError}</p>
            )}
            {!loadingOptions && eligibleEvents.length === 0 && !optionsError && (
              <p className="text-xs text-neutral-600">
                No other eligible general admission events found in this organization.
              </p>
            )}
            {eligibleEvents.length > 0 && (
              <fieldset className="space-y-1.5">
                <legend className="text-xs font-medium text-neutral-700 mb-1">
                  Included nights ({selectedEventIds.length} selected)
                </legend>
                <div className="max-h-56 overflow-y-auto divide-y divide-neutral-100 rounded-lg border border-neutral-200 bg-neutral-50/50 px-3">
                  {eligibleEvents.map(ev => {
                    const evId = Number(ev.id)
                    const checked = selectedEventIds.includes(evId)
                    const isLocked = lockedEventIds.has(evId)
                    return (
                      <label
                        key={ev.id}
                        className={`flex items-center justify-between gap-3 py-2 text-sm ${isLocked ? 'cursor-not-allowed opacity-85' : 'cursor-pointer'}`}
                      >
                        <span className="flex min-w-0 items-center gap-2.5">
                          <input
                            type="checkbox"
                            checked={checked}
                            disabled={saving || isLocked}
                            onChange={() => toggleIncludedEvent(evId)}
                            className="h-4 w-4 shrink-0 rounded border-neutral-300 text-brand-700 focus:ring-brand-500"
                          />
                          <span className="min-w-0">
                            <span className="block font-medium text-neutral-900 [overflow-wrap:anywhere]">{ev.title}</span>
                            {ev.starts_at && (
                              <span className="block text-xs text-neutral-500">
                                {formatEventDate(ev.starts_at, ev.timezone || eventTimezone || DEFAULT_EVENT_TIME_ZONE, { weekday: 'short' })}
                              </span>
                            )}
                          </span>
                        </span>
                        <span className="flex shrink-0 items-center gap-1.5">
                          {ev.status && ev.status !== 'published' && (
                            <span className="rounded-full bg-neutral-100 px-2 py-0.5 text-xs capitalize text-neutral-700">{ev.status}</span>
                          )}
                          {isLocked && (
                            <span className="inline-flex items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-900">
                              <Lock aria-hidden="true" className="h-3 w-3" />
                              Locked
                            </span>
                          )}
                        </span>
                      </label>
                    )
                  })}
                </div>
                {eventsTruncated && (
                  <p className="text-xs text-neutral-500">
                    Showing first 100 events — use a series or search if your event isn&apos;t listed.
                  </p>
                )}
              </fieldset>
            )}
          </div>
        )}
      </div>

      <details className="group rounded-xl border border-neutral-200 bg-white px-3">
        <summary className="flex min-h-11 cursor-pointer items-center text-sm font-semibold text-neutral-700">More ticket options<ChevronDown aria-hidden="true" className="ml-auto h-4 w-4 group-open:rotate-180" /></summary>
        <div className="space-y-4 pb-4 pt-2">
          <div>
            <label htmlFor="ticket-type-description" className="block text-sm font-medium text-neutral-700 mb-1">Description</label>
            <input id="ticket-type-description" value={form.description} onChange={e => setForm(f => ({ ...f, description: e.target.value }))} className="input" placeholder="Optional description" disabled={saving} />
          </div>
          <div>
            <label htmlFor="ticket-type-attendee-info" className="block text-sm font-medium text-neutral-700 mb-1">Attendee info at checkout</label>
            <select id="ticket-type-attendee-info" aria-describedby="ticket-type-attendee-info-help" value={form.attendee_info_mode || 'none'} onChange={e => setForm(f => ({ ...f, attendee_info_mode: e.target.value }))} className="input" disabled={saving}>
              {ATTENDEE_INFO_OPTIONS.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
            </select>
            <p id="ticket-type-attendee-info-help" className="mt-1 text-xs text-neutral-500">Asking for names prints each attendee&apos;s name on their own ticket, so door staff can see who each ticket is for.</p>
          </div>
          <div>
            <label htmlFor="ticket-type-door-allocation" className="block text-sm font-medium text-neutral-700 mb-1">Door allocation</label>
            <input id="ticket-type-door-allocation" type="number" min="0" step="1" value={form.door_allocation} onChange={e => setForm(f => ({ ...f, door_allocation: e.target.value }))} className="input" placeholder="No separate cap" disabled={saving} />
            <p className="mt-1 text-xs text-neutral-500">Optional cap for sales at the venue. Leave blank to use the remaining ticket inventory.</p>
          </div>
          <div>
            <p className="text-xs text-neutral-500 mb-2">Optional sales dates in {eventTimezone || 'Pacific/Guam'}.</p>
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <div>
                <label htmlFor="ticket-type-sales-start" className="block text-sm font-medium text-neutral-700 mb-1">Sales start</label>
                <input id="ticket-type-sales-start" type="datetime-local" value={form.sales_start_at} onChange={e => setForm(current => ({ ...current, sales_start_at: e.target.value }))} className="input" disabled={saving} />
              </div>
              <div>
                <label htmlFor="ticket-type-sales-end" className="block text-sm font-medium text-neutral-700 mb-1">Sales end</label>
                <input id="ticket-type-sales-end" type="datetime-local" value={form.sales_end_at} onChange={e => setForm(current => ({ ...current, sales_end_at: e.target.value }))} className="input" disabled={saving} />
              </div>
            </div>
          </div>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <label htmlFor="ticket-type-max-order" className="block text-sm font-medium text-neutral-700 mb-1">Tickets per order</label>
              <input id="ticket-type-max-order" type="number" min="1" step="1" value={form.max_per_order} onChange={e => setForm(f => ({ ...f, max_per_order: e.target.value }))} className="input" placeholder="10 for online checkout if blank" disabled={saving} />
            </div>
            <div>
              <label htmlFor="ticket-type-max-buyer" className="block text-sm font-medium text-neutral-700 mb-1">Tickets per buyer</label>
              <input id="ticket-type-max-buyer" type="number" min="1" step="1" value={form.max_per_buyer} onChange={e => setForm(f => ({ ...f, max_per_buyer: e.target.value }))} className="input" placeholder="Leave blank for unlimited" aria-describedby="ticket-type-max-buyer-help" disabled={saving} />
              <p id="ticket-type-max-buyer-help" className="mt-1 text-xs text-neutral-500">Leave blank for unlimited.</p>
            </div>
          </div>
          <p className="text-xs text-neutral-500">Blank purchase limits add no separate cap; event capacity and remaining ticket inventory still apply.</p>
        </div>
      </details>
      <DoorScannerSettings form={form} setForm={setForm} ticketTypeId={editingTicketType?.id} questions={scannerQuestions} saving={saving} />
      <div className="flex gap-2 justify-end">
        <button type="button" onClick={onCancel} disabled={saving} className="min-h-12 px-3 py-1.5 text-base text-neutral-700 hover:text-neutral-900">Cancel</button>
        <button type="submit" disabled={saving} className="btn-primary min-h-12 text-base px-4 py-1.5">
          {saving ? 'Saving...' : initial ? 'Update' : 'Add ticket type'}
        </button>
      </div>
    </form>
  )
}

function TicketTypesSession({ eventId, ticketTypes = [], scannerQuestions = [], onRefresh, remainingCapacity, eventTimezone = 'Pacific/Guam', assignedSeating = false, beginRequest: parentBeginRequest, identity, resourcePath }) {
  const { current, beginRequest } = useInventoryRequests(identity, resourcePath, parentBeginRequest)
  const busy = useRef(false)
  const storageKey = `hafapass:pending-ticket-types:${identity.owner}:${identity.organizationId}:${eventId}`
  const [unconfirmed, setUnconfirmed] = useState(() => readPendingInventory(storageKey))
  const [showForm, setShowForm] = useState(false)
  const [editingId, setEditingId] = useState(null)
  const [saving, setSaving] = useState(false)
  const [deletingId, setDeletingId] = useState(null)
  const [confirmDeleteId, setConfirmDeleteId] = useState(null)
  const [confirmSyncId, setConfirmSyncId] = useState(null)
  const [syncingId, setSyncingId] = useState(null)
  const [syncNotice, setSyncNotice] = useState(null)
  const [expandedPassIds, setExpandedPassIds] = useState({})
  const [error, setError] = useState(null)

  const locked = saving || deletingId !== null || syncingId !== null || Boolean(unconfirmed)
  const mutate = async (operation, send, onSuccess) => {
    if (!current() || busy.current || unconfirmed) return
    const request = beginRequest()
    if (!request) return
    busy.current = true
    setError(null)
    setSyncNotice(null)
    if (operation === 'delete') setDeletingId(confirmDeleteId)
    else setSaving(true)
    let confirmed = false
    let sent = false
    try {
      window.sessionStorage.setItem(storageKey, JSON.stringify({ operation }))
      sent = true
      await send(request.config)
      if (!request.current()) return
      confirmed = true
      onSuccess()
      window.sessionStorage.removeItem(storageKey)
      if (request.current()) await onRefresh?.()
    } catch (error) {
      if (!request.current()) return
      if (!sent) {
        setError('This browser could not retain the pending request. No change was sent. Allow browser storage before trying again.')
      } else if (!confirmed && uncertainInventoryResponse(error)) {
        setUnconfirmed({ operation })
        setError('The ticket change may have completed. Do not repeat it; refresh the ticket list and ask support to verify the result.')
      } else if (confirmed) {
        setError('The ticket change was saved, but the latest list could not be refreshed. Check the ticket list before making another change.')
      } else {
        window.sessionStorage.removeItem(storageKey)
        setError(error.response?.data?.errors?.join(', ') || error.response?.data?.error || 'The ticket change was rejected. Your draft is still here.')
      }
    } finally {
      request.release()
      if (request.current()) { busy.current = false; setSaving(false); setDeletingId(null) }
    }
  }
  const refreshList = async () => {
    if (!current()) return
    try { await onRefresh?.() }
    catch { if (current()) setError('The ticket list could not be refreshed. Reconnect and try again; no ticket change was sent.') }
  }
  const handleCreate = data => {
    const payload = { ...data }
    mutate('create', config => apiClient.post(`/organizer/events/${eventId}/ticket_types`, payload, config), () => setShowForm(false))
  }
  const handleUpdate = data => {
    const payload = { ...data }, ticketId = editingId
    mutate('update', config => apiClient.put(`/organizer/events/${eventId}/ticket_types/${ticketId}`, payload, config), () => setEditingId(null))
  }
  const handleDelete = ticketId => mutate('delete', config => apiClient.delete(`/organizer/events/${eventId}/ticket_types/${ticketId}`, config), () => setConfirmDeleteId(null))

  const handleSyncPassHolders = async (tt) => {
    if (!current() || busy.current || unconfirmed) return
    const request = beginRequest()
    if (!request) return
    busy.current = true
    setSyncingId(tt.id)
    setError(null)
    setSyncNotice(null)
    try {
      const response = await apiClient.post(
        `/organizer/events/${eventId}/ticket_types/${tt.id}/sync_pass_holders`,
        {},
        request.config,
      )
      if (!request.current()) return
      setConfirmSyncId(null)
      const issued = response.data?.issued_ticket_count ?? 0
      const parents = response.data?.parent_ticket_count ?? 0
      setSyncNotice(
        issued > 0
          ? `Synced ${parents} pass ${parents === 1 ? 'holder' : 'holders'}: issued ${issued} new night ${issued === 1 ? 'ticket' : 'tickets'}.`
          : `All ${parents} pass ${parents === 1 ? 'holder is' : 'holders are'} already up to date (0 new tickets needed).`
      )
      await onRefresh?.()
    } catch (err) {
      if (!request.current()) return
      setConfirmSyncId(null)
      setError(err.response?.data?.error || err.response?.data?.errors?.join(', ') || 'Could not sync pass holders right now.')
    } finally {
      request.release()
      if (request.current()) {
        busy.current = false
        setSyncingId(null)
      }
    }
  }

  return (
    <div className="card p-5 sm:p-6 mt-6">
      <div className="flex flex-col items-start gap-3 sm:flex-row sm:items-center sm:justify-between mb-4">
        <h2 className="text-lg font-semibold text-neutral-900">Ticket types</h2>
        {!showForm && !editingId && (
          <button disabled={locked} onClick={() => setShowForm(true)} className="btn-primary text-sm px-3 py-1.5 flex items-center gap-1.5">
            <Plus className="w-4 h-4" /> Add ticket type
          </button>
        )}
      </div>

      {error && (
        <div role="alert" className="mb-4 p-3 bg-red-50 border border-red-200 rounded-xl text-red-700 text-sm">{error}</div>
      )}
      {syncNotice && (
        <div role="status" className="mb-4 p-3 bg-emerald-50 border border-emerald-200 rounded-xl text-emerald-900 text-sm">{syncNotice}</div>
      )}

      {unconfirmed && <section aria-label="Unconfirmed ticket change" className="mb-4 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950"><p>A previous ticket change is not confirmed. Changes are paused to prevent repetition.</p><button type="button" disabled={!onRefresh} onClick={refreshList} className="min-h-11 font-semibold underline">Refresh ticket list</button><SupportLink subject="Verify an unconfirmed ticket change" className="ml-3 inline-flex min-h-11 items-center font-semibold underline">Contact support</SupportLink></section>}
      {showForm && (
        <div className="mb-4">
          <TicketTypeForm
            eventId={eventId}
            assignedSeating={assignedSeating}
            beginRequest={beginRequest}
            onSave={handleCreate}
            onCancel={() => setShowForm(false)}
            saving={locked}
            eventTimezone={eventTimezone}
            defaultQuantity={remainingCapacity}
            scannerQuestions={scannerQuestions}
          />
        </div>
      )}

      {ticketTypes.length === 0 && !showForm ? (
        <p className="text-sm text-neutral-500 text-center py-4">No ticket types yet. Add one to start selling tickets.</p>
      ) : (
        <div className="space-y-3">
          {ticketTypes.map(tt => {
            const includedNights = tt.included_events || []
            const includedCount = includedNights.length || (tt.included_event_ids || []).length
            const isExpanded = Boolean(expandedPassIds[tt.id])
            return (
            <div key={tt.id}>
              {editingId === tt.id ? (
                <TicketTypeForm
                  eventId={eventId}
                  assignedSeating={assignedSeating}
                  beginRequest={beginRequest}
                  editingTicketType={tt}
                  scannerQuestions={scannerQuestions}
                  initial={{
                    name: tt.name,
                    description: tt.description || '',
                    price: (tt.price_cents / 100).toFixed(2),
                    quantity_available: tt.quantity_available ? String(tt.quantity_available) : '',
                    door_allocation: tt.door_allocation == null ? '' : String(tt.door_allocation),
                    max_per_order: tt.max_per_order ? String(tt.max_per_order) : '',
                    max_per_buyer: tt.max_per_buyer ? String(tt.max_per_buyer) : '',
                    attendee_info_mode: tt.attendee_info_mode || 'none',
                    door_check_mode: tt.door_check_mode || 'instant',
                    door_alert_label: tt.door_alert_label || '',
                    door_instructions: tt.door_instructions || '',
                    scanner_show_buyer: tt.scanner_show_buyer === true,
                    sales_start_at: toEventLocalInput(tt.sales_start_at, eventTimezone),
                    sales_end_at: toEventLocalInput(tt.sales_end_at, eventTimezone)
                  }}
                  onSave={handleUpdate}
                  onCancel={() => setEditingId(null)}
                  saving={locked}
                  eventTimezone={eventTimezone}
                />
              ) : (
                <div>
                  <div className="flex flex-col gap-3 p-3 bg-neutral-50 rounded-xl sm:flex-row sm:items-center sm:justify-between">
                    <div className="min-w-0 sm:flex-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <p className="font-medium text-neutral-900 [overflow-wrap:anywhere]">{tt.name}</p>
                        {tt.is_pass && (
                          <span className="inline-flex items-center gap-1 rounded-full border border-brand-200 bg-brand-50 px-2.5 py-0.5 text-xs font-semibold text-brand-900">
                            <Sparkles aria-hidden="true" className="h-3 w-3" />
                            Multi-Night Pass · {includedCount} {includedCount === 1 ? 'night' : 'nights'}
                          </span>
                        )}
                      </div>
                      {tt.description && <p className="text-sm text-neutral-500">{tt.description}</p>}
                      {tt.is_pass && includedNights.length > 0 && (
                        <div className="mt-1.5">
                          <button
                            type="button"
                            aria-expanded={isExpanded}
                            onClick={() => setExpandedPassIds(prev => ({ ...prev, [tt.id]: !prev[tt.id] }))}
                            className="inline-flex items-center gap-1 text-xs font-semibold text-brand-800 hover:text-brand-950"
                          >
                            <span>{isExpanded ? 'Hide included nights' : `Included nights (${includedNights.length})`}</span>
                            <ChevronDown aria-hidden="true" className={`h-3.5 w-3.5 transition-transform ${isExpanded ? 'rotate-180' : ''}`} />
                          </button>
                          {isExpanded && (
                            <ul className="mt-1.5 space-y-1 rounded-lg border border-neutral-200 bg-white px-2.5 py-2 text-xs text-neutral-700">
                              {includedNights.map(night => (
                                <li key={night.id} className="flex flex-wrap items-baseline justify-between gap-2">
                                  <span className="font-medium text-neutral-900">{night.title}</span>
                                  {night.starts_at && (
                                    <span className="text-neutral-500">
                                      {formatEventDate(night.starts_at, night.timezone || eventTimezone || DEFAULT_EVENT_TIME_ZONE, { weekday: 'short' })}
                                    </span>
                                  )}
                                </li>
                              ))}
                            </ul>
                          )}
                        </div>
                      )}
                    </div>
                    <div className="flex flex-wrap items-center justify-between gap-3 sm:justify-end">
                      <div className="min-w-0 text-left sm:mr-2 sm:text-right">
                        <p className="font-semibold text-neutral-900">${(tt.price_cents / 100).toFixed(2)}</p>
                        {tt.current_price_cents != null && tt.current_price_cents !== tt.price_cents && (
                          <p className="text-xs text-emerald-600">Current: ${(tt.current_price_cents / 100).toFixed(2)}</p>
                        )}
                        <p className="text-xs text-neutral-500">{tt.quantity_sold ?? 0}/{tt.quantity_available ?? '∞'} sold</p>
                        {tt.door_allocation != null && <p className="text-xs text-brand-700">Door: {tt.door_sold_quantity ?? 0}/{tt.door_allocation}</p>}
                        {(tt.sales_start_at || tt.sales_end_at) && (
                          <p className="text-xs text-content-muted">
                            {tt.sales_start_at ? `From ${formatEventDateTime(tt.sales_start_at, eventTimezone)}` : 'On sale now'}
                            {tt.sales_end_at ? ` to ${formatEventDateTime(tt.sales_end_at, eventTimezone)}` : ''}
                          </p>
                        )}
                      </div>
                      {tt.is_pass && (tt.quantity_sold ?? 0) > 0 && (
                        confirmSyncId === tt.id ? (
                          <div className="flex items-center gap-1 rounded-lg border border-brand-200 bg-white px-2 py-1">
                            <span className="text-xs font-medium text-neutral-800 mr-1">Sync pass holders?</span>
                            <button
                              type="button"
                              disabled={locked}
                              onClick={() => handleSyncPassHolders(tt)}
                              className="min-h-11 rounded px-2 text-xs font-semibold text-brand-800 hover:bg-brand-50"
                            >
                              {syncingId === tt.id ? 'Syncing…' : 'Confirm Sync'}
                            </button>
                            <button
                              type="button"
                              disabled={locked}
                              onClick={() => setConfirmSyncId(null)}
                              className="min-h-11 rounded px-2 text-xs font-medium text-neutral-600 hover:text-neutral-900"
                            >
                              Cancel
                            </button>
                          </div>
                        ) : (
                          <button
                            type="button"
                            disabled={locked}
                            onClick={() => { setConfirmSyncId(tt.id); setConfirmDeleteId(null) }}
                            className="btn-secondary min-h-11 gap-1.5 px-3 text-xs"
                          >
                            <RefreshCw aria-hidden="true" className={`h-3.5 w-3.5 ${syncingId === tt.id ? 'animate-spin' : ''}`} />
                            Sync Pass Holders
                          </button>
                        )
                      )}
                    {confirmDeleteId === tt.id ? (
                      <div className="flex items-center gap-1">
                        <span className="text-xs text-red-600 mr-1">Delete?</span>
                        <button onClick={() => handleDelete(tt.id)} disabled={locked} className="min-h-11 min-w-11 rounded px-2 text-red-700 hover:text-red-900 text-sm font-medium focus-visible:ring-2 focus-visible:ring-focus">
                          {deletingId === tt.id ? '...' : 'Yes'}
                        </button>
                        <button disabled={locked} onClick={() => setConfirmDeleteId(null)} className="min-h-11 min-w-11 rounded px-2 text-content-muted hover:text-neutral-900 text-sm font-medium focus-visible:ring-2 focus-visible:ring-focus">No</button>
                      </div>
                    ) : (
                      <>
                        <button disabled={locked} aria-label={`Edit ${tt.name}`} onClick={() => { setEditingId(tt.id); setShowForm(false); setConfirmSyncId(null) }} className="min-h-11 min-w-11 grid place-items-center text-content-muted hover:text-brand-800 rounded-lg hover:bg-brand-50 focus-visible:ring-2 focus-visible:ring-focus">
                          <Pencil className="w-4 h-4" />
                        </button>
                        <button disabled={locked} aria-label={`Delete ${tt.name}`} onClick={() => { setConfirmDeleteId(tt.id); setConfirmSyncId(null) }} className="min-h-11 min-w-11 grid place-items-center text-content-muted hover:text-red-800 rounded-lg hover:bg-red-50 focus-visible:ring-2 focus-visible:ring-focus">
                          <Trash2 className="w-4 h-4" />
                        </button>
                      </>
                    )}
                  </div>
                </div>
                  <PricingTiersCRUD eventId={eventId} ticketTypeId={tt.id} eventTimezone={eventTimezone} salesEndAt={tt.sales_end_at} basePriceCents={tt.price_cents} beginRequest={beginRequest} onRefresh={onRefresh} blocked={locked} />
                </div>
              )}
            </div>
            )
          })}
        </div>
      )}
    </div>
  )
}

export default function TicketTypeCRUD(props) {
  const identity = useOrganizerIdentity()
  const location = useLocation()
  const resourceKey = String(props.eventId)
  const resource = useRef({ key: resourceKey, path: location.pathname.replace(/\/$/, '') })
  if (resource.current.key !== resourceKey) resource.current = { key: resourceKey, path: location.pathname.replace(/\/$/, '') }
  const visit = useOrganizerPageVisit(resource.current.path)
  if (!visit.active) return null
  if (!identity.ready) return <p role="status" className="p-4 text-sm text-neutral-700">Preparing inventory access…</p>
  return <TicketTypesSession key={`${identity.accountKey}:${identity.organizationId}:${resourceKey}:${visit.generation}`} {...props} identity={identity} resourcePath={resource.current.path} />
}
