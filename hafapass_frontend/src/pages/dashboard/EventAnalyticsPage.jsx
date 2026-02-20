import { Loader2 } from 'lucide-react'
import { useState, useEffect, useCallback } from 'react'
import { useParams, Link } from 'react-router-dom'
import apiClient from '../../api/client'

function formatCents(cents) {
 const safe = Number.isFinite(cents) ? cents : 0
 return `$${(safe / 100).toFixed(2)}`
}

function formatDate(isoString) {
 if (!isoString) return ''
 return new Date(isoString).toLocaleString('en-US', {
  month: 'short',
  day: 'numeric',
  year: 'numeric',
  hour: 'numeric',
  minute: '2-digit'
 })
}

export default function EventAnalyticsPage() {
 const { id } = useParams()
 const [loading, setLoading] = useState(true)
 const [error, setError] = useState(null)
 const [stats, setStats] = useState(null)
 const [event, setEvent] = useState(null)
 const [attendees, setAttendees] = useState(null)
 const [showAttendees, setShowAttendees] = useState(false)
 const [attendeesLoading, setAttendeesLoading] = useState(false)

 const fetchData = useCallback(async () => {
  setLoading(true)
  setError(null)
  try {
   const [statsRes, eventRes] = await Promise.all([
    apiClient.get(`/organizer/events/${id}/stats`),
    apiClient.get(`/organizer/events/${id}`)
   ])
   setStats(statsRes.data)
   setEvent(eventRes.data)
  } catch (err) {
   if (err.response?.status === 401) {
    setError('Please sign in to access this page.')
   } else if (err.response?.status === 404) {
    setError('Event not found.')
   } else {
    setError('Failed to load analytics.')
   }
  } finally {
   setLoading(false)
  }
 }, [id])

 useEffect(() => {
  fetchData()
 }, [fetchData])

 const fetchAttendees = async () => {
  setError(null)
  setAttendeesLoading(true)
  try {
   const res = await apiClient.get(`/organizer/events/${id}/attendees`)
   // Handle both paginated { attendees: [...], meta: {...} } and legacy array response
   const attendeesData = res.data.attendees || res.data
   setAttendees(Array.isArray(attendeesData) ? attendeesData : [])
   setShowAttendees(true)
  } catch {
   setError('Failed to load attendees.')
  } finally {
   setAttendeesLoading(false)
  }
 }

 const handleToggleAttendees = () => {
  if (showAttendees) {
   setShowAttendees(false)
  } else if (attendees) {
   setShowAttendees(true)
  } else {
   fetchAttendees()
  }
 }

 if (loading) {
  return (
   <div className="flex justify-center items-center py-20">
    <Loader2 className="w-8 h-8 text-brand-500 animate-spin" />
   </div>
  )
 }

 if (error && !stats) {
  return (
   <div className="max-w-4xl mx-auto px-4 py-8">
    <div className="p-4 bg-red-50 border border-red-200 rounded-xl text-red-700 text-sm">
     {error}
    </div>
    <Link to="/dashboard" className="mt-4 inline-block text-brand-500 hover:text-brand-700 text-sm font-medium">
     Back to Dashboard
    </Link>
   </div>
  )
 }

 const totalTickets = (stats.tickets_by_type || []).reduce((sum, t) => sum + t.sold + t.available, 0)
 const checkInRate = stats.total_tickets_sold > 0
  ? Math.round((stats.tickets_checked_in / stats.total_tickets_sold) * 100)
  : 0

 return (
  <div className="max-w-4xl mx-auto px-4 py-8">
   {/* Header */}
   <div className="mb-6 flex items-center justify-between">
    <Link to={`/dashboard/events/${id}/edit`} className="text-brand-500 hover:text-brand-700 text-sm font-medium flex items-center gap-1">
     <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 19l-7-7 7-7" />
     </svg>
     Back to Event
    </Link>
   </div>

   <h1 className="text-2xl font-bold text-neutral-900 mb-1">Event Analytics</h1>
   {event && (
    <p className="text-neutral-600 mb-6">{event.title}</p>
   )}

   {error && (
    <div className="mb-6 p-4 bg-red-50 border border-red-200 rounded-xl text-red-700 text-sm">
     {error}
    </div>
   )}

   {/* Summary Cards */}
   <div className="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-8">
    <div className="bg-white rounded-xl shadow-sm border border-neutral-200 p-5">
     <div className="flex items-center gap-3">
      <div className="w-10 h-10 bg-brand-100 rounded-xl flex items-center justify-center">
       <svg className="w-5 h-5 text-brand-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 5v2m0 4v2m0 4v2M5 5a2 2 0 00-2 2v3a2 2 0 110 4v3a2 2 0 002 2h14a2 2 0 002-2v-3a2 2 0 110-4V7a2 2 0 00-2-2H5z" />
       </svg>
      </div>
      <div>
       <p className="text-sm text-neutral-500">Tickets Sold</p>
       <p className="text-2xl font-bold text-neutral-900">{stats.total_tickets_sold}</p>
       {totalTickets > 0 && (
        <p className="text-xs text-neutral-400">of {totalTickets} total</p>
       )}
      </div>
     </div>
    </div>

    <div className="bg-white rounded-xl shadow-sm border border-neutral-200 p-5">
     <div className="flex items-center gap-3">
      <div className="w-10 h-10 bg-green-100 rounded-xl flex items-center justify-center">
       <svg className="w-5 h-5 text-green-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 8c-1.657 0-3 .895-3 2s1.343 2 3 2 3 .895 3 2-1.343 2-3 2m0-8c1.11 0 2.08.402 2.599 1M12 8V7m0 1v8m0 0v1m0-1c-1.11 0-2.08-.402-2.599-1M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
       </svg>
      </div>
      <div>
       <p className="text-sm text-neutral-500">Total Revenue</p>
       <p className="text-2xl font-bold text-neutral-900">{formatCents(stats.total_revenue_cents)}</p>
      </div>
     </div>
    </div>

    <div className="bg-white rounded-xl shadow-sm border border-neutral-200 p-5">
     <div className="flex items-center gap-3">
      <div className="w-10 h-10 bg-purple-100 rounded-xl flex items-center justify-center">
       <svg className="w-5 h-5 text-purple-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
       </svg>
      </div>
      <div>
       <p className="text-sm text-neutral-500">Check-in Rate</p>
       <p className="text-2xl font-bold text-neutral-900">{checkInRate}%</p>
       <p className="text-xs text-neutral-400">{stats.tickets_checked_in} checked in</p>
      </div>
     </div>
    </div>
   </div>

   {/* Tickets by Type */}
   <div className="bg-white rounded-xl shadow-sm border border-neutral-200 mb-8">
    <div className="px-4 sm:px-5 py-4 border-b border-neutral-200">
     <h2 className="text-lg font-semibold text-neutral-900">Tickets by Type</h2>
    </div>
    <div className="overflow-x-auto">
     <table className="w-full">
      <thead>
       <tr className="bg-neutral-50">
        <th className="text-left px-3 sm:px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Type</th>
        <th className="text-right px-2 sm:px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Sold</th>
        <th className="text-right px-2 sm:px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Avail</th>
        <th className="text-right px-3 sm:px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Revenue</th>
       </tr>
      </thead>
      <tbody className="divide-y divide-neutral-200">
       {(stats.tickets_by_type || []).map((type, idx) => (
        <tr key={idx}>
         <td className="px-3 sm:px-5 py-3 text-sm font-medium text-neutral-900">{type.name}</td>
         <td className="px-2 sm:px-5 py-3 text-sm text-neutral-600 text-right">{type.sold}</td>
         <td className="px-2 sm:px-5 py-3 text-sm text-neutral-600 text-right">{type.available}</td>
         <td className="px-3 sm:px-5 py-3 text-sm text-neutral-900 text-right font-medium">{formatCents(type.revenue_cents)}</td>
        </tr>
       ))}
       {(stats.tickets_by_type || []).length === 0 && (
        <tr>
         <td colSpan={4} className="px-3 sm:px-5 py-4 text-sm text-neutral-500 text-center">No ticket types yet.</td>
        </tr>
       )}
      </tbody>
     </table>
    </div>
   </div>

   {/* Recent Orders */}
   <div className="bg-white rounded-xl shadow-sm border border-neutral-200 mb-8">
    <div className="px-5 py-4 border-b border-neutral-200">
     <h2 className="text-lg font-semibold text-neutral-900">Recent Orders</h2>
    </div>
    {(stats.recent_orders || []).length > 0 ? (
     <>
      {/* Desktop table */}
      <div className="hidden sm:block overflow-x-auto">
       <table className="w-full">
        <thead>
         <tr className="bg-neutral-50">
          <th className="text-left px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Buyer</th>
          <th className="text-left px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Email</th>
          <th className="text-right px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Tickets</th>
          <th className="text-right px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Total</th>
          <th className="text-right px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Date</th>
         </tr>
        </thead>
        <tbody className="divide-y divide-neutral-200">
         {(stats.recent_orders || []).map((order) => (
          <tr key={order.id}>
           <td className="px-5 py-3 text-sm font-medium text-neutral-900">{order.buyer_name}</td>
           <td className="px-5 py-3 text-sm text-neutral-600">{order.buyer_email}</td>
           <td className="px-5 py-3 text-sm text-neutral-600 text-right">{order.ticket_count}</td>
           <td className="px-5 py-3 text-sm text-neutral-900 text-right font-medium">{formatCents(order.total_cents)}</td>
           <td className="px-5 py-3 text-sm text-neutral-500 text-right whitespace-nowrap">{formatDate(order.created_at)}</td>
          </tr>
         ))}
        </tbody>
       </table>
      </div>
      {/* Mobile card layout */}
      <div className="sm:hidden divide-y divide-neutral-200">
       {(stats.recent_orders || []).map((order) => (
        <div key={order.id} className="px-4 py-3">
         <div className="flex items-center justify-between">
          <span className="text-sm font-medium text-neutral-900">{order.buyer_name}</span>
          <span className="text-sm font-medium text-neutral-900">{formatCents(order.total_cents)}</span>
         </div>
         <div className="flex items-center justify-between mt-1">
          <span className="text-xs text-neutral-500 truncate mr-2">{order.buyer_email}</span>
          <span className="text-xs text-neutral-500 whitespace-nowrap">{order.ticket_count} ticket{order.ticket_count === 1 ? '' : 's'}</span>
         </div>
         <p className="text-xs text-neutral-400 mt-1">{formatDate(order.created_at)}</p>
        </div>
       ))}
      </div>
     </>
    ) : (
     <div className="px-5 py-8 text-center">
      <p className="text-sm text-neutral-500">No orders yet.</p>
     </div>
    )}
   </div>

   {/* Attendees Section */}
   <div className="bg-white rounded-xl shadow-sm border border-neutral-200">
    <div className="px-5 py-4 border-b border-neutral-200 flex items-center justify-between">
     <h2 className="text-lg font-semibold text-neutral-900">Attendees</h2>
     <div className="flex items-center gap-3">
      <Link to={`/dashboard/events/${id}/attendees`} className="text-sm text-brand-500 hover:text-brand-700 font-medium">
       Full List →
      </Link>
      <button
       onClick={handleToggleAttendees}
       disabled={attendeesLoading}
       className="text-sm text-brand-500 hover:text-brand-700 font-medium disabled:opacity-50"
      >
       {attendeesLoading ? 'Loading...' : showAttendees ? 'Hide' : 'View All'}
      </button>
     </div>
    </div>
    {showAttendees && attendees && (
     attendees.length > 0 ? (
      <>
       {/* Desktop table */}
       <div className="hidden sm:block overflow-x-auto">
        <table className="w-full">
         <thead>
          <tr className="bg-neutral-50">
           <th className="text-left px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Name</th>
           <th className="text-left px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Email</th>
           <th className="text-left px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Ticket Type</th>
           <th className="text-left px-5 py-3 text-xs font-medium text-neutral-500 uppercase tracking-wider">Status</th>
          </tr>
         </thead>
         <tbody className="divide-y divide-neutral-200">
          {attendees.map((att) => (
           <tr key={att.id}>
            <td className="px-5 py-3 text-sm font-medium text-neutral-900">{att.attendee_name || '—'}</td>
            <td className="px-5 py-3 text-sm text-neutral-600">{att.attendee_email || '—'}</td>
            <td className="px-5 py-3 text-sm text-neutral-600">{att.ticket_type}</td>
            <td className="px-5 py-3">
             {att.status === 'checked_in' ? (
              <span className="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800">
               Checked In
              </span>
             ) : att.status === 'issued' ? (
              <span className="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-brand-100 text-brand-700">
               Valid
              </span>
             ) : att.status === 'cancelled' ? (
              <span className="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-red-100 text-red-800">
               Cancelled
              </span>
             ) : (
              <span className="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-neutral-100 text-neutral-800">
               {att.status}
              </span>
             )}
            </td>
           </tr>
          ))}
         </tbody>
        </table>
       </div>
       {/* Mobile card layout */}
       <div className="sm:hidden divide-y divide-neutral-200">
        {attendees.map((att) => (
         <div key={att.id} className="px-4 py-3">
          <div className="flex items-center justify-between">
           <span className="text-sm font-medium text-neutral-900">{att.attendee_name || '—'}</span>
           {att.status === 'checked_in' ? (
            <span className="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800">
             Checked In
            </span>
           ) : att.status === 'issued' ? (
            <span className="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-brand-100 text-brand-700">
             Valid
            </span>
           ) : att.status === 'cancelled' ? (
            <span className="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-red-100 text-red-800">
             Cancelled
            </span>
           ) : (
            <span className="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-neutral-100 text-neutral-800">
             {att.status}
            </span>
           )}
          </div>
          <p className="text-xs text-neutral-500 mt-1">{att.attendee_email || '—'}</p>
          <p className="text-xs text-neutral-400 mt-0.5">{att.ticket_type}</p>
         </div>
        ))}
       </div>
      </>
     ) : (
      <div className="px-5 py-8 text-center">
       <p className="text-sm text-neutral-500">No attendees yet.</p>
      </div>
     )
    )}
    {!showAttendees && !attendeesLoading && (
     <div className="px-5 py-6 text-center">
      <p className="text-sm text-neutral-500">Click &quot;View All&quot; to see the full attendee list with check-in status.</p>
     </div>
    )}
   </div>
  </div>
 )
}
