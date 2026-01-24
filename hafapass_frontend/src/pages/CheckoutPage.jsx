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

  // Buyer form state
  const [buyerName, setBuyerName] = useState('')
  const [buyerEmail, setBuyerEmail] = useState('')
  const [buyerPhone, setBuyerPhone] = useState('')
  const [formErrors, setFormErrors] = useState({})
  const [submitting, setSubmitting] = useState(false)
  const [submitError, setSubmitError] = useState(null)

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

  const validateForm = () => {
    const errors = {}
    if (!buyerName.trim()) {
      errors.name = 'Name is required'
    }
    if (!buyerEmail.trim()) {
      errors.email = 'Email is required'
    } else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(buyerEmail.trim())) {
      errors.email = 'Please enter a valid email address'
    }
    return errors
  }

  const handleSubmit = async (e) => {
    e.preventDefault()
    setSubmitError(null)

    const errors = validateForm()
    if (Object.keys(errors).length > 0) {
      setFormErrors(errors)
      return
    }

    setSubmitting(true)
    try {
      const payload = {
        event_id: event.id,
        buyer_name: buyerName.trim(),
        buyer_email: buyerEmail.trim(),
        buyer_phone: buyerPhone.trim() || null,
        line_items: lineItems.map(item => ({
          ticket_type_id: item.ticket_type_id,
          quantity: item.quantity,
        })),
      }

      const response = await apiClient.post('/orders', payload)
      const order = response.data

      navigate(`/orders/${order.id}/confirmation`, {
        state: { order, event },
        replace: true,
      })
    } catch (err) {
      const message = err.response?.data?.error || 'Something went wrong. Please try again.'
      setSubmitError(message)
    } finally {
      setSubmitting(false)
    }
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

      {/* Buyer Information Form */}
      <div className="bg-white border border-gray-200 rounded-xl shadow-sm p-6 mb-6">
        <h2 className="text-lg font-semibold text-gray-900 mb-4">Your Information</h2>

        {submitError && (
          <div className="bg-red-50 border border-red-200 rounded-lg p-3 mb-4">
            <p className="text-red-700 text-sm">{submitError}</p>
          </div>
        )}

        <form onSubmit={handleSubmit} noValidate>
          <div className="space-y-4">
            {/* Name */}
            <div>
              <label htmlFor="buyerName" className="block text-sm font-medium text-gray-700 mb-1">
                Full Name <span className="text-red-500">*</span>
              </label>
              <input
                id="buyerName"
                type="text"
                value={buyerName}
                onChange={(e) => { setBuyerName(e.target.value); setFormErrors(prev => ({ ...prev, name: null })) }}
                className={`w-full px-4 py-3 border rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent ${formErrors.name ? 'border-red-300 bg-red-50' : 'border-gray-300'}`}
                placeholder="Enter your full name"
                disabled={submitting}
              />
              {formErrors.name && <p className="text-red-600 text-xs mt-1">{formErrors.name}</p>}
            </div>

            {/* Email */}
            <div>
              <label htmlFor="buyerEmail" className="block text-sm font-medium text-gray-700 mb-1">
                Email Address <span className="text-red-500">*</span>
              </label>
              <input
                id="buyerEmail"
                type="email"
                value={buyerEmail}
                onChange={(e) => { setBuyerEmail(e.target.value); setFormErrors(prev => ({ ...prev, email: null })) }}
                className={`w-full px-4 py-3 border rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent ${formErrors.email ? 'border-red-300 bg-red-50' : 'border-gray-300'}`}
                placeholder="you@example.com"
                disabled={submitting}
              />
              {formErrors.email && <p className="text-red-600 text-xs mt-1">{formErrors.email}</p>}
            </div>

            {/* Phone */}
            <div>
              <label htmlFor="buyerPhone" className="block text-sm font-medium text-gray-700 mb-1">
                Phone Number <span className="text-gray-400 font-normal">(optional)</span>
              </label>
              <input
                id="buyerPhone"
                type="tel"
                value={buyerPhone}
                onChange={(e) => setBuyerPhone(e.target.value)}
                className="w-full px-4 py-3 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                placeholder="(671) 555-0123"
                disabled={submitting}
              />
            </div>
          </div>

          {/* Submit Button */}
          <button
            type="submit"
            disabled={submitting}
            className="w-full mt-6 bg-orange-500 hover:bg-orange-600 disabled:bg-orange-300 disabled:cursor-not-allowed text-white font-bold py-4 px-6 rounded-lg text-lg transition-colors duration-200"
          >
            {submitting ? 'Processing...' : `Complete Purchase — ${formatPrice(totalCents)}`}
          </button>

          <p className="text-xs text-gray-400 text-center mt-3">
            By completing this purchase you agree to the HafaPass terms of service.
          </p>
        </form>
      </div>
    </div>
  )
}
