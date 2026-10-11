import EventWorkspace from '../../components/EventWorkspace'
import Dialog from '../../components/Dialog'
import { useState, useEffect, useCallback, useRef } from 'react'
import { Link, useParams } from 'react-router-dom'
import { Plus, Users, UserPlus, Check, Loader2, Trash2 } from 'lucide-react'
import apiClient from '../../api/client'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import { supportMailto } from '../../utils/supportContact'

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

function GuestListSession({ eventId, identity }) {
  const { current, beginRequest } = useOrganizerRequests(identity, `/dashboard/events/${eventId}/guest-list`)
  const pendingLoad = useRef(null)
  const loadGeneration = useRef(0)
  const mutationBusy = useRef(false)
  const storageKey = `hafapass:pending-guest-list:${identity.owner}:${identity.organizationId}:${eventId}`
  const [unconfirmed, setUnconfirmed] = useState(() => readPendingOperation(storageKey))
  const unconfirmedRef = useRef(unconfirmed)
  const [event, setEvent] = useState(null)
  const [refreshing, setRefreshing] = useState(false)
  const [loadError, setLoadError] = useState('')
  const [mutationError, setMutationError] = useState('')
  const [notice, setNotice] = useState('')
  const [activeMutation, setActiveMutation] = useState(null)
  const [confirmation, setConfirmation] = useState(null)
  const [entries, setEntries] = useState([])
  const [ticketTypes, setTicketTypes] = useState([])
  const [loading, setLoading] = useState(true)
  const [showForm, setShowForm] = useState(false)
  const [form, setForm] = useState({ guest_name: '', guest_email: '', guest_phone: '', notes: '', quantity: 1, ticket_type_id: '' })
  const saving = activeMutation === 'add_guest'
  const clearPrivateState = useCallback(() => {
    setConfirmation(null); setEvent(null); setEntries([]); setTicketTypes([]); setShowForm(false)
    setForm({ guest_name: '', guest_email: '', guest_phone: '', notes: '', quantity: 1, ticket_type_id: '' })
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
      const [entriesResponse, eventResponse] = await Promise.all([
        apiClient.get(`/organizer/events/${eventId}/guest_list`, request.config),
        apiClient.get(`/organizer/events/${eventId}`, request.config),
      ])
      if (!canApply()) return
      if (eventResponse.data.permissions?.manage_attendees !== true) {
        clearPrivateState(); setEvent(eventResponse.data); return
      }
      setEvent(eventResponse.data)
      const rows = entriesResponse.data.guest_list || entriesResponse.data
      setEntries(Array.isArray(rows) ? rows : [])
      const ticketTypes = eventResponse.data.ticket_types || []
      setTicketTypes(ticketTypes)
      setForm(draft => draft.ticket_type_id || !ticketTypes.length ? draft : { ...draft, ticket_type_id: ticketTypes[0].id })
    } catch (error) {
      if (!canApply()) return
      if ([401, 403, 404].includes(error.response?.status)) clearPrivateState()
      setLoadError(errorMessage(error, 'The guest list could not be loaded.'))
    } finally {
      if (canApply()) { setLoading(false); setRefreshing(false) }
      request.release()
    }
  }, [beginRequest, clearPrivateState, eventId])
  useEffect(() => { fetchData() }, [fetchData])
  const canManage = event?.permissions?.manage_attendees === true
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
    const payload = { ...form }
    performMutation('add_guest', config => apiClient.post(`/organizer/events/${eventId}/guest_list`, payload, config), () => {
      setForm(draft => ({ guest_name: '', guest_email: '', guest_phone: '', notes: '', quantity: 1, ticket_type_id: draft.ticket_type_id }))
      setShowForm(false); setNotice('Guest added. Any notification is handled separately.')
    })
  }
  const handleRedeem = entry => {
    askConfirmation('redeem_guest', `Redeem ${entry.quantity} ticket(s) for ${entry.guest_name}?`, 'Redeem tickets', config => apiClient.post(`/organizer/events/${eventId}/guest_list/${entry.id}/redeem`, {}, config), () => setNotice('Guest tickets created.'))
  }
  const handleDelete = entry => {
    askConfirmation('remove_guest', `Remove ${entry.guest_name} from guest list?`, 'Remove guest', config => apiClient.delete(`/organizer/events/${eventId}/guest_list/${entry.id}`, config), () => setNotice('Guest removed.'))
  }
  if (loading) return <div className="flex justify-center py-20" role="status"><Loader2 className="w-8 h-8 text-brand-500 animate-spin" /> Loading guest list…</div>
  if (!event) return <main className="mx-auto max-w-3xl px-4 py-8">
    <Link to="/dashboard" className="inline-flex min-h-11 items-center font-medium text-brand-800">All events</Link>
    <h1 className="mt-3 text-2xl font-bold">Guest List</h1>
    <p role="alert" className="mt-4 text-sm text-red-800">{loadError || mutationError || 'Event access is unavailable.'}</p>
    <button type="button" disabled={refreshing} onClick={fetchData} className="btn-secondary mt-3">Retry guest list</button>
  </main>
  if (!canManage) return <EventWorkspace eventId={eventId} event={event}><p role="status" className="text-neutral-700">Your event access does not include this tool.</p></EventWorkspace>
 const unredeemed = entries.filter(e => !e.redeemed)
 const redeemed = entries.filter(e => e.redeemed)

 return (
  <EventWorkspace eventId={eventId} event={event}><div className="min-w-0 w-full max-w-4xl mx-auto">

   <div className="flex flex-col items-start gap-4 mb-8 sm:flex-row sm:items-center sm:justify-between">
    <div>
     <h2 className="text-2xl font-bold tracking-tight text-neutral-900">Guest List</h2>
     <p className="text-sm text-neutral-500 mt-1">{unredeemed.length} pending, {redeemed.length} redeemed</p>
    </div>
    <button disabled={mutationsLocked} onClick={() => setShowForm(!showForm)} className="btn-primary text-sm !py-2.5 gap-1.5">
     <UserPlus className="w-4 h-4" /> Add Guest
    </button>
   </div>


   {confirmation && <Dialog labelledBy="guest-list-confirm-title" onClose={() => setConfirmation(null)}>
     <h3 id="guest-list-confirm-title" className="text-lg font-semibold text-neutral-950">Confirm action</h3>
     <p className="mt-3 break-words text-sm text-neutral-700">{confirmation.message}</p>
     <div className="mt-5 flex flex-wrap gap-3"><button type="button" className="btn-secondary" onClick={() => setConfirmation(null)}>Cancel</button><button type="button" className="btn-primary" disabled={mutationsLocked} onClick={confirmOperation}>{confirmation.label}</button></div>
   </Dialog>}
   {refreshing && <p role="status" className="mb-4 text-sm text-neutral-700">Updating the list…</p>}
   {loadError && <div role="alert" className="mb-4 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-800"><p>{loadError} The previous list and your draft are retained; actions are paused until the list is refreshed.</p><button type="button" disabled={refreshing} onClick={fetchData} className="mt-2 min-h-11 font-semibold underline">Retry list</button></div>}
   {mutationError && <div role="alert" className="mb-4 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-800"><p>{mutationError}</p><button type="button" disabled={refreshing || Boolean(activeMutation)} onClick={fetchData} className="mt-2 min-h-11 font-semibold underline">Check latest list</button></div>}
   {unconfirmed && <section aria-label="Unconfirmed operation" className="mb-4 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950"><p>An earlier {unconfirmed.operation.replaceAll('_', ' ')} request is not confirmed. Changes are paused to avoid repeating an unconfirmed request. Refresh the list and contact support before repeating it.</p><div className="mt-2 flex flex-wrap gap-3"><button type="button" disabled={refreshing || Boolean(activeMutation)} onClick={fetchData} className="min-h-11 font-semibold underline">Refresh latest list</button><a className="inline-flex min-h-11 items-center font-semibold underline" href={supportMailto('Verify an unconfirmed event-tool operation')}>Contact support</a></div></section>}
   {notice && <p role="status" className="mb-4 rounded-xl border border-brand-200 bg-brand-50 p-4 text-sm text-brand-900">{notice}</p>}

   {showForm && (
    <form onSubmit={handleCreate} className="card p-4 sm:p-6 mb-6"><fieldset className="min-w-0" disabled={mutationsLocked}>
     <h3 className="font-semibold text-neutral-900 mb-4">Add to Guest List</h3>
     <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
      <div>
       <label htmlFor="guest-guest_name" className="block text-sm font-medium text-neutral-700 mb-1.5">Name</label>
       <input id="guest-guest_name" value={form.guest_name} onChange={e => setForm({...form, guest_name: e.target.value})} className="input min-w-0 max-w-full" placeholder="Guest name" required />
      </div>
      <div>
       <label htmlFor="guest-guest_email" className="block text-sm font-medium text-neutral-700 mb-1.5">Email <span className="text-content-muted font-normal">(optional)</span></label>
       <input type="email" id="guest-guest_email" value={form.guest_email} onChange={e => setForm({...form, guest_email: e.target.value})} className="input min-w-0 max-w-full" placeholder="guest@email.com" />
      </div>
      <div>
       <label htmlFor="guest-ticket_type_id" className="block text-sm font-medium text-neutral-700 mb-1.5">Ticket Type</label>
       <select id="guest-ticket_type_id" value={form.ticket_type_id} onChange={e => setForm({...form, ticket_type_id: parseInt(e.target.value, 10) || ''})} className="input min-w-0 max-w-full">
        {ticketTypes.map(tt => <option key={tt.id} value={tt.id}>{tt.name}</option>)}
       </select>
      </div>
      <div>
       <label htmlFor="guest-quantity" className="block text-sm font-medium text-neutral-700 mb-1.5">Quantity</label>
       <input type="number" min="1" max="10" id="guest-quantity" value={form.quantity} onChange={e => setForm({...form, quantity: parseInt(e.target.value, 10) || 1})} className="input min-w-0 max-w-full" />
      </div>
      <div className="sm:col-span-2">
       <label htmlFor="guest-notes" className="block text-sm font-medium text-neutral-700 mb-1.5">Notes <span className="text-content-muted font-normal">(optional)</span></label>
       <input id="guest-notes" value={form.notes} onChange={e => setForm({...form, notes: e.target.value})} className="input min-w-0 max-w-full" placeholder="VIP, photographer, etc." />
      </div>
     </div>
     <div className="flex flex-wrap gap-3 mt-5">
      <button type="submit" disabled={saving} className="btn-primary text-sm !py-2.5">{saving ? 'Adding...' : 'Add Guest'}</button>
      <button type="button" onClick={() => setShowForm(false)} className="btn-secondary text-sm !py-2.5">Cancel</button>
     </div>
    </fieldset></form>
   )}

   {entries.length === 0 ? (
    <div className="card px-4 py-8 sm:p-12 text-center">
     <Users className="w-10 h-10 text-neutral-300 mx-auto mb-3" />
     <p className="text-content-muted">No guests added yet</p>
    </div>
   ) : (
    <div className="space-y-3">
     {unredeemed.map(entry => (
      <div key={entry.id} className="card p-4 sm:p-5 flex min-w-0 flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
       <div className="flex min-w-0 flex-1 items-start gap-3 sm:gap-4">
        <div className="w-10 h-10 shrink-0 rounded-xl bg-accent-50 flex items-center justify-center">
         <Users className="w-5 h-5 text-accent-700" />
        </div>
        <div className="min-w-0 flex-1">
         <p className="font-medium text-neutral-900 [overflow-wrap:anywhere]">{entry.guest_name}</p>
         <p className="text-sm text-content-muted [overflow-wrap:anywhere]">
          {entry.ticket_type.name} &times; {entry.quantity}
          {entry.guest_email && ` · ${entry.guest_email}`}
          {entry.notes && ` · ${entry.notes}`}
         </p>
        </div>
       </div>
       <div className="flex shrink-0 items-center gap-2 self-end sm:self-center">
        <button disabled={mutationsLocked} onClick={() => handleRedeem(entry)} className="btn-primary text-sm !px-3 gap-1.5">
         <Check className="w-3 h-3" /> Redeem
        </button>
        <button disabled={mutationsLocked} aria-label={`Remove guest ${entry.guest_name}`} onClick={() => handleDelete(entry)} className="inline-flex min-h-11 min-w-11 items-center justify-center rounded-xl text-red-700 hover:bg-red-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-700 focus-visible:ring-offset-2 disabled:opacity-50 transition-colors">
         <Trash2 className="w-4 h-4" />
        </button>
       </div>
      </div>
     ))}
     {redeemed.length > 0 && (
      <>
       <h3 className="text-sm font-medium text-content-muted pt-4">Redeemed</h3>
       {redeemed.map(entry => (
        <div key={entry.id} className="card p-4 sm:p-5 min-w-0 bg-neutral-50">
         <div className="flex min-w-0 flex-1 items-start gap-3 sm:gap-4">
          <div className="w-10 h-10 shrink-0 rounded-xl bg-emerald-50 flex items-center justify-center">
           <Check className="w-5 h-5 text-emerald-700" />
          </div>
          <div className="min-w-0 flex-1">
           <p className="font-medium text-neutral-900 [overflow-wrap:anywhere]">{entry.guest_name}</p>
           <p className="text-sm text-content-muted [overflow-wrap:anywhere]">{entry.ticket_type.name} &times; {entry.quantity} &middot; Order #{entry.order_id}</p>
          </div>
         </div>
        </div>
       ))}
      </>
     )}
    </div>
   )}
  </div></EventWorkspace>
 )
}

export default function GuestListPage() {
  const { id: eventId } = useParams()
  const identity = useOrganizerIdentity()
  const visit = useOrganizerPageVisit(`/dashboard/events/${eventId}/guest-list`)
  if (!visit.active) return null
  if (!identity.ready) return <p className="p-6" role="status">Preparing your account…</p>
  return <GuestListSession key={`${identity.accountKey}:${identity.organizationId}:${eventId}:${visit.generation}`} eventId={eventId} identity={identity} />
}
