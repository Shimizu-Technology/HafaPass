import { useState, useEffect } from 'react'
import { useParams, useNavigate, useLocation, Link } from 'react-router-dom'
import apiClient from '../api/client'
import StripeProvider from '../components/StripeProvider'
import PaymentForm from '../components/PaymentForm'

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

  // Stripe state
  const [clientSecret, setClientSecret] = useState(null)
  const [orderId, setOrderId] = useState(null)
  const [orderData, setOrderData] = useState(null)
  const [step, setStep] = useState('info') // 'info' | 'payment'

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
      weekday: 'short', month: 'short', day: 'numeric', year: 'numeric',
    })
  }

  const formatTime = (dateStr) => {
    const date = new Date(dateStr)
    return date.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' })
  }

  const validateForm = () => {
    const errors = {}
    if (!buyerName.trim()) errors.name = 'Name is required'
    if (!buyerEmail.trim()) {
      errors.email = 'Email is required'
    } else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(buyerEmail.trim())) {
      errors.email = 'Please enter a valid email address'
    }
    return errors
  }

  const handleInfoSubmit = async (e) => {
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

      if (order.client_secret) {
        // Stripe mode: show payment form
        setClientSecret(order.client_secret)
        setOrderId(order.id)
        setOrderData(order)
        setStep('payment')
      } else {
        // Mock/free mode: go straight to confirmation
        navigate(`/orders/${order.id}/confirmation`, {
          state: { order, event },
          replace: true,
        })
      }
    } catch (err) {
      const message = err.response?.data?.error || 'Something went wrong. Please try again.'
      setSubmitError(message)
    } finally {
      setSubmitting(false)
    }
  }

  const handlePaymentSuccess = (paymentIntent) => {
    navigate(`/orders/${orderId}/confirmation`, {
      state: { order: orderData, event, paymentIntent },
      replace: true,
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
          <Link to={`/events/${slug}`} className="inline-block bg-blue-600 hover:bg-blue-700 text-white font-medium px-6 py-2 rounded-lg transition-colors duration-200">
            Back to Event
          </Link>
        </div>
      </div>
    )
  }

  if (!event || !lineItems) return null

  // Build order summary
  const orderLines = lineItems.map(item => {
    const ticketType = event.ticket_types.find(tt => tt.id === item.ticket_type_id)
    if (!ticketType) return null
    const lineTotal = ticketType.price_cents * item.quantity
    return { ...item, name: ticketType.name, price_cents: ticketType.price_cents, lineTotal }
  }).filter(Boolean)

  const totalTickets = orderLines.reduce((sum, line) => sum + line.quantity, 0)
  const subtotalCents = orderLines.reduce((sum, line) => sum + line.lineTotal, 0)
  const serviceFeeCents = Math.round(subtotalCents * 0.03) + (totalTickets * 50)
  const totalCents = subtotalCents + serviceFeeCents

  return (
    <div className="max-w-2xl mx-auto px-4 sm:px-6 py-8">
      <Link to={`/events/${slug}`} className="inline-flex items-center text-blue-600 hover:text-blue-800 mb-6 text-sm font-medium">
        <svg className="w-4 h-4 mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 19l-7-7 7-7" />
        </svg>
        Back to Event
      </Link>

      <h1 className="text-2xl sm:text-3xl font-bold text-gray-900 mb-2">Checkout</h1>

      {/* Progress indicator */}
      <div className="flex items-center gap-2 mb-6">
        <div className={`flex items-center gap-1.5 text-sm font-medium ${step === 'info' ? 'text-blue-700' : 'text-green-600'}`}>
          {step === 'payment' ? (
            <svg className="w-5 h-5" fill="currentColor" viewBox="0 0 20 20">
              <path fillRule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clipRule="evenodd" />
            </svg>
          ) : (
            <span className="w-5 h-5 rounded-full bg-blue-700 text-white text-xs flex items-center justify-center">1</span>
          )}
          Your Info
        </div>
        <svg className="w-4 h-4 text-gray-300" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 5l7 7-7 7" />
        </svg>
        <div className={`flex items-center gap-1.5 text-sm font-medium ${step === 'payment' ? 'text-blue-700' : 'text-gray-400'}`}>
          <span className={`w-5 h-5 rounded-full text-xs flex items-center justify-center ${step === 'payment' ? 'bg-blue-700 text-white' : 'bg-gray-200 text-gray-500'}`}>2</span>
          Payment
        </div>
      </div>

      {/* Event info */}
      <div className="mb-6">
        <p className="text-gray-700 font-medium">{event.title}</p>
        <p className="text-sm text-gray-500">
          {formatDate(event.starts_at)} &middot; {formatTime(event.starts_at)}
          {event.venue_name && ` · ${event.venue_name}`}
        </p>
      </div>

      {/* Order Summary Card */}
      <div className="bg-white border border-gray-200 rounded-xl shadow-sm p-4 sm:p-6 mb-6">
        <h2 className="text-lg font-semibold text-gray-900 mb-4">Order Summary</h2>

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

        <hr className="border-gray-200 my-4" />

        <div className="flex justify-between items-center mb-2">
          <span className="text-gray-600">Subtotal</span>
          <span className="text-gray-900">{formatPrice(subtotalCents)}</span>
        </div>

        <div className="flex justify-between items-center mb-2">
          <span className="text-gray-600">
            Service fee
            <span className="text-xs text-gray-400 ml-1 hidden sm:inline">(3% + $0.50/ticket)</span>
          </span>
          <span className="text-gray-900">{formatPrice(serviceFeeCents)}</span>
        </div>

        <hr className="border-gray-200 my-4" />

        <div className="flex justify-between items-center">
          <span className="text-gray-900 font-bold text-lg">Total</span>
          <span className="text-gray-900 font-bold text-lg">{formatPrice(totalCents)}</span>
        </div>
      </div>

      {/* Step 1: Buyer Information */}
      {step === 'info' && (
        <div className="bg-white border border-gray-200 rounded-xl shadow-sm p-4 sm:p-6 mb-6">
          <h2 className="text-lg font-semibold text-gray-900 mb-4">Your Information</h2>

          {submitError && (
            <div className="bg-red-50 border border-red-200 rounded-lg p-3 mb-4">
              <p className="text-red-700 text-sm">{submitError}</p>
            </div>
          )}

          <form onSubmit={handleInfoSubmit} noValidate>
            <div className="space-y-4">
              <div>
                <label htmlFor="buyerName" className="block text-sm font-medium text-gray-700 mb-1">
                  Full Name <span className="text-red-500">*</span>
                </label>
                <input
                  id="buyerName" type="text" value={buyerName}
                  onChange={(e) => { setBuyerName(e.target.value); setFormErrors(prev => ({ ...prev, name: null })) }}
                  className={`w-full px-4 py-3 border rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent ${formErrors.name ? 'border-red-300 bg-red-50' : 'border-gray-300'}`}
                  placeholder="Enter your full name" disabled={submitting}
                />
                {formErrors.name && <p className="text-red-600 text-xs mt-1">{formErrors.name}</p>}
              </div>

              <div>
                <label htmlFor="buyerEmail" className="block text-sm font-medium text-gray-700 mb-1">
                  Email Address <span className="text-red-500">*</span>
                </label>
                <input
                  id="buyerEmail" type="email" value={buyerEmail}
                  onChange={(e) => { setBuyerEmail(e.target.value); setFormErrors(prev => ({ ...prev, email: null })) }}
                  className={`w-full px-4 py-3 border rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent ${formErrors.email ? 'border-red-300 bg-red-50' : 'border-gray-300'}`}
                  placeholder="you@example.com" disabled={submitting}
                />
                {formErrors.email && <p className="text-red-600 text-xs mt-1">{formErrors.email}</p>}
              </div>

              <div>
                <label htmlFor="buyerPhone" className="block text-sm font-medium text-gray-700 mb-1">
                  Phone Number <span className="text-gray-400 font-normal">(optional)</span>
                </label>
                <input
                  id="buyerPhone" type="tel" value={buyerPhone}
                  onChange={(e) => setBuyerPhone(e.target.value)}
                  className="w-full px-4 py-3 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                  placeholder="(671) 555-0123" disabled={submitting}
                />
              </div>
            </div>

            <button
              type="submit" disabled={submitting}
              className="w-full mt-6 bg-orange-500 hover:bg-orange-600 disabled:bg-orange-300 disabled:cursor-not-allowed text-white font-bold py-4 px-6 rounded-lg text-lg transition-colors duration-200"
            >
              {submitting ? 'Setting up payment...' : `Continue to Payment — ${formatPrice(totalCents)}`}
            </button>
          </form>
        </div>
      )}

      {/* Step 2: Payment */}
      {step === 'payment' && clientSecret && (
        <div className="bg-white border border-gray-200 rounded-xl shadow-sm p-4 sm:p-6 mb-6">
          <div className="flex items-center justify-between mb-4">
            <h2 className="text-lg font-semibold text-gray-900">Payment</h2>
            <button
              onClick={() => { setStep('info'); setClientSecret(null); }}
              className="text-sm text-blue-600 hover:text-blue-800"
            >
              Edit info
            </button>
          </div>

          <div className="bg-gray-50 rounded-lg p-3 mb-4 text-sm text-gray-600">
            <span className="font-medium">{buyerName}</span> · {buyerEmail}
          </div>

          <StripeProvider clientSecret={clientSecret}>
            <PaymentForm
              totalCents={totalCents}
              onSuccess={handlePaymentSuccess}
              submitting={submitting}
              setSubmitting={setSubmitting}
            />
          </StripeProvider>
        </div>
      )}

      <p className="text-xs text-gray-400 text-center">
        By completing this purchase you agree to the HafaPass terms of service.
      </p>
    </div>
  )
}
