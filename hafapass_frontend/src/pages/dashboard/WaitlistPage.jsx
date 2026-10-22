import EventWorkspace from '../../components/EventWorkspace'
import Dialog from '../../components/Dialog'
import { useState, useEffect, useCallback, useRef } from 'react'
import { Link, useParams } from 'react-router-dom'
import { Bell, Trash2, Loader2, ClipboardList, Send } from 'lucide-react'
import apiClient from '../../api/client'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import SupportLink from '../../components/SupportLink'

const STATUS_COLORS = {
  waiting: 'bg-amber-50 text-amber-700',
  notified: 'bg-blue-50 text-blue-700',
  offered: 'bg-indigo-50 text-indigo-700',
  converted: 'bg-emerald-50 text-emerald-700',
  expired: 'bg-neutral-100 text-content-muted',
  cancelled: 'bg-red-50 text-red-600',
}

const STATUS_LABELS = {
  waiting: 'Waiting',
  notified: 'Notified',
  offered: 'Offered',
  converted: 'Converted',
  expired: 'Expired',
  cancelled: 'Cancelled',
}
const statusLabel = status => STATUS_LABELS[status] || (status ? status.charAt(0).toUpperCase() + status.slice(1).replaceAll('_', ' ') : '')
const FILTER_COUNT_KEYS = { waiting: 'total_waiting', notified: 'total_notified', expired: 'total_expired', converted: 'total_converted' }

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

