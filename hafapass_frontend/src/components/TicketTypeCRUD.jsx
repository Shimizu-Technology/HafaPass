import { useState, useRef, useCallback, useLayoutEffect } from 'react'
import { Plus, Pencil, Trash2, ChevronDown, Loader2 } from 'lucide-react'
import apiClient from '../api/client'
import { useLocation } from 'react-router-dom'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../hooks/useOrganizerContext'
import SupportLink from './SupportLink'
import PricingTiersCRUD from './PricingTiersCRUD'
import { compareLocalDateTimes, formatEventDateTime, toEventLocalInput } from '../utils/eventTime'

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

const EMPTY_FORM = { name: '', description: '', price: '0.00', quantity_available: '', door_allocation: '', max_per_order: '', max_per_buyer: '', sales_start_at: '', sales_end_at: '' }

function TicketTypeForm({ initial, onSave, onCancel, saving, eventTimezone, defaultQuantity }) {
  const [form, setForm] = useState(() => initial || { ...EMPTY_FORM, quantity_available: Number.isInteger(defaultQuantity) && defaultQuantity > 0 ? String(defaultQuantity) : '' })
  const [error, setError] = useState(null)

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
    if (form.sales_start_at && form.sales_end_at && compareLocalDateTimes(form.sales_end_at, form.sales_start_at) <= 0) {
      invalid('Sales end must be after sales start.', 'ticket-type-sales-end')
      return
    }
    setError(null)
    onSave({
      name: form.name.trim(),
      description: form.description.trim() || null,
      price_cents: Math.round(price * 100),
      quantity_available: quantity,
      door_allocation: form.door_allocation === '' ? null : parseInt(form.door_allocation, 10),
      max_per_order: form.max_per_order ? parseInt(form.max_per_order, 10) : null,
      max_per_buyer: form.max_per_buyer ? parseInt(form.max_per_buyer, 10) : null,
      sales_start_at: form.sales_start_at || null,
      sales_end_at: form.sales_end_at || null
    })
  }

  return (
    <form onSubmit={handleSubmit} noValidate className="p-4 bg-neutral-50 rounded-xl border border-neutral-200 space-y-3">
      {error && <p role="alert" className="text-sm text-red-600">{error}</p>}
      <div>
        <label htmlFor="ticket-type-name" className="block text-sm font-medium text-neutral-700 mb-1">Name <span aria-hidden="true" className="text-red-500">*</span></label>
        <input id="ticket-type-name" required value={form.name} onChange={e => setForm(f => ({...f, name: e.target.value}))} className="input" placeholder="e.g., General Admission" disabled={saving} />
      </div>
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div>
          <label htmlFor="ticket-type-price" className="block text-sm font-medium text-neutral-700 mb-1">Price ($) <span aria-hidden="true" className="text-red-500">*</span></label>
          <input id="ticket-type-price" type="number" step="0.01" min="0" required value={form.price} onChange={e => setForm(f => ({ ...f, price: e.target.value }))} className="input" placeholder="0.00" aria-describedby="ticket-type-price-help" disabled={saving} />
          <p id="ticket-type-price-help" className="mt-1 text-xs text-neutral-500">Enter 0 for free tickets.</p>
        </div>
        <div>
          <label htmlFor="ticket-type-quantity" className="block text-sm font-medium text-neutral-700 mb-1">Tickets available <span aria-hidden="true" className="text-red-500">*</span></label>
          <input id="ticket-type-quantity" type="number" min="1" step="1" required value={form.quantity_available} onChange={e => setForm(f => ({ ...f, quantity_available: e.target.value }))} className="input" placeholder="e.g., 30" aria-describedby="ticket-type-quantity-help" disabled={saving} />
          <p id="ticket-type-quantity-help" className="mt-1 text-xs text-neutral-500">Total tickets for this type, including any already sold.{!initial && defaultQuantity != null && ` ${Math.max(0, defaultQuantity)} places remain in the event capacity.`}</p>
        </div>
      </div>
      <details className="group rounded-xl border border-neutral-200 bg-white px-3">
        <summary className="flex min-h-11 cursor-pointer items-center text-sm font-semibold text-neutral-700">More ticket options<ChevronDown aria-hidden="true" className="ml-auto h-4 w-4 group-open:rotate-180" /></summary>
        <div className="space-y-4 pb-4 pt-2">
          <div>
            <label htmlFor="ticket-type-description" className="block text-sm font-medium text-neutral-700 mb-1">Description</label>
            <input id="ticket-type-description" value={form.description} onChange={e => setForm(f => ({ ...f, description: e.target.value }))} className="input" placeholder="Optional description" disabled={saving} />
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
              <input id="ticket-type-max-order" type="number" min="1" step="1" value={form.max_per_order} onChange={e => setForm(f => ({ ...f, max_per_order: e.target.value }))} className="input" placeholder="No additional limit" disabled={saving} />
            </div>
            <div>
              <label htmlFor="ticket-type-max-buyer" className="block text-sm font-medium text-neutral-700 mb-1">Tickets per buyer</label>
              <input id="ticket-type-max-buyer" type="number" min="1" step="1" value={form.max_per_buyer} onChange={e => setForm(f => ({ ...f, max_per_buyer: e.target.value }))} className="input" placeholder="No additional limit" disabled={saving} />
            </div>
          </div>
          <p className="text-xs text-neutral-500">Blank purchase limits add no separate cap; event capacity and remaining ticket inventory still apply.</p>
        </div>
      </details>
      <div className="flex gap-2 justify-end">
        <button type="button" onClick={onCancel} disabled={saving} className="min-h-11 px-3 py-1.5 text-sm text-neutral-600 hover:text-neutral-800">Cancel</button>
        <button type="submit" disabled={saving} className="btn-primary min-h-11 text-sm px-4 py-1.5">
          {saving ? 'Saving...' : initial ? 'Update' : 'Add Ticket Type'}
        </button>
      </div>
    </form>
  )
}

