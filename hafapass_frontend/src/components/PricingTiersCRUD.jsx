import { useState, useEffect, useCallback, useLayoutEffect, useRef, useId } from 'react'
import { Plus, Pencil, Trash2, Loader2, Clock, Hash, ArrowUp, ArrowDown } from 'lucide-react'
import apiClient from '../api/client'
import { useLocation } from 'react-router-dom'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../hooks/useOrganizerContext'
import SupportLink from './SupportLink'
import { toEventLocalInput } from '../utils/eventTime'
import { formatScheduleTime, scheduleTimezoneLabel } from '../utils/serverClock'
import { formatMoneyCents } from '../utils/money'

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

const EMPTY_FORM = {
  name: '',
  price: '',
  tier_type: 'time_based',
  quantity_limit: '',
  starts_at: '',
  ends_at: ''
}

function localBoundary(value, timezone) {
  return toEventLocalInput(value, timezone, { includeSeconds: true })
}

function ScheduleBoundary({ field, label, value, onChange }) {
  const [date = '', time = ''] = value.split('T')
  return (
    <fieldset className="min-w-0 space-y-1">
      <legend className="text-sm font-medium text-neutral-700">{label}</legend>
      <div className="grid gap-2 sm:grid-cols-2">
        <input type="date" aria-label={`${label} date`} className="input min-w-0" value={date} onChange={e => onChange(field, `${e.target.value}T${time}`)} />
        <input type="time" step="1" aria-label={`${label} time`} className="input min-w-0" value={time} onChange={e => onChange(field, `${date}T${e.target.value}`)} />
      </div>
    </fieldset>
  )
}

function TierForm({ initial, editing = false, onSave, onCancel, saving, eventTimezone }) {
  const formId = useId()
  const [form, setForm] = useState(initial || EMPTY_FORM)
  const [error, setError] = useState(null)

  const handleSubmit = (e) => {
    e.preventDefault()
    if (!form.name.trim()) { setError('Name is required'); return }
    setError(null)

    const data = {
      name: form.name.trim(),
      price_cents: Math.round(parseFloat(form.price || '0') * 100),
      tier_type: form.tier_type
    }

    if (form.tier_type === 'quantity_based') {
      data.quantity_limit = form.quantity_limit ? parseInt(form.quantity_limit, 10) : null
    } else {
      for (const field of ['starts_at', 'ends_at']) {
        const [date, time] = form[field].split('T')
        if (Boolean(date) !== Boolean(time)) {
          setError(`Enter both the date and time for ${field === 'starts_at' ? 'Starts at' : 'Ends at'}.`)
          return
        }
        // Keep the exact instant on edit or chain, including seconds and DST folds.
        data[field] = date ? (form[field] === initial?.[field] ? initial.instants?.[field] || form[field] : form[field]) : null
      }
      if (!data.starts_at && !data.ends_at) {
        setError('Enter a start or end for the price window.')
        return
      }
    }

    onSave(data)
  }

  return (
    <form onSubmit={handleSubmit} className="p-4 bg-neutral-50 rounded-xl border border-neutral-200 space-y-3">
      {error && <p role="alert" className="text-sm text-red-600">{error}</p>}
      <div className="grid grid-cols-2 gap-3">
        <div>
          <label htmlFor={`${formId}-name`} className="block text-sm font-medium text-neutral-700 mb-1">Name <span className="text-red-500">*</span></label>
          <input id={`${formId}-name`} value={form.name} onChange={e => setForm(f => ({...f, name: e.target.value}))} className="input" placeholder="e.g. Early Bird" disabled={saving} />
        </div>
        <div>
          <label htmlFor={`${formId}-price`} className="block text-sm font-medium text-neutral-700 mb-1">Price ($)</label>
          <input type="number" step="0.01" min="0" id={`${formId}-price`} value={form.price} onChange={e => setForm(f => ({...f, price: e.target.value}))} className="input" placeholder="0.00" disabled={saving} />
        </div>
      </div>
      <fieldset>
        <legend className="mb-1 text-sm font-medium text-neutral-700">Price applies by</legend>
        <div className="flex flex-wrap gap-2">
          {[['time_based', 'Date & Time window'], ['quantity_based', 'Quantity cap']].map(([type, label]) => (
            <label key={type} className="flex min-h-11 items-center gap-2 rounded-lg border border-neutral-200 px-3 text-sm">
              <input type="radio" name={`${formId}-type`} checked={form.tier_type === type}
                onChange={() => setForm(f => ({ ...f, tier_type: type }))} disabled={saving} />
              {label}
            </label>
          ))}
        </div>
      </fieldset>
      {form.tier_type === 'quantity_based' && (
        <div>
          <label htmlFor={`${formId}-quantity_limit`} className="block text-sm font-medium text-neutral-700 mb-1">Quantity limit</label>
          <input type="number" min="1" id={`${formId}-quantity_limit`} value={form.quantity_limit} onChange={e => setForm(f => ({...f, quantity_limit: e.target.value}))} className="input" placeholder="e.g. 50" disabled={saving} />
        </div>
      )}
      {form.tier_type === 'time_based' && (
        <fieldset disabled={saving} className="space-y-3">
          <legend className="text-xs font-semibold text-neutral-600">Dates and times use {scheduleTimezoneLabel(eventTimezone)}</legend>
          <ScheduleBoundary field="starts_at" label="Starts at" value={form.starts_at} onChange={(field, value) => setForm(f => ({ ...f, [field]: value }))} />
          <ScheduleBoundary field="ends_at" label="Ends at" value={form.ends_at} onChange={(field, value) => setForm(f => ({ ...f, [field]: value }))} />
        </fieldset>
      )}
      <div className="flex gap-2 justify-end">
        <button type="button" onClick={onCancel} disabled={saving} className="min-h-11 rounded px-3 py-1.5 text-sm text-content-muted hover:text-neutral-900 focus-visible:ring-2 focus-visible:ring-focus">Cancel</button>
        <button type="submit" disabled={saving} className="btn-primary text-sm px-4 py-1.5">
          {saving ? 'Saving...' : editing ? 'Update' : 'Add price'}
        </button>
      </div>
    </form>
  )
}

