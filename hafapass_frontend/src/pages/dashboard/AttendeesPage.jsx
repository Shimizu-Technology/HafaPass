import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import EventWorkspace from '../../components/EventWorkspace'
import { Loader2, Search, ChevronLeft, ChevronRight } from 'lucide-react'
import { useState, useEffect, useCallback, useRef } from 'react'
import { useParams } from 'react-router-dom'
import apiClient from '../../api/client'

const STATUS_STYLES = {
  checked_in: { label: 'Checked In', className: 'bg-green-100 text-green-800' },
  issued: { label: 'Valid', className: 'bg-brand-100 text-brand-700' },
  cancelled: { label: 'Cancelled', className: 'bg-red-100 text-red-800' }
}

function formatDate(iso) {
  if (!iso) return '—'
  return new Date(iso).toLocaleString('en-US', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })
}

export default function AttendeesPage() {
 const { id } = useParams()
 const identity = useOrganizerIdentity()
 const visit = useOrganizerPageVisit(`/dashboard/events/${id}/attendees`)
 if (!visit.active) return null
 if (!identity.ready) return <p role="status" className="p-6">Preparing your account…</p>
 return <AttendeesPageSession key={`${identity.accountKey}:${identity.organizationId}:${id}:${visit.generation}`} id={id} identity={identity} />
}

