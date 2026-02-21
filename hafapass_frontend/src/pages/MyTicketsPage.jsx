import { useState, useEffect } from 'react'
import { Link } from 'react-router-dom'
import { motion } from 'framer-motion'
import { Loader2, Ticket, Calendar, MapPin, Clock, ChevronRight, Download } from 'lucide-react'
import apiClient from '../api/client'
import SEO from '../components/SEO'
import { StaggerContainer, StaggerItem } from '../components/ui/ScrollReveal'
import NoiseOverlay from '../components/ui/NoiseOverlay'

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
      const data = response.data.orders || response.data
      setOrders(Array.isArray(data) ? data : [])
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
        <Loader2 className="w-8 h-8 text-brand-500 animate-spin" />
      </div>
    )
  }

  if (error) {
    return (
      <div className="max-w-2xl mx-auto px-4 py-12">
        <div className="bg-red-50 border border-red-200 rounded-xl p-6 text-center">
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
      <div>
        <SEO title="My Tickets" />
        {/* Dark header */}
        <div className="bg-neutral-950 pt-8 pb-12 relative">
          <NoiseOverlay />
          <div className="max-w-3xl mx-auto px-4 sm:px-6 text-center relative z-[2]">
            <h1 className="font-display text-3xl sm:text-4xl font-bold tracking-tight text-white mb-2">My Tickets</h1>
            <p className="text-neutral-400">Your event passes, all in one place</p>
          </div>
        </div>
        <div className="h-px bg-gradient-to-r from-transparent via-brand-500/20 to-transparent" />
        <div className="bg-neutral-50 min-h-[40vh]">
          <motion.div
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            className="max-w-2xl mx-auto px-4 py-12 text-center"
          >
            <div className="card p-8">
              <Ticket className="mx-auto h-16 w-16 text-neutral-300" />
              <h2 className="mt-4 text-xl font-semibold text-neutral-800">No tickets yet</h2>
              <p className="mt-2 text-neutral-500">Browse events to get started!</p>
              <Link
                to="/events"
                className="mt-6 inline-block btn-primary px-6 py-3"
              >
                Browse Events
              </Link>
            </div>
          </motion.div>
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
        return <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-brand-50 text-brand-700">Valid</span>
      case 'checked_in':
        return <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-neutral-100 text-neutral-600">Used</span>
      case 'cancelled':
        return <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-red-100 text-red-800">Cancelled</span>
      case 'transferred':
        return <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-yellow-100 text-yellow-800">Transferred</span>
      default:
        return null
    }
  }

  return (
    <div>
      <SEO title="My Tickets" />
      {/* Dark header */}
      <div className="bg-neutral-950 pt-8 pb-12 relative">
        <NoiseOverlay />
        <div className="max-w-3xl mx-auto px-4 sm:px-6 text-center relative z-[2]">
          <h1 className="font-display text-3xl sm:text-4xl font-bold tracking-tight text-white mb-2">My Tickets</h1>
          <p className="text-neutral-400">Your event passes, all in one place</p>
        </div>
      </div>
      <div className="h-px bg-gradient-to-r from-transparent via-brand-500/20 to-transparent" />

      {/* Light content */}
      <div className="bg-neutral-50 min-h-[40vh]">
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          className="max-w-3xl mx-auto px-4 py-8"
        >
          <StaggerContainer className="space-y-6">
            {eventGroups.map(({ event, tickets }, index) => {
              const eventDate = new Date(event.starts_at)
              const isPast = eventDate < now

              return (
                <StaggerItem key={event.id}>
                <motion.div
                  initial={{ opacity: 0, y: 20 }}
                  animate={{ opacity: 1, y: 0 }}
                  transition={{ delay: index * 0.1 }}
                  className="card overflow-hidden"
                >
                  <div className={`px-4 sm:px-5 py-4 border-b ${isPast ? 'bg-neutral-50' : 'bg-brand-50'}`}>
                    <div className="flex items-start justify-between">
                      <div>
                        <Link
                          to={`/events/${event.slug}`}
                          className="text-lg font-semibold text-neutral-900 hover:text-brand-600 transition-colors"
                        >
                          {event.title}
                        </Link>
                        <p className="text-sm text-neutral-600 mt-0.5 flex items-center gap-1.5">
                          <Calendar className="w-3.5 h-3.5" />
                          {formatDate(event.starts_at)}
                          <Clock className="w-3.5 h-3.5 ml-1" />
                          {formatTime(event.starts_at)}
                        </p>
                        {event.venue_name && (
                          <p className="text-sm text-neutral-500 flex items-center gap-1.5 mt-0.5">
                            <MapPin className="w-3.5 h-3.5" />
                            {event.venue_name}
                          </p>
                        )}
                      </div>
                      {isPast && (
                        <span className="text-xs font-medium text-neutral-500 bg-neutral-200 px-2 py-1 rounded-xl">Past</span>
                      )}
                    </div>
                  </div>

                  <div className="divide-y divide-neutral-100">
                    {tickets.map(ticket => (
                      <div
                        key={ticket.id}
                        className="flex items-center justify-between px-4 sm:px-5 py-3 min-h-[52px] hover:bg-neutral-50 transition-colors"
                      >
                        <Link
                          to={`/tickets/${ticket.qr_code}`}
                          className="flex items-center space-x-3 flex-1 min-w-0"
                        >
                          <div className="flex-shrink-0">
                            <Ticket className="h-5 w-5 text-neutral-400" />
                          </div>
                          <div>
                            <p className="text-sm font-medium text-neutral-900">{ticket.ticket_type.name}</p>
                            {ticket.attendee_name && (
                              <p className="text-xs text-neutral-500">{ticket.attendee_name}</p>
                            )}
                          </div>
                        </Link>
                        <div className="flex items-center space-x-2">
                          {getStatusBadge(ticket.status)}
                          <a
                            href={`${import.meta.env.VITE_API_URL || 'http://localhost:3000/api/v1'}/tickets/${ticket.qr_code}/download`}
                            className="p-1.5 text-neutral-400 hover:text-brand-500 transition-colors rounded-lg hover:bg-brand-50"
                            title="Download PDF"
                            onClick={(e) => e.stopPropagation()}
                          >
                            <Download className="h-4 w-4" />
                          </a>
                          <Link to={`/tickets/${ticket.qr_code}`}>
                            <ChevronRight className="h-4 w-4 text-neutral-400" />
                          </Link>
                        </div>
                      </div>
                    ))}
                  </div>
                </motion.div>
                </StaggerItem>
              )
            })}
          </StaggerContainer>
        </motion.div>
      </div>
    </div>
  )
}
