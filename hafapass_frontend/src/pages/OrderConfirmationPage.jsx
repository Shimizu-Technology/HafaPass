import { useState, useEffect } from 'react'
import { useParams, useLocation, Link } from 'react-router-dom'
import apiClient from '../api/client'

export default function OrderConfirmationPage() {
  const { id } = useParams()
  const location = useLocation()

  const [order, setOrder] = useState(location.state?.order || null)
  const [event, setEvent] = useState(location.state?.event || null)
  const [loading, setLoading] = useState(!location.state?.order)
  const [error, setError] = useState(null)

  useEffect(() => {
    if (!order) {
      setLoading(true)
      apiClient.get(`/me/orders/${id}`)
        .then(res => {
          setOrder(res.data)
          setEvent(res.data.event)
          setLoading(false)
        })
        .catch(() => {
          setError('Unable to load order details. Please check your email for confirmation.')
          setLoading(false)
        })
    }
  }, [id, order])

  const formatPrice = (cents) => {
    if (cents === 0) return 'Free'
    return `$${(cents / 100).toFixed(2)}`
  }

  const formatDate = (dateStr) => {
    if (!dateStr) return ''
    const date = new Date(dateStr)
    return date.toLocaleDateString('en-US', {
      weekday: 'short',
      month: 'short',
      day: 'numeric',
      year: 'numeric',
    })
  }

  const formatTime = (dateStr) => {
    if (!dateStr) return ''
    const date = new Date(dateStr)
    return date.toLocaleTimeString('en-US', {
      hour: 'numeric',
      minute: '2-digit',
    })
  }

  if (loading) {
    return (
      <div className="flex justify-center py-16">
        <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-700"></div>
      </div>
    )
  }

  if (error) {
    return (
      <div className="max-w-2xl mx-auto px-4 py-16">
        <div className="bg-red-50 border border-red-200 rounded-lg p-6 text-center">
          <p className="text-red-700 mb-4">{error}</p>
          <Link
            to="/events"
            className="inline-block bg-blue-600 hover:bg-blue-700 text-white font-medium px-6 py-2 rounded-lg transition-colors duration-200"
          >
            Browse Events
          </Link>
        </div>
      </div>
    )
  }

  if (!order) return null

  return (
    <div className="max-w-2xl mx-auto px-4 sm:px-6 py-8">
      {/* Success header */}
      <div className="text-center mb-8">
        <div className="inline-flex items-center justify-center w-16 h-16 bg-green-100 rounded-full mb-4">
          <svg className="w-8 h-8 text-green-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 13l4 4L19 7" />
          </svg>
        </div>
        <h1 className="text-2xl sm:text-3xl font-bold text-gray-900 mb-2">
          Your tickets are confirmed!
        </h1>
        <p className="text-gray-600">
          A confirmation has been sent to <span className="font-medium">{order.buyer_email}</span>
        </p>
      </div>

      {/* Order summary card */}
      <div className="bg-white border border-gray-200 rounded-xl shadow-sm p-6 mb-6">
        <h2 className="text-lg font-semibold text-gray-900 mb-4">Order Summary</h2>

        {/* Event info */}
        {event && (
          <div className="mb-4 pb-4 border-b border-gray-100">
            <p className="text-gray-900 font-medium">{event.title}</p>
            {event.starts_at && (
              <p className="text-sm text-gray-500 mt-1">
                {formatDate(event.starts_at)} &middot; {formatTime(event.starts_at)}
              </p>
            )}
            {event.venue_name && (
              <p className="text-sm text-gray-500">{event.venue_name}</p>
            )}
          </div>
        )}

        {/* Buyer info */}
        <div className="mb-4 pb-4 border-b border-gray-100">
          <div className="flex justify-between text-sm">
            <span className="text-gray-500">Name</span>
            <span className="text-gray-900">{order.buyer_name}</span>
          </div>
          {order.buyer_phone && (
            <div className="flex justify-between text-sm mt-1">
              <span className="text-gray-500">Phone</span>
              <span className="text-gray-900">{order.buyer_phone}</span>
            </div>
          )}
        </div>

        {/* Total paid */}
        <div className="flex justify-between items-center">
          <span className="text-gray-900 font-bold">Total Paid</span>
          <span className="text-gray-900 font-bold text-lg">{formatPrice(order.total_cents)}</span>
        </div>
      </div>

      {/* Tickets list */}
      <div className="bg-white border border-gray-200 rounded-xl shadow-sm p-6 mb-6">
        <h2 className="text-lg font-semibold text-gray-900 mb-4">
          Your Tickets ({order.tickets?.length || 0})
        </h2>

        <div className="space-y-3">
          {order.tickets?.map(ticket => (
            <div
              key={ticket.id}
              className="flex items-center justify-between p-3 bg-gray-50 rounded-lg"
            >
              <div>
                <p className="text-gray-900 font-medium">{ticket.ticket_type?.name}</p>
                <p className="text-sm text-gray-500">{ticket.attendee_name}</p>
              </div>
              <Link
                to={`/tickets/${ticket.qr_code}`}
                className="inline-flex items-center text-blue-600 hover:text-blue-800 text-sm font-medium"
              >
                View Ticket
                <svg className="w-4 h-4 ml-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 5l7 7-7 7" />
                </svg>
              </Link>
            </div>
          ))}
        </div>
      </div>

      {/* Browse more events button */}
      <div className="text-center">
        <Link
          to="/events"
          className="inline-block bg-blue-600 hover:bg-blue-700 text-white font-medium px-8 py-3 rounded-lg transition-colors duration-200"
        >
          Browse More Events
        </Link>
      </div>
    </div>
  )
}
