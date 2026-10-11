import { useState, useEffect, useCallback, useLayoutEffect, useRef, useId } from 'react'
import { Plus, Pencil, Trash2, Loader2, Clock, Hash } from 'lucide-react'
import apiClient from '../api/client'
import { useLocation } from 'react-router-dom'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../hooks/useOrganizerContext'
import { supportMailto } from '../utils/supportContact'
import { toEventLocalInput } from '../utils/eventTime'

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
  tier_type: 'quantity_based',
  quantity_limit: '',
  starts_at: '',
  ends_at: '',
  position: '0'
}

function TierForm({ initial, onSave, onCancel, saving, eventTimezone }) {
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
      tier_type: form.tier_type,
      position: parseInt(form.position || '0', 10)
    }

    if (form.tier_type === 'quantity_based') {
      data.quantity_limit = form.quantity_limit ? parseInt(form.quantity_limit, 10) : null
    } else {
      data.starts_at = form.starts_at || null
      data.ends_at = form.ends_at || null
    }

    onSave(data)
  }

  return (
    <form onSubmit={handleSubmit} className="p-4 bg-neutral-50 rounded-xl border border-neutral-200 space-y-3">
      {error && <p className="text-sm text-red-600">{error}</p>}
      <div className="grid grid-cols-2 gap-3">
        <div>
          <label htmlFor={`${formId}-name`} className="block text-sm font-medium text-neutral-700 mb-1">Name <span className="text-red-500">*</span></label>
          <input id={`${formId}-name`} value={form.name} onChange={e => setForm(f => ({...f, name: e.target.value}))} className="input" placeholder="e.g., Early Bird" disabled={saving} />
        </div>
        <div>
          <label htmlFor={`${formId}-price`} className="block text-sm font-medium text-neutral-700 mb-1">Price ($)</label>
          <input type="number" step="0.01" min="0" id={`${formId}-price`} value={form.price} onChange={e => setForm(f => ({...f, price: e.target.value}))} className="input" placeholder="0.00" disabled={saving} />
        </div>
      </div>
      <div className="grid grid-cols-2 gap-3">
        <div>
          <label htmlFor={`${formId}-tier_type`} className="block text-sm font-medium text-neutral-700 mb-1">Type</label>
          <select id={`${formId}-tier_type`} value={form.tier_type} onChange={e => setForm(f => ({...f, tier_type: e.target.value}))} className="input" disabled={saving}>
            <option value="quantity_based">Quantity Based</option>
            <option value="time_based">Time Based</option>
          </select>
        </div>
        <div>
          <label htmlFor={`${formId}-position`} className="block text-sm font-medium text-neutral-700 mb-1">Position</label>
          <input type="number" min="0" id={`${formId}-position`} value={form.position} onChange={e => setForm(f => ({...f, position: e.target.value}))} className="input" disabled={saving} />
        </div>
      </div>
      {form.tier_type === 'quantity_based' && (
        <div>
          <label htmlFor={`${formId}-quantity_limit`} className="block text-sm font-medium text-neutral-700 mb-1">Quantity Limit</label>
          <input type="number" min="1" id={`${formId}-quantity_limit`} value={form.quantity_limit} onChange={e => setForm(f => ({...f, quantity_limit: e.target.value}))} className="input" placeholder="e.g., 50" disabled={saving} />
        </div>
      )}
      {form.tier_type === 'time_based' && (
        <div><p className="text-xs text-neutral-500 mb-2">Times use {eventTimezone || 'Pacific/Guam'}.</p><div className="grid grid-cols-2 gap-3">
          <div>
            <label htmlFor={`${formId}-starts_at`} className="block text-sm font-medium text-neutral-700 mb-1">Starts At</label>
            <input type="datetime-local" id={`${formId}-starts_at`} value={form.starts_at} onChange={e => setForm(f => ({...f, starts_at: e.target.value}))} className="input" disabled={saving} />
          </div>
          <div>
            <label htmlFor={`${formId}-ends_at`} className="block text-sm font-medium text-neutral-700 mb-1">Ends At</label>
            <input type="datetime-local" id={`${formId}-ends_at`} value={form.ends_at} onChange={e => setForm(f => ({...f, ends_at: e.target.value}))} className="input" disabled={saving} />
          </div>
        </div></div>
      )}
      <div className="flex gap-2 justify-end">
        <button type="button" onClick={onCancel} disabled={saving} className="px-3 py-1.5 text-sm text-neutral-600 hover:text-neutral-800">Cancel</button>
        <button type="submit" disabled={saving} className="btn-primary text-sm px-4 py-1.5">
          {saving ? 'Saving...' : initial ? 'Update' : 'Add Tier'}
        </button>
      </div>
    </form>
  )
}

