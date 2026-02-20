import { Loader2, Search, ChevronLeft, ChevronRight } from 'lucide-react'
import { useState, useEffect, useCallback } from 'react'
import { useParams, Link } from 'react-router-dom'
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
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [attendees, setAttendees] = useState([])
  const [meta, setMeta] = useState(null)
  const [event, setEvent] = useState(null)
  const [page, setPage] = useState(1)
  const [search, setSearch] = useState('')
  const [statusFilter, setStatusFilter] = useState('')
  const [ticketTypeFilter, setTicketTypeFilter] = useState('')

  const fetchAttendees = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const params = new URLSearchParams({ page: String(page), per_page: '25' })
      if (search.trim()) params.set('search', search.trim())
      if (statusFilter) params.set('status', statusFilter)
      if (ticketTypeFilter) params.set('ticket_type', ticketTypeFilter)

      const [attRes, eventRes] = await Promise.all([
        apiClient.get(`/organizer/events/${id}/attendees?${params}`),
        event ? Promise.resolve({ data: event }) : apiClient.get(`/organizer/events/${id}`)
      ])

      const data = attRes.data.attendees || attRes.data
      setAttendees(Array.isArray(data) ? data : [])
      setMeta(attRes.data.meta || null)
      if (!event) setEvent(eventRes.data)
    } catch (err) {
      if (err.response?.status === 401) setError('Please sign in.')
      else if (err.response?.status === 404) setError('Event not found.')
      else setError('Failed to load attendees.')
    } finally {
      setLoading(false)
    }
  }, [id, page, search, statusFilter, ticketTypeFilter])

  useEffect(() => { fetchAttendees() }, [fetchAttendees])

  const ticketTypes = event?.ticket_types || []
  const totalPages = meta?.total_pages || 1

  return (
    <div className="max-w-4xl mx-auto px-4 py-8">
      <div className="mb-6 flex items-center justify-between">
        <Link to={`/dashboard/events/${id}/edit`} className="text-brand-500 hover:text-brand-700 text-sm font-medium flex items-center gap-1">
          <ChevronLeft className="w-4 h-4" /> Back to Event
        </Link>
        <Link to={`/dashboard/events/${id}/analytics`} className="text-brand-500 hover:text-brand-700 text-sm font-medium">Analytics</Link>
      </div>

      <h1 className="text-2xl font-bold text-neutral-900 mb-1">Attendees</h1>
      {event && <p className="text-neutral-600 mb-6">{event.title}</p>}

      {error && (
        <div className="mb-6 p-4 bg-red-50 border border-red-200 rounded-xl text-red-700 text-sm">{error}</div>
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
            className="input pl-9"
          />
        </div>
        <select value={statusFilter} onChange={(e) => { setStatusFilter(e.target.value); setPage(1) }} className="input w-auto">
          <option value="">All Statuses</option>
          <option value="issued">Valid</option>
          <option value="checked_in">Checked In</option>
          <option value="cancelled">Cancelled</option>
        </select>
        {ticketTypes.length > 0 && (
          <select value={ticketTypeFilter} onChange={(e) => { setTicketTypeFilter(e.target.value); setPage(1) }} className="input w-auto">
            <option value="">All Ticket Types</option>
            {ticketTypes.map(tt => <option key={tt.id} value={tt.name}>{tt.name}</option>)}
          </select>
        )}
      </div>

      {loading ? (
        <div className="flex justify-center py-12"><Loader2 className="w-8 h-8 text-brand-500 animate-spin" /></div>
      ) : attendees.length === 0 ? (
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
    </div>
  )
}