function AttendeesPageSession({ id, identity }) {
 const { current, beginRequest } = useOrganizerRequests(identity, `/dashboard/events/${id}/attendees`)
 const accessEpoch = useRef(0)
 const accessDenied = useRef(false)
 const requests = useRef(new Set())
 const [loading, setLoading] = useState(true)
 const [error, setError] = useState(null)
 const [detailError, setDetailError] = useState(null)
 const [loadAttempt, setLoadAttempt] = useState(0)
 const [attendees, setAttendees] = useState([])
 const [meta, setMeta] = useState(null)
 const [event, setEvent] = useState(null)
 const [page, setPage] = useState(1)
 const listGeneration = useRef(0)
 const [search, setSearch] = useState('')
 const [statusFilter, setStatusFilter] = useState('')
 const [ticketTypeFilter, setTicketTypeFilter] = useState('')
 const withdrawAccess = useCallback(message => {
  accessDenied.current = true
  ++accessEpoch.current
  requests.current.forEach(request => request.controller.abort())
  setAttendees([]); setMeta(null); setEvent(null)
  setDetailError(null); setError(message); setLoading(false)
 }, [])
 const requestApi = useCallback(async (method, url, payload, options = {}) => {
  const request = beginRequest()
  if (!request) throw new DOMException('Page context changed', 'AbortError')
  const epoch = accessEpoch.current
  requests.current.add(request)
  try {
   const response = method === 'get' || method === 'delete'
    ? await apiClient[method](url, { ...payload, ...request.config })
    : await apiClient[method](url, payload, { ...options, ...request.config })
   if (!request.current() || epoch !== accessEpoch.current) throw new DOMException('Page context changed', 'AbortError')
   return response
  } catch (requestError) {
   if (request.current() && epoch === accessEpoch.current && [401, 403, 404].includes(requestError.response?.status)) {
    withdrawAccess(requestError.response.status === 401 ? 'Please sign in.'
     : requestError.response.status === 404 ? 'Event not found.' : 'Your attendee access changed. Retry to verify access before viewing this list.')
   }
   throw requestError
  } finally { requests.current.delete(request); request.release() }
 }, [beginRequest, withdrawAccess])

  const fetchAttendees = useCallback(async () => {
    const generation = ++listGeneration.current
    if (!current()) return
    const epoch = ++accessEpoch.current
    requests.current.forEach(request => request.controller.abort())
    const canApply = () => current() && generation === listGeneration.current && epoch === accessEpoch.current
    setLoading(true)
    setError(null)
    try {
      try {
        const response = await requestApi('get', `/organizer/events/${id}`)
        if (!canApply()) return
        const saved = response.data
        if (String(saved.id) !== String(id) || saved.organization_id == null || (identity.organizationId != null && String(saved.organization_id) !== String(identity.organizationId))) {
          withdrawAccess('The event context could not be verified. Return to your dashboard and select the event again.')
          return
        }
        if (saved.permissions?.view_attendees !== true) {
          withdrawAccess('Your event access does not include viewing attendees.')
          return
        }
        accessDenied.current = false
        setEvent(saved); setDetailError(null)
      } catch {
        if (!canApply()) return
        setDetailError('Failed to load event details.')
        // A list endpoint can independently authorize a normal metadata outage.
        // After a known denial, only fresh event permission verification restores it.
        if (accessDenied.current) return
      }
      const params = new URLSearchParams({ page: String(page), per_page: '25' })
      if (search.trim()) params.set('search', search.trim())
      if (statusFilter) params.set('status', statusFilter)
      if (ticketTypeFilter) params.set('ticket_type', ticketTypeFilter)

      const attRes = await requestApi('get', `/organizer/events/${id}/attendees?${params}`)
      if (!canApply()) return

      const data = attRes.data.attendees || attRes.data
      setAttendees(Array.isArray(data) ? data : [])
      setMeta(attRes.data.meta || null)
    } catch (err) {
      if (!canApply()) return
      if (err.response?.status === 401) setError('Please sign in.')
      else if (err.response?.status === 404) setError('Event not found.')
      else setError('Failed to load attendees.')
    } finally {
      if (canApply()) setLoading(false)
    }
  }, [id, page, search, statusFilter, ticketTypeFilter, requestApi, current, identity.organizationId, withdrawAccess])

  useEffect(() => { fetchAttendees() }, [fetchAttendees, loadAttempt])

  const visibleError = detailError || error
  const ticketTypes = event?.ticket_types || []
  const totalPages = meta?.total_pages || 1

  return (
    <EventWorkspace eventId={id} event={event}><div className="max-w-4xl mx-auto">

      <h2 className="text-2xl font-bold text-neutral-900 mb-1">Attendees</h2>
      {event && <p className="text-neutral-600 mb-6">{event.title}</p>}

      {visibleError && (
        <div role="alert" className="mb-6 p-4 bg-red-50 border border-red-200 rounded-xl text-red-700 text-sm"><p>{visibleError}</p><button type="button" className="min-h-11 font-semibold underline" onClick={() => setLoadAttempt(value => value + 1)}>Retry attendee list</button></div>
      )}

      {/* Filters */}
      <div className="flex flex-col sm:flex-row gap-3 mb-6">
        <div className="relative flex-1">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-neutral-400" />
          <input
            type="text"
            value={search}
            onChange={(e) => { setSearch(e.target.value); setPage(1) }}
            placeholder="Search by name or email..."
            aria-label="Search attendees by name or email"
            className="input pl-9"
          />
        </div>
        <select aria-label="Filter attendees by status" value={statusFilter} onChange={(e) => { setStatusFilter(e.target.value); setPage(1) }} className="input w-auto">
          <option value="">All Statuses</option>
          <option value="issued">Valid</option>
          <option value="checked_in">Checked In</option>
          <option value="cancelled">Cancelled</option>
        </select>
        {ticketTypes.length > 0 && (
          <select aria-label="Filter attendees by ticket type" value={ticketTypeFilter} onChange={(e) => { setTicketTypeFilter(e.target.value); setPage(1) }} className="input w-auto">
            <option value="">All Ticket Types</option>
            {ticketTypes.map(tt => <option key={tt.id} value={tt.name}>{tt.name}</option>)}
          </select>
        )}
      </div>

      {loading ? (
        <div className="flex justify-center py-12"><Loader2 className="w-8 h-8 text-brand-500 animate-spin" /></div>
      ) : visibleError && attendees.length === 0 ? null : attendees.length === 0 ? (
        <div className="bg-white rounded-xl shadow-sm border border-neutral-200 p-12 text-center">
          <p className="text-neutral-500">No attendees found.</p>
        </div>
      ) : (
        <>
          {/* Desktop table */}
          <div className="hidden sm:block bg-white rounded-xl shadow-sm border border-neutral-200 overflow-hidden">
            <table className="w-full">
              <thead>
                <tr className="bg-neutral-50">
                  <th className="text-left px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Name</th>
                  <th className="text-left px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Email</th>
                  <th className="text-left px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Ticket Type</th>
                  <th className="text-left px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Status</th>
                  <th className="text-left px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Checked In</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-neutral-200">
                {attendees.map((att) => {
                  const style = STATUS_STYLES[att.status] || { label: att.status, className: 'bg-neutral-100 text-neutral-800' }
                  return (
                    <tr key={att.id}>
                      <td className="px-5 py-3 text-sm font-medium text-neutral-900">{att.attendee_name || '—'}</td>
                      <td className="px-5 py-3 text-sm text-neutral-600">{att.attendee_email || '—'}</td>
                      <td className="px-5 py-3 text-sm text-neutral-600">{att.ticket_type}</td>
                      <td className="px-5 py-3"><span className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-medium ${style.className}`}>{style.label}</span></td>
                      <td className="px-5 py-3 text-sm text-neutral-500">{formatDate(att.checked_in_at)}</td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>

          {/* Mobile cards */}
          <div className="sm:hidden space-y-2">
            {attendees.map((att) => {
              const style = STATUS_STYLES[att.status] || { label: att.status, className: 'bg-neutral-100 text-neutral-800' }
              return (
                <div key={att.id} className="bg-white rounded-xl border border-neutral-200 p-4">
                  <div className="flex items-center justify-between">
                    <span className="text-sm font-medium text-neutral-900">{att.attendee_name || '—'}</span>
                    <span className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-medium ${style.className}`}>{style.label}</span>
                  </div>
                  <p className="text-xs text-neutral-500 mt-1">{att.attendee_email || '—'}</p>
                  <div className="flex justify-between mt-1">
                    <span className="text-xs text-neutral-400">{att.ticket_type}</span>
                    {att.checked_in_at && <span className="text-xs text-neutral-400">{formatDate(att.checked_in_at)}</span>}
                  </div>
                </div>
              )
            })}
          </div>

          {/* Pagination */}
          {totalPages > 1 && (
            <div className="flex items-center justify-center gap-4 mt-6">
              <button onClick={() => setPage(p => Math.max(1, p - 1))} disabled={page <= 1} className="p-2 text-neutral-500 hover:text-neutral-700 disabled:opacity-30">
                <ChevronLeft className="w-5 h-5" />
              </button>
              <span className="text-sm text-neutral-600">Page {page} of {totalPages}</span>
              <button onClick={() => setPage(p => Math.min(totalPages, p + 1))} disabled={page >= totalPages} className="p-2 text-neutral-500 hover:text-neutral-700 disabled:opacity-30">
                <ChevronRight className="w-5 h-5" />
              </button>
            </div>
          )}
        </>
      )}
    </div></EventWorkspace>
  )
}
