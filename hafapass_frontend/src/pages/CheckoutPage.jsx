import { useState, useEffect } from 'react'
import { useParams, useNavigate, useLocation, Link } from 'react-router-dom'
import { ArrowLeft, Check, Tag, X, Loader2 } from 'lucide-react'
import apiClient from '../api/client'
import StripeProvider from '../components/StripeProvider'
import PaymentForm from '../components/PaymentForm'
import PaymentModeBanner from '../components/PaymentModeBanner'

export default function CheckoutPage() {
  const { slug } = useParams()
  const navigate = useNavigate()
  const location = useLocation()

  const [event, setEvent] = useState(location.state?.event || null)
  const [loading, setLoading] = useState(!location.state?.event)
  const lineItems = location.state?.lineItems || null
  const [error, setError] = useState(null)
  const [configError, setConfigError] = useState(null)
  const [config, setConfig] = useState(null)

  // Buyer form
  const [buyerName, setBuyerName] = useState('')
  const [buyerEmail, setBuyerEmail] = useState('')
  const [buyerPhone, setBuyerPhone] = useState('')
  const [formErrors, setFormErrors] = useState({})
  const [submitting, setSubmitting] = useState(false)
  const [submitError, setSubmitError] = useState(null)

  // Promo code (HP-7)
  const [promoInput, setPromoInput] = useState('')
  const [promoLoading, setPromoLoading] = useState(false)
  const [promoData, setPromoData] = useState(null)
  const [promoError, setPromoError] = useState(null)
  const [showPromo, setShowPromo] = useState(false)

  // Stripe
  const [clientSecret, setClientSecret] = useState(null)
  const [stripePublishableKey, setStripePublishableKey] = useState(null)
  const [orderId, setOrderId] = useState(null)
  const [orderData, setOrderData] = useState(null)
  const [step, setStep] = useState('info')

  useEffect(() => {
    apiClient.get('/config')
      .then(res => setConfig(res.data))
      .catch((err) => {
        console.error('Failed to load payment config:', err)
        setConfigError('Unable to load payment configuration. Please try again later.')
      })
  }, [])

  useEffect(() => {
    if (!lineItems || lineItems.length === 0) {
      navigate(`/events/${slug}`, { replace: true })
      return
    }
    if (!event) {
      setLoading(true)
      apiClient.get(`/events/${slug}`)
        .then(res => { setEvent(res.data); setLoading(false) })
        .catch(() => { setError('Unable to load event details.'); setLoading(false) })
    }
  }, [slug, event, lineItems, navigate])

  const formatPrice = (cents) => cents === 0 ? 'Free' : `$${(cents / 100).toFixed(2)}`
  const formatDate = (dateStr) => new Date(dateStr).toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' })
  const formatTime = (dateStr) => new Date(dateStr).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' })

  // Promo code validation
  const handlePromoValidate = async () => {
    if (!promoInput.trim()) return

    // Compute subtotal locally (can't rely on the variable defined later in render)
    const orderLines = lineItems?.map(item => {
      const tt = event?.ticket_types?.find(t => t.id === item.ticket_type_id)
      return tt ? tt.price_cents * item.quantity : 0
    }) || []
    const currentSubtotal = orderLines.reduce((s, l) => s + l, 0)

    setPromoLoading(true)
    setPromoError(null)
    try {
      const res = await apiClient.post('/promo_codes/validate', {
        event_id: event.id,
        code: promoInput.trim(),
        subtotal_cents: currentSubtotal,
      })
      if (res.data.valid) {
        setPromoData(res.data)
        setPromoError(null)
      } else {
        setPromoData(null)
        setPromoError(res.data.error || 'Invalid code')
      }
    } catch {
      setPromoError('Could not validate code')
    } finally {
      setPromoLoading(false)
    }
  }

  const clearPromo = () => {
    setPromoData(null)
    setPromoInput('')
    setPromoError(null)
  }

  const validateForm = () => {
    const errors = {}
    if (!buyerName.trim()) errors.name = 'Name is required'
    if (!buyerEmail.trim()) errors.email = 'Email is required'
    else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(buyerEmail.trim())) errors.email = 'Please enter a valid email'
    return errors
  }

  const handleInfoSubmit = async (e) => {
    e.preventDefault()
    setSubmitError(null)
    const errors = validateForm()
    if (Object.keys(errors).length > 0) { setFormErrors(errors); return }

    setSubmitting(true)
    try {
      const payload = {
        event_id: event.id,
        buyer_name: buyerName.trim(),
        buyer_email: buyerEmail.trim(),
        buyer_phone: buyerPhone.trim() || null,
        line_items: lineItems.map(item => ({ ticket_type_id: item.ticket_type_id, quantity: item.quantity })),
        promo_code_id: promoData?.promo_code_id || null,
      }
      const response = await apiClient.post('/orders', payload)
      const order = response.data

      if (order.client_secret && order.stripe_publishable_key) {
        setClientSecret(order.client_secret)
        setStripePublishableKey(order.stripe_publishable_key)
        setOrderId(order.id)
        setOrderData(order)
        setStep('payment')
      } else {
        navigate(`/orders/${order.id}/confirmation`, { state: { order, event }, replace: true })
      }
    } catch (err) {
      setSubmitError(err.response?.data?.error || 'Something went wrong.')
    } finally {
      setSubmitting(false)
    }
  }

  const handlePaymentSuccess = (paymentIntent) => {
    navigate(`/orders/${orderId}/confirmation`, { state: { order: orderData, event, paymentIntent }, replace: true })
  }

  if (configError) return (
    <div className="min-h-screen flex items-center justify-center bg-neutral-50 px-4">
      <div className="text-center">
        <p className="text-red-600 mb-4">{configError}</p>
        <button onClick={() => window.location.reload()} className="btn-primary">Retry</button>
      </div>
    </div>
  )

  if (loading) return (
    <div className="flex justify-center py-20">
      <Loader2 className="w-8 h-8 text-brand-500 animate-spin" />
    </div>
  )

  if (error) return (
    <div className="max-w-2xl mx-auto px-4 py-16">
      <div className="card p-8 text-center">
        <p className="text-red-600 mb-4">{error}</p>
        <Link to={`/events/${slug}`} className="btn-primary">Back to Event</Link>
      </div>
    </div>
  )

  if (!event || !lineItems) return null

  const feePercent = config ? parseFloat(config.service_fee_percent) : 3.0
  const feeFlatCents = config ? config.service_fee_flat_cents : 50

  const orderLines = lineItems.map(item => {
    const tt = event.ticket_types.find(t => t.id === item.ticket_type_id)
    if (!tt) return null
    return { ...item, name: tt.name, price_cents: tt.price_cents, lineTotal: tt.price_cents * item.quantity }
  }).filter(Boolean)

  const totalTickets = orderLines.reduce((s, l) => s + l.quantity, 0)
  const subtotalCents = orderLines.reduce((s, l) => s + l.lineTotal, 0)
  const serviceFeeCents = Math.round(subtotalCents * (feePercent / 100)) + (totalTickets * feeFlatCents)
  const discountCents = promoData?.discount_cents || 0
  const totalCents = Math.max(subtotalCents + serviceFeeCents - discountCents, 0)

  const paymentMode = config?.payment_mode || 'simulate'
  const isSimulate = paymentMode === 'simulate'

  return (
    <div className="max-w-2xl mx-auto px-4 sm:px-6 py-8">
      {/* Back link */}
      <Link to={`/events/${slug}`} className="inline-flex items-center gap-1.5 text-neutral-500 hover:text-neutral-900 mb-6 text-sm font-medium transition-colors">
        <ArrowLeft className="w-4 h-4" />
        Back to Event
      </Link>

      <h1 className="text-2xl sm:text-3xl font-bold text-neutral-900 tracking-tight mb-2">Checkout</h1>
      <PaymentModeBanner mode={paymentMode} />

      {/* Progress */}
      <div className="flex items-center gap-3 mb-6">
        <div className={`flex items-center gap-1.5 text-sm font-medium ${step === 'info' ? 'text-brand-500' : 'text-emerald-600'}`}>
          {step === 'payment'
            ? <div className="w-5 h-5 rounded-full bg-emerald-500 flex items-center justify-center"><Check className="w-3 h-3 text-white" /></div>
            : <span className="w-5 h-5 rounded-full bg-brand-500 text-white text-xs flex items-center justify-center">1</span>
          }
          Your Info
        </div>
        <div className="w-8 h-px bg-neutral-200" />
        <div className={`flex items-center gap-1.5 text-sm font-medium ${step === 'payment' ? 'text-brand-500' : 'text-neutral-400'}`}>
          <span className={`w-5 h-5 rounded-full text-xs flex items-center justify-center ${step === 'payment' ? 'bg-brand-500 text-white' : 'bg-neutral-200 text-neutral-500'}`}>2</span>
          Payment
        </div>
      </div>

      {/* Event info */}
      <div className="mb-6">
        <p className="font-semibold text-neutral-900">{event.title}</p>
        <p className="text-sm text-neutral-500">
          {event.starts_at && formatDate(event.starts_at)} &middot; {event.starts_at && formatTime(event.starts_at)}
          {event.venue_name && ` · ${event.venue_name}`}
        </p>
      </div>

      {/* Order Summary */}
      <div className="card p-5 sm:p-6 mb-6">
        <h2 className="text-base font-semibold text-neutral-900 mb-4">Order Summary</h2>
        <div className="space-y-3 mb-4">
          {orderLines.map(line => (
            <div key={line.ticket_type_id} className="flex justify-between items-center">
              <div>
                <span className="text-neutral-800 font-medium text-sm">{line.name}</span>
                <span className="text-neutral-400 ml-2 text-sm">&times; {line.quantity}</span>
              </div>
              <span className="text-neutral-900 font-medium text-sm">{formatPrice(line.lineTotal)}</span>
            </div>
          ))}
        </div>
        <hr className="border-neutral-100 my-4" />
        <div className="space-y-2 text-sm">
          <div className="flex justify-between"><span className="text-neutral-500">Subtotal</span><span>{formatPrice(subtotalCents)}</span></div>
          <div className="flex justify-between"><span className="text-neutral-500">Service fee</span><span>{formatPrice(serviceFeeCents)}</span></div>
          {discountCents > 0 && (
            <div className="flex justify-between text-emerald-600">
              <span className="flex items-center gap-1"><Tag className="w-3 h-3" /> {promoData.code}</span>
              <span>-{formatPrice(discountCents)}</span>
            </div>
          )}
        </div>
        <hr className="border-neutral-100 my-4" />
        <div className="flex justify-between items-center">
          <span className="font-bold text-lg text-neutral-900">Total</span>
          <span className="font-bold text-lg text-neutral-900">{formatPrice(totalCents)}</span>
        </div>
      </div>

      {/* Promo Code (HP-7) */}
      {step === 'info' && (
        <div className="mb-6">
          {!showPromo && !promoData ? (
            <button onClick={() => setShowPromo(true)} className="text-sm text-brand-500 hover:text-brand-600 font-medium flex items-center gap-1.5 transition-colors">
              <Tag className="w-3.5 h-3.5" /> Have a promo code?
            </button>
          ) : promoData ? (
            <div className="flex items-center justify-between bg-emerald-50 border border-emerald-200 rounded-xl px-4 py-3">
              <div className="flex items-center gap-2">
                <Tag className="w-4 h-4 text-emerald-600" />
                <span className="text-sm font-medium text-emerald-700">{promoData.code}</span>
                <span className="text-xs text-emerald-600">{promoData.description}</span>
              </div>
              <button onClick={clearPromo} className="text-emerald-600 hover:text-emerald-800 transition-colors">
                <X className="w-4 h-4" />
              </button>
            </div>
          ) : (
            <div className="flex gap-2">
              <input
                type="text" value={promoInput} onChange={(e) => setPromoInput(e.target.value.toUpperCase())}
                placeholder="Enter code" className="input flex-1 !py-2.5 text-sm uppercase"
                onKeyDown={(e) => e.key === 'Enter' && handlePromoValidate()}
              />
              <button onClick={handlePromoValidate} disabled={promoLoading || !promoInput.trim()}
                className="btn-secondary !py-2.5 text-sm disabled:opacity-50">
                {promoLoading ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Apply'}
              </button>
              <button onClick={() => { setShowPromo(false); setPromoError(null) }} className="text-neutral-400 hover:text-neutral-600">
                <X className="w-4 h-4" />
              </button>
            </div>
          )}
          {promoError && <p className="text-red-500 text-xs mt-1.5">{promoError}</p>}
        </div>
      )}

      {/* Step 1: Info */}
      {step === 'info' && (
        <div className="card p-5 sm:p-6 mb-6">
          <h2 className="text-base font-semibold text-neutral-900 mb-4">Your Information</h2>
          {submitError && (
            <div className="bg-red-50 border border-red-200 rounded-xl p-3 mb-4">
              <p className="text-red-700 text-sm">{submitError}</p>
            </div>
          )}
          <form onSubmit={handleInfoSubmit} noValidate>
            <div className="space-y-4">
              <div>
                <label htmlFor="buyerName" className="block text-sm font-medium text-neutral-700 mb-1.5">Full Name</label>
                <input id="buyerName" type="text" value={buyerName}
                  onChange={(e) => { setBuyerName(e.target.value); setFormErrors(p => ({ ...p, name: null })) }}
                  className={`input ${formErrors.name ? 'input-error' : ''}`}
                  placeholder="Enter your full name" disabled={submitting} />
                {formErrors.name && <p className="text-red-500 text-xs mt-1">{formErrors.name}</p>}
              </div>
              <div>
                <label htmlFor="buyerEmail" className="block text-sm font-medium text-neutral-700 mb-1.5">Email Address</label>
                <input id="buyerEmail" type="email" value={buyerEmail}
                  onChange={(e) => { setBuyerEmail(e.target.value); setFormErrors(p => ({ ...p, email: null })) }}
                  className={`input ${formErrors.email ? 'input-error' : ''}`}
                  placeholder="you@example.com" disabled={submitting} />
                {formErrors.email && <p className="text-red-500 text-xs mt-1">{formErrors.email}</p>}
              </div>
              <div>
                <label htmlFor="buyerPhone" className="block text-sm font-medium text-neutral-700 mb-1.5">
                  Phone <span className="text-neutral-400 font-normal">(optional)</span>
                </label>
                <input id="buyerPhone" type="tel" value={buyerPhone}
                  onChange={(e) => setBuyerPhone(e.target.value)}
                  className="input" placeholder="(671) 555-0123" disabled={submitting} />
              </div>
            </div>
            <button type="submit" disabled={submitting} className="w-full mt-6 btn-primary text-base !py-4">
              {submitting
                ? (isSimulate ? 'Placing order...' : 'Setting up payment...')
                : (isSimulate ? `Place Order \u2014 ${formatPrice(totalCents)}` : `Continue to Payment \u2014 ${formatPrice(totalCents)}`)}
            </button>
          </form>
        </div>
      )}

      {/* Step 2: Payment */}
      {step === 'payment' && clientSecret && stripePublishableKey && (
        <div className="card p-5 sm:p-6 mb-6">
          <div className="flex items-center justify-between mb-4">
            <h2 className="text-base font-semibold text-neutral-900">Payment</h2>
            <button onClick={() => { setStep('info'); setClientSecret(null); setStripePublishableKey(null) }}
              className="text-sm text-brand-500 hover:text-brand-600 font-medium">Edit info</button>
          </div>
          <div className="bg-neutral-50 rounded-xl p-3 mb-4 text-sm text-neutral-600">
            <span className="font-medium">{buyerName}</span> &middot; {buyerEmail}
          </div>
          <PaymentModeBanner mode={paymentMode} />
          <StripeProvider publishableKey={stripePublishableKey} clientSecret={clientSecret}>
            <PaymentForm totalCents={totalCents} onSuccess={handlePaymentSuccess} submitting={submitting} setSubmitting={setSubmitting} />
          </StripeProvider>
        </div>
      )}

      <p className="text-xs text-neutral-400 text-center">
        By completing this purchase you agree to the HafaPass terms of service.
      </p>
    </div>
  )
}