function TicketTypesSession({ eventId, ticketTypes = [], onRefresh, remainingCapacity, eventTimezone = 'Pacific/Guam', beginRequest: parentBeginRequest, identity, resourcePath }) {
  const { current, beginRequest } = useInventoryRequests(identity, resourcePath, parentBeginRequest)
  const busy = useRef(false)
  const storageKey = `hafapass:pending-ticket-types:${identity.owner}:${identity.organizationId}:${eventId}`
  const [unconfirmed, setUnconfirmed] = useState(() => readPendingInventory(storageKey))
  const [showForm, setShowForm] = useState(false)
  const [editingId, setEditingId] = useState(null)
  const [saving, setSaving] = useState(false)
  const [deletingId, setDeletingId] = useState(null)
  const [confirmDeleteId, setConfirmDeleteId] = useState(null)
  const [error, setError] = useState(null)

  const locked = saving || deletingId !== null || Boolean(unconfirmed)
  const mutate = async (operation, send, onSuccess) => {
    if (!current() || busy.current || unconfirmed) return
    const request = beginRequest()
    if (!request) return
    busy.current = true
    setError(null)
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

  return (
    <div className="card p-5 sm:p-6 mt-6">
      <div className="flex flex-col items-start gap-3 sm:flex-row sm:items-center sm:justify-between mb-4">
        <h2 className="text-lg font-semibold text-neutral-900">Ticket Types</h2>
        {!showForm && !editingId && (
          <button disabled={locked} onClick={() => setShowForm(true)} className="btn-primary text-sm px-3 py-1.5 flex items-center gap-1.5">
            <Plus className="w-4 h-4" /> Add Ticket Type
          </button>
        )}
      </div>

      {error && (
        <div role="alert" className="mb-4 p-3 bg-red-50 border border-red-200 rounded-xl text-red-700 text-sm">{error}</div>
      )}

      {unconfirmed && <section aria-label="Unconfirmed ticket change" className="mb-4 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950"><p>A previous ticket change is not confirmed. Changes are paused to prevent repetition.</p><button type="button" disabled={!onRefresh} onClick={refreshList} className="min-h-11 font-semibold underline">Refresh ticket list</button><SupportLink subject="Verify an unconfirmed ticket change" className="ml-3 inline-flex min-h-11 items-center font-semibold underline">Contact support</SupportLink></section>}
      {showForm && (
        <div className="mb-4">
          <TicketTypeForm onSave={handleCreate} onCancel={() => setShowForm(false)} saving={locked} eventTimezone={eventTimezone} defaultQuantity={remainingCapacity} />
        </div>
      )}

      {ticketTypes.length === 0 && !showForm ? (
        <p className="text-sm text-neutral-500 text-center py-4">No ticket types yet. Add one to start selling tickets.</p>
      ) : (
        <div className="space-y-3">
          {ticketTypes.map(tt => (
            <div key={tt.id}>
              {editingId === tt.id ? (
                <TicketTypeForm
                  initial={{
                    name: tt.name,
                    description: tt.description || '',
                    price: (tt.price_cents / 100).toFixed(2),
                    quantity_available: tt.quantity_available ? String(tt.quantity_available) : '',
                    door_allocation: tt.door_allocation == null ? '' : String(tt.door_allocation),
                    max_per_order: tt.max_per_order ? String(tt.max_per_order) : '',
                    max_per_buyer: tt.max_per_buyer ? String(tt.max_per_buyer) : '',
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
                      <p className="font-medium text-neutral-900 [overflow-wrap:anywhere]">{tt.name}</p>
                      {tt.description && <p className="text-sm text-neutral-500">{tt.description}</p>}
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
                        <button disabled={locked} aria-label={`Edit ${tt.name}`} onClick={() => { setEditingId(tt.id); setShowForm(false) }} className="min-h-11 min-w-11 grid place-items-center text-content-muted hover:text-brand-800 rounded-lg hover:bg-brand-50 focus-visible:ring-2 focus-visible:ring-focus">
                          <Pencil className="w-4 h-4" />
                        </button>
                        <button disabled={locked} aria-label={`Delete ${tt.name}`} onClick={() => setConfirmDeleteId(tt.id)} className="min-h-11 min-w-11 grid place-items-center text-content-muted hover:text-red-800 rounded-lg hover:bg-red-50 focus-visible:ring-2 focus-visible:ring-focus">
                          <Trash2 className="w-4 h-4" />
                        </button>
                      </>
                    )}
                  </div>
                </div>
                  <PricingTiersCRUD eventId={eventId} ticketTypeId={tt.id} eventTimezone={eventTimezone} beginRequest={beginRequest} onRefresh={onRefresh} blocked={locked} />
                </div>
              )}
            </div>
          ))}
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
