import { useState, useEffect } from 'react'
import { useParams, useNavigate, useLocation, Link } from 'react-router-dom'
import apiClient from '../api/client'

export default function CheckoutPage() {
  const { slug } = useParams()
  const navigate = useNavigate()
  const location = useLocation()

  const [event, setEvent] = useState(location.state?.event || null)
  const [loading, setLoading] = useState(!location.state?.event)
  const lineItems = location.state?.lineItems || null
  const [error, setError] = useState(null)

  useEffect(() => {
    if (!lineItems || lineItems.length === 0) {
      navigate(`/events/${slug}`, { replace: true })
      return
    }
    if (!event) {
      setLoading(true)
      apiClient.get(`/events/${slug}`)
        .then(res => {
          setEvent(res.data)
          setLoading(false)
        })
        .catch(() => {
          setError('Unable to load event details.')
          setLoading(false)
        })
    }
  }, [slug, event, lineItems, navigate])

  const formatPrice = (cents) => {
    if (cents === 0) return 'Free'
    return `$${(cents / 100).toFixed(2)}`
  }

  const formatDate = (dateStr) => {
    const date = new Date(dateStr)
    return date.toLocaleDateString('en-US', {
      weekday: 'short',
      month: 'short',
      day: 'numeric',
      year: 'numeric',
    })
  }

  const formatTime = (dateStr) => {
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
            to={`/events/${slug}`}
            className="inline-block bg-blue-600 hover:bg-blue-700 text-white font-medium px-6 py-2 rounded-lg transition-colors duration-200"
          >
            Back to Event
          </Link>
        </div>
      </div>
    )
  }

  if (!event || !lineItems) return null

  // Build order summary from lineItems and event ticket_types
  const orderLines = lineItems.map(item => {
    const ticketType = event.ticket_types.find(tt => tt.id === item.ticket_type_id)
    if (!ticketType) return null
    const lineTotal = ticketType.price_cents * item.quantity
    return {
      ...item,
      name: ticketType.name,
      price_cents: ticketType.price_cents,
      lineTotal,
    }
  }).filter(Boolean)

  const totalTickets = orderLines.reduce((sum, line) => sum + line.quantity, 0)
  const subtotalCents = orderLines.reduce((sum, line) => sum + line.lineTotal, 0)
  const serviceFeeCents = Math.round(subtotalCents * 0.03) + (totalTickets * 50)
  const totalCents = subtotalCents + serviceFeeCents

  return (
    <div className="max-w-2xl mx-auto px-4 sm:px-6 py-8">
      <Link
        to={`/events/${slug}`}
        className="inline-flex items-center text-blue-600 hover:text-blue-800 mb-6 text-sm font-medium"
      >
        <svg className="w-4 h-4 mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 19l-7-7 7-7" />
        </svg>
        Back to Event
      </Link>

      <h1 className="text-2xl sm:text-3xl font-bold text-gray-900 mb-2">Checkout</h1>

      {/* Event info */}
      <div className="mb-6">
        <p className="text-gray-700 font-medium">{event.title}</p>
        <p className="text-sm text-gray-500">
          {formatDate(event.starts_at)} &middot; {formatTime(event.starts_at)}
          {event.venue_name && ` &middot; ${event.venue_name}`}
        </p>
      </div>

      {/* Order Summary Card */}
      <div className="bg-white border border-gray-200 rounded-xl shadow-sm p-6 mb-6">
        <h2 className="text-lg font-semibold text-gray-900 mb-4">Order Summary</h2>

        {/* Line items */}
        <div className="space-y-3 mb-4">
          {orderLines.map(line => (
            <div key={line.ticket_type_id} className="flex justify-between items-center">
              <div>
                <span className="text-gray-800 font-medium">{line.name}</span>
                <span className="text-gray-500 ml-2">× {line.quantity}</span>
              </div>
              <span className="text-gray-900 font-medium">{formatPrice(line.lineTotal)}</span>
            </div>
          ))}
        </div>

        {/* Divider */}
        <hr className="border-gray-200 my-4" />

        {/* Subtotal */}
        <div className="flex justify-between items-center mb-2">
          <span className="text-gray-600">Subtotal</span>
          <span className="text-gray-900">{formatPrice(subtotalCents)}</span>
        </div>

        {/* Service Fee */}
        <div className="flex justify-between items-center mb-2">
          <span className="text-gray-600">
            Service fee
            <span className="text-xs text-gray-400 ml-1">(3% + $0.50/ticket)</span>
          </span>
          <span className="text-gray-900">{formatPrice(serviceFeeCents)}</span>
        </div>

        {/* Divider */}
        <hr className="border-gray-200 my-4" />

        {/* Total */}
        <div className="flex justify-between items-center">
          <span className="text-gray-900 font-bold text-lg">Total</span>
          <span className="text-gray-900 font-bold text-lg">{formatPrice(totalCents)}</span>
        </div>
      </div>

      {/* Placeholder for buyer form (Task 22) */}
      <div className="text-sm text-gray-500 text-center">
        Buyer information form will be added next.
      </div>
    </div>
  )
}