function PricingTiersSession({ eventId, ticketTypeId, eventTimezone = 'Pacific/Guam', beginRequest: parentBeginRequest, onRefresh, blocked = false, identity, resourcePath }) {
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
  const [showForm, setShowForm] = useState(false)
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

  if (loading) return <div className="text-sm text-neutral-400 py-2"><Loader2 className="w-4 h-4 animate-spin inline mr-1" /> Loading tiers...</div>

  return (
    <div className="mt-3 ml-4 border-l-2 border-brand-200 pl-4">
      <div className="flex items-center justify-between mb-2">
        <h4 className="text-sm font-medium text-neutral-700">Pricing Tiers</h4>
        {!showForm && !editingId && (
          <button disabled={locked} onClick={() => setShowForm(true)} className="text-xs text-brand-500 hover:text-brand-600 font-medium flex items-center gap-1">
            <Plus className="w-3 h-3" /> Add Tier
          </button>
        )}
      </div>

      {error && <p role="alert" className="text-sm text-red-800 mb-2">{error}</p>}
      {loadError && <div role="alert" className="mb-3 text-sm text-red-800"><p>{loadError}</p><button type="button" disabled={refreshing} onClick={fetchTiers} className="min-h-11 font-semibold underline">Retry pricing tiers</button></div>}
      {unconfirmed && <section aria-label="Unconfirmed pricing change" className="mb-3 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950"><p>A previous pricing change is not confirmed. Changes are paused to prevent repetition.</p><button type="button" disabled={refreshing} onClick={fetchTiers} className="min-h-11 font-semibold underline">Refresh pricing list</button><a href={supportMailto('Verify an unconfirmed pricing change')} className="ml-3 inline-flex min-h-11 items-center font-semibold underline">Contact support</a></section>}

      {showForm && (
        <div className="mb-3">
          <TierForm onSave={handleCreate} onCancel={() => setShowForm(false)} saving={locked} eventTimezone={eventTimezone} />
        </div>
      )}

      {tiers.length === 0 && !showForm && !loadError && (
        <p className="text-xs text-neutral-400">No pricing tiers. Base price will be used.</p>
      )}

      <div className="space-y-2">
        {tiers.map(tier => (
          <div key={tier.id}>
            {editingId === tier.id ? (
              <TierForm
                initial={{
                  name: tier.name,
                  price: (tier.price_cents / 100).toFixed(2),
                  tier_type: tier.tier_type,
                  quantity_limit: tier.quantity_limit ? String(tier.quantity_limit) : '',
                  starts_at: toEventLocalInput(tier.starts_at, eventTimezone),
                  ends_at: toEventLocalInput(tier.ends_at, eventTimezone),
                  position: String(tier.position)
                }}
                onSave={handleUpdate}
                onCancel={() => setEditingId(null)}
                saving={locked}
                eventTimezone={eventTimezone}
              />
            ) : (
              <div className="flex items-center justify-between py-2 px-3 bg-neutral-50 rounded-lg text-sm">
                <div className="flex items-center gap-2">
                  {tier.tier_type === 'quantity_based' ? (
                    <Hash className="w-3.5 h-3.5 text-neutral-400" />
                  ) : (
                    <Clock className="w-3.5 h-3.5 text-neutral-400" />
                  )}
                  <span className="font-medium text-neutral-800">{tier.name}</span>
                  <span className="text-neutral-500">${(tier.price_cents / 100).toFixed(2)}</span>
                  {tier.active && (
                    <span className="text-xs bg-emerald-50 text-emerald-600 px-1.5 py-0.5 rounded-full font-medium">Active</span>
                  )}
                  {tier.tier_type === 'quantity_based' && (
                    <span className="text-xs text-neutral-400">{tier.quantity_sold}/{tier.quantity_limit} sold</span>
                  )}
                </div>
                <div className="flex items-center gap-1">
                  <button disabled={locked} aria-label={`Edit pricing tier ${tier.name}`} onClick={() => { setEditingId(tier.id); setShowForm(false) }} className="p-1 text-neutral-400 hover:text-brand-500">
                    <Pencil className="w-3.5 h-3.5" />
                  </button>
                  <button aria-label={`Delete pricing tier ${tier.name}`} onClick={() => handleDelete(tier.id)} disabled={locked} className="p-1 text-neutral-400 hover:text-red-500">
                    {deletingId === tier.id ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : <Trash2 className="w-3.5 h-3.5" />}
                  </button>
                </div>
              </div>
            )}
          </div>
        ))}
      </div>
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
