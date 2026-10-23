import EventWorkspace from '../../components/EventWorkspace'
import Dialog from '../../components/Dialog'
import { useState, useEffect, useCallback, useRef } from 'react'
import { Link, useParams } from 'react-router-dom'
import { Plus, Tag, Trash2, Pencil, ToggleLeft, ToggleRight, Loader2 } from 'lucide-react'
import apiClient from '../../api/client'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import SupportLink from '../../components/SupportLink'
import { formatEventDateTime, toEventLocalInput, fromEventLocalInput } from '../../utils/eventTime'
import { promoDiscountToApi, promoDiscountFromApi } from '../../utils/promoDiscount'

const readPendingOperation = key => {
  try {
    const raw = window.sessionStorage.getItem(key)
    if (raw === null) return null
    const value = JSON.parse(raw)
    return value && typeof value.operation === 'string' ? value : { operation: 'unconfirmed_change' }
  } catch { return { operation: 'unconfirmed_change' } }
}
const uncertainResponse = error => !error.response || error.response.status >= 500
  || [408, 409, 429].includes(error.response.status) || error.response.data?.reconciliation_required === true
const errorMessage = (error, fallback) => error.response?.data?.errors?.join(', ') || error.response?.data?.error || fallback

function PromoCodesSession({ eventId, identity }) {
  const { current, beginRequest } = useOrganizerRequests(identity, `/dashboard/events/${eventId}/promo-codes`)
  const pendingLoad = useRef(null)
  const loadGeneration = useRef(0)
  const mutationBusy = useRef(false)
  const storageKey = `hafapass:pending-promo-codes:${identity.owner}:${identity.organizationId}:${eventId}`
  const [unconfirmed, setUnconfirmed] = useState(() => readPendingOperation(storageKey))
  const unconfirmedRef = useRef(unconfirmed)
  const [event, setEvent] = useState(null)
  const [refreshing, setRefreshing] = useState(false)
  const [loadError, setLoadError] = useState('')
  const [mutationError, setMutationError] = useState('')
  const [notice, setNotice] = useState('')
  const [activeMutation, setActiveMutation] = useState(null)
  const [confirmation, setConfirmation] = useState(null)
  const [codes, setCodes] = useState([])
  const [loading, setLoading] = useState(true)
  const [showForm, setShowForm] = useState(false)
  const [editingCode, setEditingCode] = useState(null)
  const [form, setForm] = useState({ code: '', discount_type: 'percentage', discount_value: '', max_uses: '', expires_at: '' })
  const saving = activeMutation === 'create_code' || activeMutation === 'edit_code'
  const clearPrivateState = useCallback(() => {
    setConfirmation(null); setEvent(null); setCodes([]); setShowForm(false); setEditingCode(null)
    setForm({ code: '', discount_type: 'percentage', discount_value: '', max_uses: '', expires_at: '' })
  }, [])
  const fetchData = useCallback(async () => {
    const request = beginRequest()
    if (!request) return
    pendingLoad.current?.controller.abort()
    pendingLoad.current = request
    const generation = ++loadGeneration.current
    const canApply = () => request.current() && generation === loadGeneration.current
    setRefreshing(true); setLoadError('')
    try {
      const [codesResponse, eventResponse] = await Promise.all([
        apiClient.get(`/organizer/events/${eventId}/promo_codes`, request.config),
        apiClient.get(`/organizer/events/${eventId}`, request.config),
      ])
      if (!canApply()) return
      if (eventResponse.data.permissions?.manage_marketing !== true) {
        clearPrivateState(); setEvent(eventResponse.data); return
      }
      setEvent(eventResponse.data)
      setCodes(Array.isArray(codesResponse.data) ? codesResponse.data : [])
    } catch (error) {
      if (!canApply()) return
      if ([401, 403, 404].includes(error.response?.status)) clearPrivateState()
      setLoadError(errorMessage(error, 'Promo codes could not be loaded.'))
    } finally {
      if (canApply()) { setLoading(false); setRefreshing(false) }
      request.release()
    }
  }, [beginRequest, clearPrivateState, eventId])
  useEffect(() => { fetchData() }, [fetchData])
  const canManage = event?.permissions?.manage_marketing === true
  const mutationsLocked = !canManage || refreshing || Boolean(loadError) || Boolean(activeMutation) || Boolean(unconfirmed)

  const askConfirmation = (operation, message, label, send, complete) => {
    if (!current() || mutationsLocked || mutationBusy.current) return
    setConfirmation({ operation, message, label, send, complete })
  }
  const confirmOperation = () => {
    if (!current() || !confirmation || mutationsLocked) return
    const chosen = confirmation
    setConfirmation(null)
    performMutation(chosen.operation, chosen.send, chosen.complete)
  }

  const performMutation = async (operation, send, complete) => {
    if (!current() || mutationsLocked || mutationBusy.current || unconfirmedRef.current) return
    const request = beginRequest()
    if (!request) return
    mutationBusy.current = true
    setActiveMutation(operation)
    setMutationError('')
    setNotice('')
    try {
      // These endpoints do not expose a replayable operation key. Remember an
      // in-flight write before transport so a remount cannot blindly repeat it.
      window.sessionStorage.setItem(storageKey, JSON.stringify({ operation, started_at: new Date().toISOString() }))
    } catch {
      mutationBusy.current = false
      setActiveMutation(null)
      request.release()
      setMutationError('This browser could not retain the request state. No change was sent. Allow browser storage and try again.')
      return
    }
    try {
      const response = await send(request.config)
      if (!request.current()) return
      window.sessionStorage.removeItem(storageKey)
      unconfirmedRef.current = null
      setUnconfirmed(null)
      complete(response.data || {})
      await fetchData()
    } catch (error) {
      if (!request.current()) return
      if (uncertainResponse(error)) {
        const pending = { operation }
        unconfirmedRef.current = pending
        setUnconfirmed(pending)
        setMutationError('The response was interrupted. The change may have completed. Do not repeat it; refresh the list and ask support to verify the result.')
      } else {
        window.sessionStorage.removeItem(storageKey)
        setMutationError(errorMessage(error, 'The change was rejected. Your draft is still available.'))
        if ([401, 403, 404].includes(error.response?.status)) clearPrivateState()
      }
    } finally {
      request.release()
      if (request.current()) { mutationBusy.current = false; setActiveMutation(null) }
    }
  }

  const handleCreate = submitEvent => {
    submitEvent.preventDefault()
    const payload = { code: form.code, discount_type: form.discount_type, discount_value: promoDiscountToApi(form.discount_value, form.discount_type),
      max_uses: form.max_uses ? parseInt(form.max_uses, 10) : null, expires_at: editingCode && form.expires_at === toEventLocalInput(editingCode.expires_at, event?.timezone)
        ? editingCode.expires_at : form.expires_at ? fromEventLocalInput(form.expires_at, event?.timezone)?.toISOString() : null }
    if (payload.discount_value === null || (form.expires_at && !payload.expires_at)) { setMutationError('Enter a valid discount and expiration time.'); return }
    const codeId = editingCode?.id
    performMutation(codeId ? 'edit_code' : 'create_code', config => codeId
      ? apiClient.patch(`/organizer/events/${eventId}/promo_codes/${codeId}`, payload, config)
      : apiClient.post(`/organizer/events/${eventId}/promo_codes`, payload, config), () => {
      setForm({ code: '', discount_type: 'percentage', discount_value: '', max_uses: '', expires_at: '' })
      setShowForm(false); setEditingCode(null); setNotice(codeId ? 'Promo code updated.' : 'Promo code created.')
    })
  }
  const editCode = code => {
    setEditingCode(code)
    setForm({ code: code.code, discount_type: code.discount_type, discount_value: promoDiscountFromApi(code.discount_value, code.discount_type), max_uses: code.max_uses ? String(code.max_uses) : '', expires_at: toEventLocalInput(code.expires_at, event?.timezone) })
    setShowForm(true)
  }
  const toggleActive = code => performMutation('update_code', config => apiClient.patch(`/organizer/events/${eventId}/promo_codes/${code.id}`, { active: !code.active }, config), () => setNotice('Promo code updated.'))
  const deleteCode = code => {
    askConfirmation('delete_code', `Delete promo code ${code.code}?`, 'Remove code', config => apiClient.delete(`/organizer/events/${eventId}/promo_codes/${code.id}`, config), () => setNotice('Promo code removed.'))
  }
  if (loading) return <div className="flex justify-center py-20" role="status"><Loader2 className="w-8 h-8 text-brand-500 animate-spin" /> Loading promo codes…</div>
  if (!event) return <main className="mx-auto max-w-3xl px-4 py-8">
    <Link to="/dashboard" className="inline-flex min-h-11 items-center font-medium text-brand-800">All events</Link>
    <h1 className="mt-3 text-2xl font-bold">Promo codes</h1>
    <p role="alert" className="mt-4 text-sm text-red-800">{loadError || mutationError || 'Event access is unavailable.'}</p>
    <button type="button" disabled={refreshing} onClick={fetchData} className="btn-secondary mt-3">Retry promo codes</button>
  </main>
  if (!canManage) return <EventWorkspace eventId={eventId} event={event}><p role="status" className="text-neutral-700">Your event access does not include this tool.</p></EventWorkspace>
 return (
  <EventWorkspace eventId={eventId} event={event}><div className="min-w-0 w-full max-w-4xl mx-auto">

   <div className="flex flex-col items-start gap-4 mb-8 sm:flex-row sm:items-center sm:justify-between">
    <div>
     <h2 className="text-2xl font-bold tracking-tight text-neutral-900">Promo codes</h2>
     <p className="text-sm text-neutral-500 mt-1">Create discount codes for your event</p>
    </div>
    <button disabled={mutationsLocked} onClick={() => {
      if (editingCode) { setEditingCode(null); setForm({ code: '', discount_type: 'percentage', discount_value: '', max_uses: '', expires_at: '' }); setShowForm(true) }
      else setShowForm(!showForm)
    }} className="btn-primary text-sm !py-2.5 gap-1.5">
     <Plus className="w-4 h-4" /> New code
    </button>
   </div>


   {confirmation && <Dialog labelledBy="promo-codes-confirm-title" onClose={() => setConfirmation(null)}>
     <h3 id="promo-codes-confirm-title" className="text-lg font-semibold text-neutral-950">Confirm action</h3>
     <p className="mt-3 break-words text-sm text-neutral-700">{confirmation.message}</p>
     <div className="mt-5 flex flex-wrap gap-3"><button type="button" className="btn-secondary" onClick={() => setConfirmation(null)}>Cancel</button><button type="button" className="btn-primary" disabled={mutationsLocked} onClick={confirmOperation}>{confirmation.label}</button></div>
   </Dialog>}
   {refreshing && <p role="status" className="mb-4 text-sm text-neutral-700">Updating the list…</p>}
   {loadError && <div role="alert" className="mb-4 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-800"><p>{loadError} The previous list and your draft are retained; actions are paused until the list is refreshed.</p><button type="button" disabled={refreshing} onClick={fetchData} className="mt-2 min-h-11 font-semibold underline">Retry list</button></div>}
   {mutationError && <div role="alert" className="mb-4 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-800"><p>{mutationError}</p><button type="button" disabled={refreshing || Boolean(activeMutation)} onClick={fetchData} className="mt-2 min-h-11 font-semibold underline">Check latest list</button></div>}
   {unconfirmed && <section aria-label="Unconfirmed operation" className="mb-4 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950"><p>An earlier {unconfirmed.operation.replaceAll('_', ' ')} request is not confirmed. Changes are paused to avoid repeating an unconfirmed request. Refresh the list and contact support before repeating it.</p><div className="mt-2 flex flex-wrap gap-3"><button type="button" disabled={refreshing || Boolean(activeMutation)} onClick={fetchData} className="min-h-11 font-semibold underline">Refresh latest list</button><SupportLink subject="Verify an unconfirmed event-tool operation" className="inline-flex min-h-11 items-center font-semibold underline">Contact support</SupportLink></div></section>}
   {notice && <p role="status" className="mb-4 rounded-xl border border-brand-200 bg-brand-50 p-4 text-sm text-brand-900">{notice}</p>}

   {showForm && (
    <form onSubmit={handleCreate} className="card p-4 sm:p-6 mb-6"><fieldset className="min-w-0" disabled={mutationsLocked}>
     <h3 className="font-semibold text-neutral-900 mb-4">{editingCode ? 'Edit promo code' : 'Create promo code'}</h3>
     <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
      <div>
       <label htmlFor="promo-code" className="block text-sm font-medium text-neutral-700 mb-1.5">Code</label>
       <input id="promo-code" value={form.code} onChange={e => setForm({...form, code: e.target.value.toUpperCase()})} className="input min-w-0 max-w-full uppercase" placeholder="SUMMER20" required />
      </div>
      <div>
       <label htmlFor="promo-discount_type" className="block text-sm font-medium text-neutral-700 mb-1.5">Discount type</label>
       <select id="promo-discount_type" value={form.discount_type} onChange={e => setForm({...form, discount_type: e.target.value})} className="input min-w-0 max-w-full">
        <option value="percentage">Percentage (%)</option>
        <option value="fixed">Fixed discount ($)</option>
       </select>
      </div>
      <div>
       <label htmlFor="promo-discount_value" className="block text-sm font-medium text-neutral-700 mb-1.5">
        {form.discount_type === 'percentage' ? 'Discount (%)' : 'Discount ($)'}
       </label>
       <input type="number" min={form.discount_type === 'percentage' ? 1 : 0.01} max={form.discount_type === 'percentage' ? 100 : undefined} step={form.discount_type === 'percentage' ? 1 : 0.01} id="promo-discount_value" value={form.discount_value} onChange={e => setForm({...form, discount_value: e.target.value})} className="input min-w-0 max-w-full" placeholder={form.discount_type === 'percentage' ? '20' : '5.00'} required />
      </div>
      <div>
       <label htmlFor="promo-max_uses" className="block text-sm font-medium text-neutral-700 mb-1.5">Maximum uses <span className="text-content-muted font-normal">(optional)</span></label>
       <input type="number" id="promo-max_uses" value={form.max_uses} onChange={e => setForm({...form, max_uses: e.target.value})} className="input min-w-0 max-w-full" placeholder="Unlimited" />
      </div>
      <div className="sm:col-span-2">
       <label htmlFor="promo-expires_at" className="block text-sm font-medium text-neutral-700 mb-1.5">Expires ({event.timezone === 'Pacific/Guam' || !event.timezone ? 'Guam time' : event.timezone}) <span className="text-content-muted font-normal">(optional)</span></label>
       <input type="datetime-local" id="promo-expires_at" value={form.expires_at} onChange={e => setForm({...form, expires_at: e.target.value})} className="input min-w-0 max-w-full" />
      </div>
     </div>
     <div className="flex flex-wrap gap-3 mt-5">
      <button type="submit" disabled={saving} className="btn-primary text-sm !py-2.5">{saving ? 'Saving…' : editingCode ? 'Save changes' : 'Create code'}</button>
      <button type="button" onClick={() => setShowForm(false)} className="btn-secondary text-sm !py-2.5">Cancel</button>
     </div>
    </fieldset></form>
   )}

   {codes.length === 0 ? (
    <div className="card px-4 py-8 sm:p-12 text-center">
     <Tag className="w-10 h-10 text-neutral-300 mx-auto mb-3" />
     <p className="text-content-muted">No promo codes yet</p>
     <p className="text-sm text-content-muted mt-1">Create a code to offer discounts</p>
    </div>
   ) : (
    <div className="space-y-3">
     {codes.map(pc => (
      <div key={pc.id} className="card p-4 sm:p-5 flex min-w-0 flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
       <div className="flex min-w-0 flex-1 items-start gap-3 sm:gap-4">
        <div className={`w-10 h-10 shrink-0 rounded-xl flex items-center justify-center ${pc.active ? 'bg-emerald-50' : 'bg-neutral-100'}`}>
         <Tag className={`w-5 h-5 ${pc.active ? 'text-emerald-700' : 'text-neutral-600'}`} />
        </div>
        <div className="min-w-0 flex-1">
         <p className="font-mono font-semibold text-neutral-900 [overflow-wrap:anywhere]">{pc.code}</p>
         <p className="text-sm text-content-muted [overflow-wrap:anywhere]">
          {pc.discount_type === 'percentage' ? `${pc.discount_value}% off` : `$${promoDiscountFromApi(pc.discount_value, pc.discount_type)} off`}
          {' '}&middot; {pc.current_uses}{pc.max_uses ? `/${pc.max_uses}` : ''} used
          {pc.expires_at && ` · Expires ${formatEventDateTime(pc.expires_at, event.timezone)}`}
         </p>
        </div>
       </div>
       <div className="flex shrink-0 items-center gap-2 self-end sm:self-center">
        <button type="button" disabled={mutationsLocked} onClick={() => editCode(pc)} aria-label={`Edit promo code ${pc.code}`} className="inline-flex min-h-11 min-w-11 items-center justify-center rounded-xl hover:bg-neutral-100 focus-visible:ring-2 focus-visible:ring-brand-700"><Pencil className="h-4 w-4" /></button>
        <button
         disabled={mutationsLocked} onClick={() => toggleActive(pc)}
         className="inline-flex min-h-11 min-w-11 items-center justify-center rounded-xl hover:bg-neutral-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-700 focus-visible:ring-offset-2 disabled:opacity-50 transition-colors"
         title={pc.active ? 'Deactivate' : 'Activate'}
         aria-label={pc.active ? `Deactivate promo code ${pc.code}` : `Activate promo code ${pc.code}`}
        >
         {pc.active ? <ToggleRight className="w-5 h-5 text-emerald-700" /> : <ToggleLeft className="w-5 h-5 text-neutral-600" />}
        </button>
        <button
         disabled={mutationsLocked} onClick={() => deleteCode(pc)}
         className="inline-flex min-h-11 min-w-11 items-center justify-center rounded-xl text-red-700 hover:bg-red-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-700 focus-visible:ring-offset-2 disabled:opacity-50 transition-colors"
         aria-label={`Delete promo code ${pc.code}`}
        >
         <Trash2 className="w-4 h-4" />
        </button>
       </div>
      </div>
     ))}
    </div>
   )}
  </div></EventWorkspace>
 )
}

export default function PromoCodesPage() {
  const { id: eventId } = useParams()
  const identity = useOrganizerIdentity()
  const visit = useOrganizerPageVisit(`/dashboard/events/${eventId}/promo-codes`)
  if (!visit.active) return null
  if (!identity.ready) return <p className="p-6" role="status">Preparing your account…</p>
  return <PromoCodesSession key={`${identity.accountKey}:${identity.organizationId}:${eventId}:${visit.generation}`} eventId={eventId} identity={identity} />
}
