import AdminAccessRecovery from '../../components/AdminAccessRecovery'
import { useState, useEffect, useCallback, useRef } from 'react'
import { Link } from 'react-router-dom'
import { Loader2, Search, Star, ChevronLeft, ChevronRight, ChevronDown } from 'lucide-react'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'
import { usePlatformIdentity, usePlatformVisit, usePlatformRequests } from '../../hooks/usePlatformContext'
import PilotReadinessReviewDialog from '../../components/PilotReadinessReviewDialog'
import PilotValidationReviewDialog from '../../components/PilotValidationReviewDialog'
import EventDayRehearsalReviewDialog from '../../components/EventDayRehearsalReviewDialog'
import LiveMoneyProofReviewDialog from '../../components/LiveMoneyProofReviewDialog'
import LivePilotOperationsDialog from '../../components/LivePilotOperationsDialog'
import PilotCloseoutDialog from '../../components/PilotCloseoutDialog'
import { adminLabel } from './adminLabels'
import EventPolicyHoldDialog from './EventPolicyHoldDialog'
import EventSalesSuspensionDialog from './EventSalesSuspensionDialog'
import CancellationRefundProgress from '../../components/CancellationRefundProgress'
import { POLICY_HOLD_SCOPES } from './adminOperations'

const statuses = ['', 'draft', 'published', 'cancelled', 'completed']
const categories = ['', 'nightlife', 'concert', 'festival', 'dining', 'sports', 'other']

// One compact per-row disclosure keeps the table scannable. The gate dialogs stay
// mounted while it is open, because each dialog lives inside its own trigger.
// The page owns `open` so a list refresh after a gate action keeps the row
// expanded and the closed dialog can return focus to its trigger.
function ReleaseGatesControl({ event, open, onToggle, onComplete, toggleProofCandidate }) {
  const panelId = `release-gates-${event.id}`
  return (
    <div className="min-w-40">
      <button type="button" aria-expanded={open} aria-controls={panelId} aria-label={`Release gates for ${event.title}`} onClick={onToggle}
        className="inline-flex min-h-11 items-center gap-1.5 rounded-full border border-neutral-300 px-3 py-2 text-xs font-semibold text-neutral-700 transition-[background-color,transform] duration-150 ease-out hover:bg-neutral-100 active:scale-[0.97] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus">
        Release gates
        <ChevronDown aria-hidden="true" className={`h-3.5 w-3.5 transition-transform duration-150 ease-out motion-reduce:transition-none ${open ? 'rotate-180' : ''}`} />
      </button>
      {open && <div id={panelId} role="group" aria-label={`Release gate actions for ${event.title}`} className="mt-2 flex flex-col items-start gap-1 border-l-2 border-neutral-200 pl-3">
        <PilotReadinessReviewDialog event={event} onComplete={onComplete} />
        <PilotValidationReviewDialog event={event} onComplete={onComplete} />
        <EventDayRehearsalReviewDialog event={event} onComplete={onComplete} />
        <LiveMoneyProofReviewDialog event={event} onComplete={onComplete} />
        {!event.live_money_proof_candidate && <LivePilotOperationsDialog event={event} onComplete={onComplete} />}
        {!event.live_money_proof_candidate && <PilotCloseoutDialog event={event} onComplete={onComplete} />}
        {event.status === 'draft' && <button type="button" onClick={() => toggleProofCandidate(event)} className="min-h-11 rounded-full border border-neutral-300 px-3 py-2 text-xs font-semibold text-neutral-700 hover:bg-neutral-100">{event.live_money_proof_candidate ? 'Remove proof-candidate flag' : 'Mark as hidden proof candidate'}</button>}
      </div>}
    </div>
  )
}