function WaitlistSession({ eventId, identity }) {
  const { current, beginRequest } = useOrganizerRequests(identity, `/dashboard/events/${eventId}/waitlist`)
  const pendingLoad = useRef(null)
  const loadGeneration = useRef(0)
  const mutationBusy = useRef(false)
  const fetchDataRef = useRef(null)
  const storageKey = `hafapass:pending-waitlist:${identity.owner}:${identity.organizationId}:${eventId}`
  const [unconfirmed, setUnconfirmed] = useState(() => readPendingOperation(storageKey))
  const unconfirmedRef = useRef(unconfirmed)
  const [event, setEvent] = useState(null)
  const [refreshing, setRefreshing] = useState(false)
  const [loadError, setLoadError] = useState('')
  const [mutationError, setMutationError] = useState('')
  const [notice, setNotice] = useState('')
  const [addressReady, setAddressReady] = useState(true)
  const [activeMutation, setActiveMutation] = useState(null)
  const [confirmation, setConfirmation] = useState(null)
  const [entries, setEntries] = useState([])
  const [stats, setStats] = useState({})
  const [loading, setLoading] = useState(true)
  const [filter, setFilter] = useState('')
  const [notifyCount, setNotifyCount] = useState('1')
  const validNotifyCount = notifyCount !== '' && Number.isInteger(Number(notifyCount))
    && Number(notifyCount) >= 1 && Number(notifyCount) <= 50
  const notifying = activeMutation === 'notify_next'
  const nobodyWaiting = !(Number(stats.total_waiting) > 0)
  const clearPrivateState = useCallback(() => {
    setConfirmation(null); setEvent(null); setEntries([]); setStats({}); setNotifyCount(1)
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
        apiClient.get(`/organizer/events/${eventId}/waitlist`, { ...request.config, params: filter ? { status: filter } : {} }),
        apiClient.get(`/organizer/events/${eventId}`, request.config),
      ])
      if (!canApply()) return
      if (eventResponse.data.permissions?.manage_attendees !== true) {
        clearPrivateState(); setEvent(eventResponse.data); return
      }
      setEvent(eventResponse.data)
      setEntries(entriesResponse.data.waitlist || [])
      setStats(entriesResponse.data.stats || {})
      setAddressReady(entriesResponse.data.marketing_address_ready !== false)
    } catch (error) {
      if (!canApply()) return
      if ([401, 403, 404].includes(error.response?.status)) clearPrivateState()
      setLoadError(errorMessage(error, 'The waitlist could not be loaded.'))
    } finally {
      if (canApply()) { setLoading(false); setRefreshing(false) }
      request.release()
    }
  }, [beginRequest, clearPrivateState, eventId, filter])
  fetchDataRef.current = fetchData
  useEffect(() => { fetchData() }, [fetchData])
  const canManage = event?.permissions?.manage_attendees === true
  const mutationsLocked = !canManage || refreshing || Boolean(loadError) || Boolean(activeMutation) || Boolean(unconfirmed)

  const askConfirmation = (operation, message, label, send, complete) => {
    if (!current() || (operation !== 'remove_entry' && !addressReady) || mutationsLocked || mutationBusy.current) return
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
      await fetchDataRef.current()
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

  const handleNotify = entry => {
    askConfirmation('notify_entry', `Notify ${entry.name || entry.email} that tickets are available?`, 'Send notification', config => apiClient.post(`/organizer/events/${eventId}/waitlist/${entry.id}/notify`, {}, config), () => setNotice('Notification request recorded. Delivery is handled separately.'))
  }
  const handleRetryUnconfirmed = entry => {
    askConfirmation('retry_unconfirmed', `Delivery to ${entry.name || entry.email} is unconfirmed and may already have arrived. Check with the buyer before sending another email. Send it again?`, entry.status === 'offered' ? 'Retry offer email' : 'Retry alert', config => apiClient.post(`/organizer/events/${eventId}/waitlist/${entry.id}/retry_unconfirmed`, {}, config), () => setNotice('A new email was requested. Delivery is handled separately.'))
  }
  const handleOffer = entry => {
    askConfirmation('offer_tickets', `Reserve inventory and send a checkout offer to ${entry.name || entry.email}?`, 'Create ticket offer', config => apiClient.post(`/organizer/events/${eventId}/waitlist/${entry.id}/offer`, {}, config), () => setNotice('Ticket offer created. Delivery is handled separately.'))
  }
  const handleNotifyNext = () => {
    if (!validNotifyCount) return
    const count = Number(notifyCount)
    const payload = { count }
    askConfirmation('notify_next', `Notify the next ${count} people on the waitlist?`, 'Send next notifications', config => apiClient.post(`/organizer/events/${eventId}/waitlist/notify_next`, payload, config), data => setNotice(Number.isInteger(data.count) ? `Notification requests recorded for ${data.count} people. Delivery is handled separately.` : 'Notification request recorded. Delivery is handled separately.'))
  }
  const handleRemove = entry => {
    askConfirmation('remove_entry', `Remove ${entry.name || entry.email} from the waitlist?`, 'Remove entry', config => apiClient.delete(`/organizer/events/${eventId}/waitlist/${entry.id}`, config), () => setNotice('Waitlist entry removed.'))
  }
  const formatDate = date => new Date(date).toLocaleDateString('en-US', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })
  if (loading) return <div className="flex justify-center py-20" role="status"><Loader2 className="w-8 h-8 text-brand-500 animate-spin" /> Loading waitlist…</div>
  if (!event) return <main className="mx-auto max-w-3xl px-4 py-8">
    <Link to="/dashboard" className="inline-flex min-h-11 items-center font-medium text-brand-800">All events</Link>
    <h1 className="mt-3 text-2xl font-bold">Waitlist</h1>
    <p role="alert" className="mt-4 text-sm text-red-800">{loadError || mutationError || 'Event access is unavailable.'}</p>
    <button type="button" disabled={refreshing} onClick={fetchData} className="btn-secondary mt-3">Retry waitlist</button>
  </main>
  if (!canManage) return <EventWorkspace eventId={eventId} event={event}><p role="status" className="text-neutral-700">Your event access does not include this tool.</p></EventWorkspace>
  return (
    <EventWorkspace eventId={eventId} event={event}><div className="min-w-0 w-full max-w-5xl mx-auto">
      {!addressReady && <div id="waitlist-address-required" role="alert" className="mb-5 rounded-xl border border-amber-300 bg-amber-50 p-4 text-sm text-amber-950">The organization owner must add and certify the business mailing address in the Marketing postal address section of <Link to="/dashboard/settings" className="font-semibold underline">Settings</Link> before sending waitlist alerts or offers.</div>}

      <div className="flex flex-col items-start gap-4 mb-6 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h2 className="text-2xl font-bold tracking-tight text-neutral-900 flex items-center gap-2">
            <ClipboardList className="w-6 h-6 text-brand-500" /> Waitlist
          </h2>
          <p className="text-sm text-content-muted mt-1">
            {stats.total_waiting || 0} waiting, {stats.total_notified || 0} notified, {stats.total_converted || 0} converted
          </p>
        </div>
        <div className="w-full sm:w-auto">
          <label htmlFor="waitlist-notify-count" className="mb-1.5 block text-sm font-medium text-neutral-700">People to notify</label>
          <div className="flex items-center gap-2">
            <input
              id="waitlist-notify-count"
              disabled={mutationsLocked}
              type="number"
              min={1}
              max={50}
              inputMode="numeric"
              value={notifyCount}
              onChange={(e) => setNotifyCount(e.target.value)}
              aria-invalid={!validNotifyCount}
              aria-describedby="waitlist-notify-count-help"
              className="input !w-20 min-h-11 shrink-0 text-center text-base"
            />
            <button onClick={handleNotifyNext} disabled={mutationsLocked || !addressReady || !validNotifyCount || nobodyWaiting} aria-describedby={!addressReady ? 'waitlist-address-required' : nobodyWaiting ? 'waitlist-notify-empty' : undefined} className="btn-primary min-w-0 flex-1 text-sm !px-3 !py-2.5 gap-1.5 sm:flex-none">
              {notifying ? <Loader2 className="w-4 h-4 animate-spin" /> : <Send className="w-4 h-4" />}
              Notify Next
            </button>
          </div>
          <p id="waitlist-notify-count-help" className={`mt-1.5 text-sm ${validNotifyCount ? 'text-content-muted' : 'text-red-700'}`}>
            {validNotifyCount ? '1–50 people' : 'Enter a whole number from 1 to 50.'}
          </p>
          {nobodyWaiting && <p id="waitlist-notify-empty" className="mt-1 text-sm text-content-muted">No one is waiting to be notified.</p>}
        </div>
      </div>


   {confirmation && <Dialog labelledBy="waitlist-confirm-title" onClose={() => setConfirmation(null)}>
     <h3 id="waitlist-confirm-title" className="text-lg font-semibold text-neutral-950">Confirm action</h3>
     <p className="mt-3 break-words text-sm text-neutral-700">{confirmation.message}</p>
     <div className="mt-5 flex flex-wrap gap-3"><button type="button" className="btn-secondary" onClick={() => setConfirmation(null)}>Cancel</button><button type="button" className="btn-primary" disabled={mutationsLocked} onClick={confirmOperation}>{confirmation.label}</button></div>
   </Dialog>}
   {refreshing && <p role="status" className="mb-4 text-sm text-neutral-700">Updating the list…</p>}
   {loadError && <div role="alert" className="mb-4 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-800"><p>{loadError} The previous list and your draft are retained; actions are paused until the list is refreshed.</p><button type="button" disabled={refreshing} onClick={fetchData} className="mt-2 min-h-11 font-semibold underline">Retry list</button></div>}
   {mutationError && <div role="alert" className="mb-4 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-800"><p>{mutationError}</p><button type="button" disabled={refreshing || Boolean(activeMutation)} onClick={fetchData} className="mt-2 min-h-11 font-semibold underline">Check latest list</button></div>}
   {unconfirmed && <section aria-label="Unconfirmed operation" className="mb-4 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950"><p>An earlier {unconfirmed.operation.replaceAll('_', ' ')} request is not confirmed. Changes are paused to avoid repeating an unconfirmed request. Refresh the list and contact support before repeating it.</p><div className="mt-2 flex flex-wrap gap-3"><button type="button" disabled={refreshing || Boolean(activeMutation)} onClick={fetchData} className="min-h-11 font-semibold underline">Refresh latest list</button><SupportLink subject="Verify an unconfirmed event-tool operation" className="inline-flex min-h-11 items-center font-semibold underline">Contact support</SupportLink></div></section>}
   {notice && <p role="status" className="mb-4 rounded-xl border border-brand-200 bg-brand-50 p-4 text-sm text-brand-900">{notice}</p>}

      {/* Filters */}
      <div className="mb-4 flex min-w-0 max-w-full flex-wrap gap-2" role="group" aria-label="Filter by status">
        {['', 'waiting', 'notified', 'expired', 'converted'].map(s => (
          <button
            key={s}
            aria-pressed={filter === s}
            onClick={() => setFilter(s)}
            className={`min-h-11 min-w-11 px-3 py-2 rounded-lg text-sm font-medium focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-700 focus-visible:ring-offset-2 transition-colors ${
              filter === s ? 'bg-brand-700 text-white' : 'bg-neutral-100 text-neutral-600 hover:bg-neutral-200'
            }`}
          >
            {s ? statusLabel(s) : 'All'}
            {s && Number.isInteger(stats[FILTER_COUNT_KEYS[s]]) && <>{' '}<span className="tabular-nums">({stats[FILTER_COUNT_KEYS[s]]})</span></>}
          </button>
        ))}
      </div>

      {/* Table */}
      {entries.length === 0 ? (
        <div className="text-center py-12 text-content-muted">No waitlist entries found.</div>
      ) : (
        <div className="max-w-full overflow-x-auto rounded-lg focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-700" role="region" aria-label="Waitlist entries" tabIndex={0}>
          <table className="w-full min-w-[48rem] text-sm">
            <thead>
              <tr className="border-b border-neutral-200 text-left text-neutral-500">
                <th className="pb-3 font-medium">#</th>
                <th className="pb-3 font-medium">Name</th>
                <th className="pb-3 font-medium">Email</th>
                <th className="pb-3 font-medium">Ticket Type</th>
                <th className="pb-3 font-medium">Qty</th>
                <th className="pb-3 font-medium">Status</th>
                <th className="pb-3 font-medium">Joined</th>
                <th className="pb-3 font-medium">Actions</th>
              </tr>
            </thead>
            <tbody>
              {entries.map(entry => (
                <tr key={entry.id} className="border-b border-neutral-100 hover:bg-neutral-50">
                  <td className="py-3 text-neutral-900 font-medium">{entry.position}</td>
                  <td className="py-3 pr-4 max-w-48 text-neutral-900 [overflow-wrap:anywhere]">{entry.name || '—'}</td>
                  <td className="py-3 pr-4 max-w-56 text-neutral-600 [overflow-wrap:anywhere]">{entry.email}</td>
                  <td className="py-3 pr-4 max-w-48 text-neutral-600 [overflow-wrap:anywhere]">{entry.ticket_type?.name || 'Any'}</td>
                  <td className="py-3 text-neutral-600">{entry.quantity}</td>
                  <td className="py-3">
                    <span className={`inline-flex px-2 py-0.5 rounded-full text-xs font-medium ${STATUS_COLORS[entry.status] || ''}`}>
                      {statusLabel(entry.status)}
                    </span>
                  </td>
                  <td className="py-3 text-content-muted text-xs">{formatDate(entry.created_at)}</td>
                  <td className="py-3">
                    <div className="flex items-center gap-1">
                      {entry.status === 'waiting' && (
                        <button disabled={mutationsLocked || !addressReady} aria-describedby={!addressReady ? 'waitlist-address-required' : undefined} onClick={() => handleOffer(entry)} className="inline-flex min-h-11 min-w-11 items-center justify-center rounded-lg px-3 text-sm font-semibold text-emerald-700 hover:bg-emerald-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-700 focus-visible:ring-offset-2 disabled:opacity-50" title="Reserve tickets and send offer">Offer</button>
                      )}
                      {['notified', 'offered'].includes(entry.status) && entry.delivery_failure?.startsWith('Delivery unconfirmed') && (
                        <button disabled={mutationsLocked || !addressReady} onClick={() => handleRetryUnconfirmed(entry)} className="inline-flex min-h-11 items-center justify-center rounded-lg px-3 text-sm font-semibold text-blue-700 hover:bg-blue-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-700 focus-visible:ring-offset-2 disabled:opacity-50">{entry.status === 'offered' ? 'Retry offer email' : 'Retry alert'}</button>
                      )}
                      {entry.status === 'waiting' && (
                        <button
                          disabled={mutationsLocked || !addressReady} aria-describedby={!addressReady ? 'waitlist-address-required' : undefined} aria-label={`Notify ${entry.name || entry.email}`} onClick={() => handleNotify(entry)}
                          className="inline-flex min-h-11 min-w-11 items-center justify-center rounded-lg text-blue-700 hover:bg-blue-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-700 focus-visible:ring-offset-2 disabled:opacity-50 transition-colors"
                          title="Notify"
                        >
                          <Bell className="w-4 h-4" />
                        </button>
                      )}
                      <button
                        disabled={mutationsLocked} aria-label={`Remove ${entry.name || entry.email}`} onClick={() => handleRemove(entry)}
                        className="inline-flex min-h-11 min-w-11 items-center justify-center rounded-lg text-red-700 hover:bg-red-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-700 focus-visible:ring-offset-2 disabled:opacity-50 transition-colors"
                        title="Remove"
                      >
                        <Trash2 className="w-4 h-4" />
                      </button>
                    </div>
                    {entry.delivery_failure && <p role="alert" className="mt-1 max-w-52 text-xs text-red-700 [overflow-wrap:anywhere]">{entry.delivery_failure.startsWith('Delivery unconfirmed') ? entry.delivery_failure : `Couldn't send: ${entry.delivery_failure}.`} {entry.status === 'waiting' ? 'Retry with Offer or Notify.' : ''}</p>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div></EventWorkspace>
  )
}

export default function WaitlistPage() {
  const { id: eventId } = useParams()
  const identity = useOrganizerIdentity()
  const visit = useOrganizerPageVisit(`/dashboard/events/${eventId}/waitlist`)
  if (!visit.active) return null
  if (!identity.ready) return <p className="p-6" role="status">Preparing your account…</p>
  return <WaitlistSession key={`${identity.accountKey}:${identity.organizationId}:${eventId}:${visit.generation}`} eventId={eventId} identity={identity} />
}
