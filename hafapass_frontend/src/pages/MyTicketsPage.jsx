import { useState, useEffect } from 'react'
import { Link } from 'react-router-dom'
import apiClient from '../api/client'

export default function MyTicketsPage() {
  const [orders, setOrders] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  useEffect(() => {
    fetchOrders()
  }, [])

  async function fetchOrders() {
    setLoading(true)
    setError(null)
    try {
      const response = await apiClient.get('/me/orders')
      setOrders(response.data)
    } catch (err) {
      if (err.response?.status === 401) {
        setError('Please sign in to view your tickets.')
      } else {
        setError('Failed to load your tickets. Please try again.')
      }
    } finally {
      setLoading(false)
    }
  }

  if (loading) {
    return (
      <div className="min-h-[60vh] flex items-center justify-center">
        <div className="animate-spin rounded-full h-10 w-10 border-b-2 border-blue-900"></div>
      </div>
    )
  }

  if (error) {
    return (
      <div className="max-w-2xl mx-auto px-4 py-12">
        <div className="bg-red-50 border border-red-200 rounded-lg p-6 text-center">
          <p className="text-red-700">{error}</p>
          <button
            onClick={fetchOrders}
            className="mt-4 text-sm font-medium text-red-600 hover:text-red-800 underline"
          >
            Try Again
          </button>
        </div>
      </div>
    )
  }

  // Flatten tickets from all orders, grouping by event
  const ticketsByEvent = {}
  orders.forEach(order => {
    if (!order.event || !order.tickets) return
    const eventId = order.event.id
    if (!ticketsByEvent[eventId]) {
      ticketsByEvent[eventId] = {
        event: order.event,
        tickets: []
      }
    }
    order.tickets.forEach(ticket => {
      ticketsByEvent[eventId].tickets.push({
        ...ticket,
        orderId: order.id
      })
    })
  })

  // Sort events: upcoming first (by starts_at), then past
  const now = new Date()
  const eventGroups = Object.values(ticketsByEvent).sort((a, b) => {
    const aDate = new Date(a.event.starts_at)
    const bDate = new Date(b.event.starts_at)
    const aUpcoming = aDate >= now
    const bUpcoming = bDate >= now
    if (aUpcoming && !bUpcoming) return -1
    if (!aUpcoming && bUpcoming) return 1
    return aUpcoming ? aDate - bDate : bDate - aDate
  })

  if (eventGroups.length === 0) {
    return (
      <div className="max-w-2xl mx-auto px-4 py-12 text-center">
        <div className="bg-white rounded-lg shadow-sm p-8">
          <svg className="mx-auto h-16 w-16 text-gray-300" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M15 5v2m0 4v2m0 4v2M5 5a2 2 0 00-2 2v3a2 2 0 110 4v3a2 2 0 002 2h14a2 2 0 002-2v-3a2 2 0 110-4V7a2 2 0 00-2-2H5z" />
          </svg>
          <h2 className="mt-4 text-xl font-semibold text-gray-800">No tickets yet</h2>
          <p className="mt-2 text-gray-500">Browse events to get started!</p>
          <Link
            to="/events"
            className="mt-6 inline-block bg-blue-900 text-white px-6 py-3 rounded-lg font-medium hover:bg-blue-800 transition-colors"
          >
            Browse Events
          </Link>
        </div>
      </div>
    )
  }

  function formatDate(dateStr) {
    const date = new Date(dateStr)
    return date.toLocaleDateString('en-US', {
      weekday: 'short',
      month: 'short',
      day: 'numeric',
      year: 'numeric'
    })
  }

  function formatTime(dateStr) {
    const date = new Date(dateStr)
    return date.toLocaleTimeString('en-US', {
      hour: 'numeric',
      minute: '2-digit'
    })
  }

  function getStatusBadge(status) {
    switch (status) {
      case 'issued':
        return <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-green-100 text-green-800">Valid</span>
      case 'checked_in':
        return <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-gray-100 text-gray-600">Used</span>
      case 'cancelled':
        return <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-red-100 text-red-800">Cancelled</span>
      case 'transferred':
        return <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-yellow-100 text-yellow-800">Transferred</span>
      default:
        return null
    }
  }

  return (
    <div className="max-w-3xl mx-auto px-4 py-8">
      <h1 className="text-2xl font-bold text-gray-900 mb-6">My Tickets</h1>

      <div className="space-y-6">
        {eventGroups.map(({ event, tickets }) => {
          const eventDate = new Date(event.starts_at)
          const isPast = eventDate < now

          return (
            <div key={event.id} className="bg-white rounded-lg shadow-sm overflow-hidden">
              <div className={`px-4 sm:px-5 py-4 border-b ${isPast ? 'bg-gray-50' : 'bg-blue-50'}`}>
                <div className="flex items-start justify-between">
                  <div>
                    <Link
                      to={`/events/${event.slug}`}
                      className="text-lg font-semibold text-gray-900 hover:text-blue-700 transition-colors"
                    >
                      {event.title}
                    </Link>
                    <p className="text-sm text-gray-600 mt-0.5">
                      {formatDate(event.starts_at)} at {formatTime(event.starts_at)}
                    </p>
                    {event.venue_name && (
                      <p className="text-sm text-gray-500">{event.venue_name}</p>
                    )}
                  </div>
                  {isPast && (
                    <span className="text-xs font-medium text-gray-500 bg-gray-200 px-2 py-1 rounded">Past</span>
                  )}
                </div>
              </div>

              <div className="divide-y divide-gray-100">
                {tickets.map(ticket => (
                  <Link
                    key={ticket.id}
                    to={`/tickets/${ticket.qr_code}`}
                    className="flex items-center justify-between px-4 sm:px-5 py-3 min-h-[52px] hover:bg-gray-50 transition-colors"
                  >
                    <div className="flex items-center space-x-3">
                      <div className="flex-shrink-0">
                        <svg className="h-5 w-5 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 5v2m0 4v2m0 4v2M5 5a2 2 0 00-2 2v3a2 2 0 110 4v3a2 2 0 002 2h14a2 2 0 002-2v-3a2 2 0 110-4V7a2 2 0 00-2-2H5z" />
                        </svg>
                      </div>
                      <div>
                        <p className="text-sm font-medium text-gray-900">{ticket.ticket_type.name}</p>
                        {ticket.attendee_name && (
                          <p className="text-xs text-gray-500">{ticket.attendee_name}</p>
                        )}
                      </div>
                    </div>
                    <div className="flex items-center space-x-3">
                      {getStatusBadge(ticket.status)}
                      <svg className="h-4 w-4 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 5l7 7-7 7" />
                      </svg>
                    </div>
                  </Link>
                ))}
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}