function AdminEventsPageSession({ identity, resourcePath }) {
  const { beginRequest } = usePlatformRequests(identity, resourcePath)
  const loadGeneration = useRef(0)
  const pendingLoad = useRef(null)
  const mutationBusy = useRef(false)
  const [loadError, setLoadError] = useState('')
  const [events, setEvents] = useState([])
  const [meta, setMeta] = useState({})
  const [loading, setLoading] = useState(true)
  const [search, setSearch] = useState('')
  const [status, setStatus] = useState('')
  const [category, setCategory] = useState('')
  const [heldOnly, setHeldOnly] = useState(false)
  const [policyEvent, setPolicyEvent] = useState(null)
  const [resumeEvent, setResumeEvent] = useState(null)
  const [notice, setNotice] = useState('')
  const [page, setPage] = useState(1)
  const [actionError, setActionError] = useState('')
  const [refreshError, setRefreshError] = useState('')
  const [openGates, setOpenGates] = useState(() => new Set())
  const toggleGates = useCallback(eventId => setOpenGates(previous => {
    const next = new Set(previous)
    if (next.has(eventId)) next.delete(eventId)
    else next.add(eventId)
    return next
  }), [])
  // A different page or filter shows different rows, so expanded gates start closed again.
  // The post-action refresh goes through fetchEvents directly and keeps them open.
  const changeListing = update => { update(); setOpenGates(new Set()) }

  // A refresh after a gate action keeps the current rows mounted so the open
  // disclosure and the trigger that holds keyboard focus stay in place.
  const fetchEvents = useCallback(options => {
    const keepRows = options?.keepRows === true
    const request = beginRequest()
    if (!request) return
    pendingLoad.current?.abort()
    pendingLoad.current = request
    const generation = ++loadGeneration.current
    const active = () => request.current() && generation === loadGeneration.current
    if (!keepRows) setLoading(true)
    setLoadError('')
    setRefreshError('')
    const params = { page, per_page: 20 }
    if (search) params.search = search
    if (status) params.status = status
    if (category) params.category = category
    if (heldOnly) params.policy_hold = 'true'
    apiClient.get('/admin/events', { ...request.config, params })
      .then(res => { if (active()) { setEvents(res.data.events); setMeta(res.data.meta); } })
      .catch(error => {
        if (!active() || request.handleError(error)) return
        // A failed refresh after a gate action leaves the rows (and the focused
        // trigger) in place; only a full load replaces the table with the error.
        if (keepRows) setRefreshError('Could not refresh events after that action. The list below may be out of date.')
        else setLoadError('Could not load events. Your filters have been kept.')
      })
      .finally(() => { request.release(); if (active()) setLoading(false) })
  }, [page, search, status, category, heldOnly, beginRequest])
  const refreshAfterAction = useCallback(() => fetchEvents({ keepRows: true }), [fetchEvents])

  useEffect(() => { fetchEvents(); return () => pendingLoad.current?.abort() }, [fetchEvents])

  const toggleFeatured = async (event) => {
    if (mutationBusy.current) return
    const request = beginRequest()
    if (!request) return
    mutationBusy.current = true
    setActionError('')
    try {
      const res = await apiClient.patch(`/admin/events/${event.id}`, { is_featured: !event.is_featured }, request.config)
      if (!request.current()) return
      setEvents(prev => prev.map(e => e.id === event.id ? res.data : e))
    } catch (err) {
      if (request.handleError(err)) return
      if (request.current()) setActionError(err.response?.data?.error || 'The change was not confirmed. Reload the saved event before trying again.')
    } finally { request.release(); mutationBusy.current = false }
  }

  const toggleProofCandidate = async (event) => {
    setActionError('')
    if (mutationBusy.current) return
    const request = beginRequest()
    if (!request) return
    mutationBusy.current = true
    setActionError('')
    try {
      const res = await apiClient.patch(`/admin/events/${event.id}`, { live_money_proof_candidate: !event.live_money_proof_candidate }, request.config)
      if (!request.current()) return
      setEvents(prev => prev.map(item => item.id === event.id ? res.data : item))
    } catch (err) {
      if (request.handleError(err)) return
      if (!request.current()) return
      const errors = err.response?.data?.errors
      setActionError(Array.isArray(errors) ? errors.join(' ') :
        err.response?.data?.error || err.response?.data?.message || 'The proof-candidate flag could not be updated.')
    } finally { request.release(); mutationBusy.current = false }
  }

  return (
    <AdminLayout>
      <div className="flex flex-col sm:flex-row gap-3 mb-6">
        <div className="relative flex-1">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-neutral-400" />
          <input
            type="text"
            placeholder="Search events..."
            value={search}
            onChange={e => changeListing(() => { setSearch(e.target.value); setPage(1) })}
            className="w-full pl-10 pr-4 py-2.5 bg-white/70 border border-neutral-200/50 rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-brand-500/20 focus:border-brand-500"
          />
        </div>
        <select aria-label="Filter events by status" value={status} onChange={e => changeListing(() => { setStatus(e.target.value); setPage(1) })} className="px-4 py-2.5 bg-white/70 border border-neutral-200/50 rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-brand-500/20">
          <option value="">All Statuses</option>
          {statuses.filter(Boolean).map(s => <option key={s} value={s}>{adminLabel(s)}</option>)}
        </select>
        <select aria-label="Filter events by category" value={category} onChange={e => changeListing(() => { setCategory(e.target.value); setPage(1) })} className="px-4 py-2.5 bg-white/70 border border-neutral-200/50 rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-brand-500/20">
          <option value="">All Categories</option>
          {categories.filter(Boolean).map(c => <option key={c} value={c}>{adminLabel(c)}</option>)}
        </select>
        <label className="inline-flex min-h-11 items-center gap-2 whitespace-nowrap rounded-xl border border-neutral-200/50 bg-white/70 px-4 text-sm text-neutral-800">
          <input type="checkbox" checked={heldOnly} onChange={e => changeListing(() => { setHeldOnly(e.target.checked); setPage(1) })} className="h-4 w-4 accent-brand-700" />
          On policy hold
        </label>
      </div>
      {notice && <p role="status" className="mb-4 rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm text-emerald-900">{notice}</p>}

      {refreshError && <div role="alert" className="mb-4 flex flex-wrap items-center gap-2 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-800">{refreshError} <button type="button" onClick={refreshAfterAction} className="min-h-11 rounded px-3 font-semibold underline focus-visible:ring-2 focus-visible:ring-focus">Refresh list</button></div>}
      {actionError && <p role="alert" className="mb-4 rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700">{actionError}</p>}

      {/* No backdrop-filter here: it would trap the gate dialogs' fixed overlays inside this card. */}
      <div className="bg-white rounded-xl border border-neutral-200/50 shadow-soft overflow-hidden">
        {loading ? (
          <div className="flex justify-center py-12"><Loader2 className="w-6 h-6 text-brand-500 animate-spin" /></div>
        ) : loadError ? (
          <div role="alert" className="p-5 text-red-700">{loadError} <button onClick={fetchEvents} className="min-h-11 rounded px-3 font-semibold underline focus-visible:ring-2 focus-visible:ring-focus">Try again</button></div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-neutral-100 text-left text-neutral-500">
                  {/* Organizer sits under the title; category joins it below xl. */}
                  <th className="min-w-[15rem] px-4 py-3 font-medium">Event</th>
                  <th className="px-3 py-3 font-medium">Status</th>
                  <th className="hidden px-3 py-3 font-medium xl:table-cell">Category</th>
                  <th className="px-3 py-3 font-medium text-right">Sold</th>
                  <th className="hidden px-3 py-3 font-medium text-right md:table-cell">Revenue</th>
                  <th className="px-3 py-3 font-medium">Release gates</th>
                  <th className="px-3 py-3 font-medium text-center"><span aria-hidden="true">★</span><span className="sr-only">Featured</span></th>
                </tr>
              </thead>
              <tbody className="divide-y divide-neutral-100">
                {events.map(event => (
                  <tr key={event.id} className="hover:bg-neutral-50/50 transition-colors">
                    <td className="min-w-[15rem] px-4 py-3">
                      <Link to={`/events/${event.slug}`} className="font-medium text-brand-600 hover:text-brand-700">{event.title}</Link>
                      <p className="mt-0.5 text-xs text-neutral-500">
                        {event.organizer_name}
                        {event.category && <span className="capitalize xl:hidden">{event.organizer_name ? ' · ' : ''}{event.category}</span>}
                      </p>
                      {event.sales_suspended && <div className="mt-1.5 max-w-sm text-xs text-red-800">
                        <p className="inline-flex rounded-full bg-red-50 px-2 py-0.5 font-medium ring-1 ring-red-200">Sales paused by HåfaPass</p>
                        {event.sales_suspension_reason && <p className="mt-1 whitespace-pre-wrap [overflow-wrap:anywhere]">{event.sales_suspension_reason}</p>}
                      </div>}
                      {event.policy_hold && <p className="mt-1.5 inline-flex rounded-full bg-red-50 px-2 py-0.5 text-xs font-medium text-red-800 ring-1 ring-red-200">{POLICY_HOLD_SCOPES[event.policy_hold.scope]?.badge || 'On policy hold'}</p>}
                      <div className="mt-1 flex flex-wrap gap-x-3 text-xs font-semibold">
                        <Link to={`/admin/payouts?event_id=${event.id}`} className="inline-flex min-h-11 items-center text-brand-700 underline-offset-2 hover:underline sm:min-h-8">Payouts<span className="sr-only"> for {event.title}</span></Link>
                        <button type="button" onClick={() => { setNotice(''); setPolicyEvent(event) }} className={`inline-flex min-h-11 items-center underline-offset-2 hover:underline sm:min-h-8 ${event.policy_hold ? 'text-brand-700' : 'text-red-700'}`}>
                          {event.policy_hold ? 'Restore' : 'Pause or hide'}<span className="sr-only"> {event.title}</span>
                        </button>
                        {event.sales_suspended && <button type="button" onClick={() => { setNotice(''); setResumeEvent(event) }} className="inline-flex min-h-11 items-center text-brand-700 underline-offset-2 hover:underline sm:min-h-8">
                          Resume sales<span className="sr-only"> for {event.title}</span>
                        </button>}
                      </div>
                      {['published', 'postponed', 'cancelled'].includes(event.status) && <CancellationRefundProgress admin canMarkCash eventId={event.id} status={event.status} eventTimeZone={event.timezone} onCancelled={() => fetchEvents({ keepRows: true })} />}
                    </td>
                    <td className="whitespace-nowrap px-3 py-3">
                      <span className={`text-xs px-2 py-1 rounded-full font-medium ${
                        event.status === 'published' ? 'bg-emerald-50 text-emerald-700' :
                        event.status === 'draft' ? 'bg-neutral-100 text-neutral-600' :
                        event.status === 'completed' ? 'bg-violet-50 text-violet-800' :
                        'bg-red-50 text-red-800'
                      }`}>{adminLabel(event.status)}</span>
                    </td>
                    <td className="hidden px-3 py-3 text-neutral-500 capitalize xl:table-cell">{event.category}</td>
                    <td className="whitespace-nowrap px-3 py-3 text-right text-neutral-700">
                      {event.tickets_sold}
                      <span className="block text-xs text-neutral-500 md:hidden">Revenue: ${(event.revenue_cents / 100).toFixed(2)}</span>
                    </td>
                    <td className="hidden whitespace-nowrap px-3 py-3 text-right text-neutral-700 md:table-cell">${(event.revenue_cents / 100).toFixed(2)}</td>
                    <td className="px-3 py-3"><ReleaseGatesControl event={event} open={openGates.has(event.id)} onToggle={() => toggleGates(event.id)} onComplete={refreshAfterAction} toggleProofCandidate={toggleProofCandidate} /></td>
                    <td className="px-3 py-3 text-center">
                      <button type="button" aria-label={event.is_featured ? `Remove ${event.title} from featured events` : `Feature ${event.title}`} onClick={() => toggleFeatured(event)} className="p-1 rounded-lg hover:bg-neutral-100 transition-colors">
                        <Star className={`w-4 h-4 ${event.is_featured ? 'fill-amber-400 text-amber-400' : 'text-neutral-300'}`} />
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {events.length === 0 && <p className="text-center py-8 text-neutral-400">No events found.</p>}
          </div>
        )}
      </div>

      {meta.total_pages > 1 && (
        <div className="flex items-center justify-center gap-2 mt-6">
          <button onClick={() => changeListing(() => setPage(p => Math.max(1, p - 1)))} disabled={page === 1} className="p-2 rounded-xl border border-neutral-200/50 bg-white/70 disabled:opacity-40 hover:bg-neutral-50 transition-colors">
            <ChevronLeft className="w-4 h-4" />
          </button>
          <span className="text-sm text-neutral-600">Page {meta.page} of {meta.total_pages}</span>
          <button onClick={() => changeListing(() => setPage(p => Math.min(meta.total_pages, p + 1)))} disabled={page === meta.total_pages} className="p-2 rounded-xl border border-neutral-200/50 bg-white/70 disabled:opacity-40 hover:bg-neutral-50 transition-colors">
            <ChevronRight className="w-4 h-4" />
          </button>
        </div>
      )}
      {policyEvent && <EventPolicyHoldDialog event={policyEvent} beginRequest={beginRequest} onClose={() => setPolicyEvent(null)}
        onSaved={message => { setPolicyEvent(null); setNotice(message); refreshAfterAction() }} />}
      {resumeEvent && <EventSalesSuspensionDialog event={resumeEvent} beginRequest={beginRequest} onClose={() => setResumeEvent(null)}
        onSaved={message => { setResumeEvent(null); setNotice(message); refreshAfterAction() }} />}
    </AdminLayout>
  )
}

export default function AdminEventsPage() {
  const identity = usePlatformIdentity('admin')
  const visit = usePlatformVisit('/admin/events')
  if (!visit.active) return null
  if (identity.authorityDenied) return <AdminAccessRecovery key={identity.accountKey} identity={identity} />
  if (!identity.ready) return <p role="status">Checking account access…</p>
  return <AdminEventsPageSession key={`${identity.accountKey}:${visit.generation}`} identity={identity} resourcePath="/admin/events" />
}