function PricingTiersSession({ eventId, ticketTypeId, eventTimezone = 'Pacific/Guam', salesEndAt, basePriceCents, beginRequest: parentBeginRequest, onRefresh, blocked = false, identity, resourcePath }) {
  const { current, beginRequest } = useInventoryRequests(identity, resourcePath, parentBeginRequest)
  const busy = useRef(false)
  const pendingLoad = useRef(null)
  const loadGeneration = useRef(0)
  const storageKey = `hafapass:pending-pricing-tiers:${identity.owner}:${identity.organizationId}:${eventId}:${ticketTypeId}`
  const [unconfirmed, setUnconfirmed] = useState(() => readPendingInventory(storageKey))
  const [refreshing, setRefreshing] = useState(false)
  const [loadError, setLoadError] = useState(null)
  const [tiers, setTiers] = useState([])
  const [loading, setLoading] = useState(true)
  const [showForm, setShowForm] = useState(null)
  const [editingId, setEditingId] = useState(null)
  const [saving, setSaving] = useState(false)
  const [deletingId, setDeletingId] = useState(null)
  const [error, setError] = useState(null)

  const basePath = `/organizer/events/${eventId}/ticket_types/${ticketTypeId}/pricing_tiers`

  const fetchTiers = useCallback(async () => {
    const request = beginRequest()
    if (!request) return
    pendingLoad.current?.controller.abort()
    pendingLoad.current = request
    const generation = ++loadGeneration.current
    const canApply = () => request.current() && generation === loadGeneration.current
    setRefreshing(true); setLoadError(null)
    try {
      const response = await apiClient.get(basePath, request.config)
      if (canApply()) setTiers(Array.isArray(response.data) ? response.data : [])
    } catch (error) {
      if (canApply()) {
        if ([401, 403, 404].includes(error.response?.status)) { setTiers([]); setShowForm(false); setEditingId(null) }
        setLoadError('Pricing tiers could not be loaded. Retry the list; drafts are retained unless event access was withdrawn.')
      }
    } finally {
      if (canApply()) { setLoading(false); setRefreshing(false) }
      request.release()
    }
  }, [basePath, beginRequest])
  useEffect(() => { fetchTiers() }, [fetchTiers])
  const locked = blocked || saving || deletingId !== null || refreshing || Boolean(loadError) || Boolean(unconfirmed)
  const mutate = async (operation, send, onSuccess, tierId) => {
    if (!current() || busy.current || locked) return
    const request = beginRequest()
    if (!request) return
    busy.current = true
    setError(null)
    if (operation === 'delete') setDeletingId(tierId)
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
      await fetchTiers()
      if (request.current()) await onRefresh?.()
    } catch (error) {
      if (!request.current()) return
      if (!sent) {
        setError('This browser could not retain the pending request. No change was sent. Allow browser storage before trying again.')
      } else if (!confirmed && uncertainInventoryResponse(error)) {
        setUnconfirmed({ operation })
        setError('The pricing change may have completed. Do not repeat it; refresh the list and ask support to verify the result.')
      } else if (confirmed) {
        setError('The pricing change was saved, but the latest event inventory could not be refreshed.')
      } else {
        window.sessionStorage.removeItem(storageKey)
        setError(error.response?.data?.errors?.join(', ') || error.response?.data?.error || 'The pricing change was rejected. Your draft is still here.')
      }
    } finally {
      request.release()
      if (request.current()) { busy.current = false; setSaving(false); setDeletingId(null) }
    }
  }
  const handleCreate = data => {
    const payload = { ...data }
    mutate('create', config => apiClient.post(basePath, payload, config), () => setShowForm(false))
  }
  const handleUpdate = data => {
    const payload = { ...data }, tierId = editingId
    mutate('update', config => apiClient.put(`${basePath}/${tierId}`, payload, config), () => setEditingId(null))
  }
  const handleDelete = tierId => mutate('delete', config => apiClient.delete(`${basePath}/${tierId}`, config), () => {}, tierId)

  const windows = tiers.filter(tier => tier.tier_type === 'time_based')
    .sort((a, b) => (a.starts_at ? Date.parse(a.starts_at) : -Infinity) - (b.starts_at ? Date.parse(b.starts_at) : -Infinity) || a.id - b.id)
  const quantityCaps = tiers.filter(tier => tier.tier_type === 'quantity_based')
  const previousEnd = windows.at(-1)?.ends_at
  const scheduleTime = value => formatScheduleTime(value, eventTimezone, { includeLocal: false })
  const handleMove = (id, direction) => mutate('reorder', config =>
    apiClient.patch(`${basePath}/${id}/move`, { direction }, config), () => {})

  if (loading) return <div className="text-sm text-neutral-600 py-2"><Loader2 className="w-4 h-4 animate-spin inline mr-1" /> Loading tiers...</div>

  return (
    <div className="mt-3 border-l-2 border-brand-200 pl-3 sm:ml-4 sm:pl-4">
      <div className="mb-2 flex flex-wrap items-center justify-between gap-x-2">
        <h4 className="text-sm font-semibold text-neutral-900">Pricing Schedule</h4>
        {!showForm && !editingId && (
          <button disabled={locked} onClick={() => setShowForm(EMPTY_FORM)} className="min-h-11 rounded px-2 text-sm text-brand-800 hover:text-brand-900 font-medium flex items-center gap-1 focus-visible:ring-2 focus-visible:ring-focus">
            <Plus className="w-3 h-3" /> Add price
          </button>
        )}
      </div>

      {error && <p role="alert" className="text-sm text-red-800 mb-2">{error}</p>}
      {loadError && <div role="alert" className="mb-3 text-sm text-red-800"><p>{loadError}</p><button type="button" disabled={refreshing} onClick={fetchTiers} className="min-h-11 font-semibold underline">Retry pricing tiers</button></div>}
      {unconfirmed && <section aria-label="Unconfirmed pricing change" className="mb-3 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950"><p>A previous pricing change is not confirmed. Changes are paused to prevent repetition.</p><button type="button" disabled={refreshing} onClick={fetchTiers} className="min-h-11 font-semibold underline">Refresh pricing list</button><SupportLink subject="Verify an unconfirmed pricing change" className="ml-3 inline-flex min-h-11 items-center font-semibold underline">Contact support</SupportLink></section>}

      {showForm && (
        <div className="mb-3">
          <TierForm initial={showForm} onSave={handleCreate} onCancel={() => setShowForm(false)} saving={locked} eventTimezone={eventTimezone} />
        </div>
      )}

      {tiers.length === 0 && !showForm && !loadError && (
        <p className="text-xs text-content-muted">The base price applies outside price windows and quantity caps.</p>
      )}

      {(windows.length > 0 || salesEndAt) && <h5 className="mb-2 text-xs font-semibold text-neutral-600">Schedule Timeline Preview</h5>}
      <div className="space-y-2">
        {[...windows, ...quantityCaps].map((tier, index) => {
          const previous = index > 0 ? windows[index - 1] : null
          const gap = tier.tier_type === 'time_based' && previous?.ends_at && tier.starts_at
            && Date.parse(previous.ends_at) < Date.parse(tier.starts_at)
          const capIndex = quantityCaps.indexOf(tier)
          return <div key={tier.id}>
            {gap && <p className="mb-2 rounded-md bg-amber-50 px-3 py-2 text-xs text-amber-900">
              Gap from {scheduleTime(previous.ends_at)} to {scheduleTime(tier.starts_at)}.
              {basePriceCents != null ? ` The base price of ${formatMoneyCents(basePriceCents)} applies if no quantity cap is active.`
                : ' The base price applies if no quantity cap is active.'}
            </p>}
            {editingId === tier.id ? (
              <TierForm
                initial={{
                  name: tier.name,
                  price: (tier.price_cents / 100).toFixed(2),
                  tier_type: tier.tier_type,
                  quantity_limit: tier.quantity_limit ? String(tier.quantity_limit) : '',
                  starts_at: localBoundary(tier.starts_at, eventTimezone),
                  ends_at: localBoundary(tier.ends_at, eventTimezone),
                  instants: tier
                }}
                editing
                onSave={handleUpdate}
                onCancel={() => setEditingId(null)}
                saving={locked}
                eventTimezone={eventTimezone}
              />
            ) : (
              <div className="flex flex-col gap-3 py-3 px-3 bg-neutral-50 rounded-lg text-sm sm:flex-row sm:items-center sm:justify-between">
                <div className="min-w-0 flex flex-wrap items-center gap-2">
                  {tier.tier_type === 'quantity_based' ? (
                    <Hash className="w-3.5 h-3.5 text-neutral-400" />
                  ) : (
                    <Clock className="w-3.5 h-3.5 text-neutral-400" />
                  )}
                  <span className="font-medium text-neutral-800 [overflow-wrap:anywhere]">{tier.name}</span>
                  <span className="text-neutral-500">${(tier.price_cents / 100).toFixed(2)}</span>
                  {tier.active && (
                    <span className="text-xs bg-emerald-50 text-emerald-600 px-1.5 py-0.5 rounded-full font-medium">Active</span>
                  )}
                  {tier.tier_type === 'time_based' ? (
                    <span className="w-full text-xs text-neutral-600">
                      {tier.starts_at ? `Starts ${scheduleTime(tier.starts_at)}` : 'No start'} · {tier.ends_at ? `Ends ${scheduleTime(tier.ends_at)}` : 'No end'}
                    </span>
                  ) : <span className="text-xs text-neutral-600">{tier.quantity_sold}/{tier.quantity_limit} sold</span>}
                </div>
                <div className="flex shrink-0 items-center">
                  {capIndex >= 0 && <>
                    <button type="button" aria-label={`Move ${tier.name} up`} disabled={locked || capIndex === 0} onClick={() => handleMove(tier.id, 'up')}
                      className="grid min-h-11 min-w-11 place-items-center rounded text-neutral-600 focus-visible:ring-2 focus-visible:ring-focus disabled:opacity-40"><ArrowUp className="h-4 w-4" /></button>
                    <button type="button" aria-label={`Move ${tier.name} down`} disabled={locked || capIndex === quantityCaps.length - 1} onClick={() => handleMove(tier.id, 'down')}
                      className="grid min-h-11 min-w-11 place-items-center rounded text-neutral-600 focus-visible:ring-2 focus-visible:ring-focus disabled:opacity-40"><ArrowDown className="h-4 w-4" /></button>
                  </>}
                  <button disabled={locked} aria-label={`Edit pricing tier ${tier.name}`} onClick={() => { setEditingId(tier.id); setShowForm(false) }} className="min-h-11 min-w-11 grid place-items-center rounded text-content-muted hover:text-brand-800 focus-visible:ring-2 focus-visible:ring-focus">
                    <Pencil className="w-3.5 h-3.5" />
                  </button>
                  <button aria-label={`Delete pricing tier ${tier.name}`} onClick={() => handleDelete(tier.id)} disabled={locked} className="min-h-11 min-w-11 grid place-items-center rounded text-content-muted hover:text-red-800 focus-visible:ring-2 focus-visible:ring-focus">
                    {deletingId === tier.id ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : <Trash2 className="w-3.5 h-3.5" />}
                  </button>
                </div>
              </div>
            )}
          </div>
        })}
      </div>
      {previousEnd && !showForm && !editingId && (!salesEndAt || Date.parse(previousEnd) < Date.parse(salesEndAt)) && (
        <button type="button" disabled={locked} className="mt-1 flex min-h-11 items-center gap-1 text-sm font-semibold text-brand-800"
          onClick={() => setShowForm({ ...EMPTY_FORM, starts_at: localBoundary(previousEnd, eventTimezone), instants: { starts_at: previousEnd } })}>
          <Plus aria-hidden="true" className="h-4 w-4" /> Add next price window
        </button>
      )}
      {salesEndAt && <p className="mt-2 flex items-center gap-2 text-xs font-semibold text-neutral-700">
        <Clock aria-hidden="true" className="h-4 w-4 shrink-0" /> Sales close {scheduleTime(salesEndAt)}
      </p>}
    </div>
  )
}

export default function PricingTiersCRUD(props) {
  const identity = useOrganizerIdentity()
  const location = useLocation()
  const resourceKey = `${props.eventId}:${props.ticketTypeId}`
  const resource = useRef({ key: resourceKey, path: location.pathname.replace(/\/$/, '') })
  if (resource.current.key !== resourceKey) resource.current = { key: resourceKey, path: location.pathname.replace(/\/$/, '') }
  const visit = useOrganizerPageVisit(resource.current.path)
  if (!visit.active) return null
  if (!identity.ready) return <p role="status" className="p-4 text-sm text-neutral-700">Preparing inventory access…</p>
  return <PricingTiersSession key={`${identity.accountKey}:${identity.organizationId}:${resourceKey}:${visit.generation}`} {...props} identity={identity} resourcePath={resource.current.path} />
}
