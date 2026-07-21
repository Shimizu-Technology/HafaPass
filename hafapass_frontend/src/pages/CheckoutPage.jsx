import { useState, useEffect } from 'react'
import { useParams, useNavigate, useLocation, Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { ArrowLeft, Check, Tag, X, Loader2, Calendar, MapPin, Timer } from 'lucide-react'
import apiClient from '../api/client'
import StripeProvider from '../components/StripeProvider'
import PaymentForm from '../components/PaymentForm'
import PaymentModeBanner from '../components/PaymentModeBanner'
import SEO from '../components/SEO'
import { formatEventDate, formatEventTime } from '../utils/eventTime'
import { clearActiveCheckout, getActiveCheckout, orderAccessHeaders, saveActiveCheckout, saveOrderAccess } from '../utils/orderAccess'
import { anonymousId, currentAttribution, trackFunnel } from '../utils/marketplaceAttribution'

export default function CheckoutPage() {
  const { slug } = useParams()
  const navigate = useNavigate()
  const location = useLocation()

  const { t } = useTranslation()
  const [event, setEvent] = useState(location.state?.event || null)
  const [loading, setLoading] = useState(!location.state?.event)
  const lineItems = location.state?.lineItems || null
  const waitlistOfferToken = location.state?.waitlistOfferToken || null
  const seatHoldToken = location.state?.seatHoldToken || null
  const seatHoldExpiresAt = location.state?.seatHoldExpiresAt || null
  const selectedSeats = location.state?.selectedSeats || []
  const liveMoneyProof = location.state?.liveMoneyProof === true
  const [error, setError] = useState(null)
  const [configError, setConfigError] = useState(null)
  const [config, setConfig] = useState(null)

  // Buyer form
  const [buyerName, setBuyerName] = useState('')
  const [buyerEmail, setBuyerEmail] = useState('')
  const [buyerPhone, setBuyerPhone] = useState('')
  const [termsAccepted, setTermsAccepted] = useState(false)
  const [catalogSelections, setCatalogSelections] = useState({})
  const [registrationAnswers, setRegistrationAnswers] = useState({})
  const [acceptedWaivers, setAcceptedWaivers] = useState({})
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
  const [secondsRemaining, setSecondsRemaining] = useState(null)

  useEffect(() => {
    const activeOrderId = getActiveCheckout(slug)
    if (activeOrderId) navigate(`/orders/${activeOrderId}/confirmation`, { replace: true })
  }, [navigate, slug])

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
      apiClient.get(`/events/${slug}`, { params: liveMoneyProof ? { live_money_proof: true } : {} })
        .then(res => { setEvent(res.data); setLoading(false) })
        .catch(() => { setError('Unable to load event details.'); setLoading(false) })
    }
  }, [slug, event, lineItems, navigate, liveMoneyProof])

  useEffect(() => {
    const expiresAt = orderData?.expires_at || seatHoldExpiresAt
    if (!expiresAt) return undefined

    const updateCountdown = () => {
      setSecondsRemaining(Math.max(0, Math.ceil((new Date(expiresAt).getTime() - Date.now()) / 1000)))
    }
    updateCountdown()
    const timer = window.setInterval(updateCountdown, 1000)
    return () => window.clearInterval(timer)
  }, [orderData?.expires_at, seatHoldExpiresAt])

  const formatPrice = (cents) => cents === 0 ? t('events.free') : `$${(cents / 100).toFixed(2)}`
  const formatDate = (dateStr) => formatEventDate(dateStr, event?.timezone, { weekday: 'short' })
  const formatTime = (dateStr) => formatEventTime(dateStr, event?.timezone)

  // Promo code validation
  const handlePromoValidate = async () => {
    if (!promoInput.trim()) return

    const orderLines = lineItems?.map(item => {
      const tt = event?.ticket_types?.find(t => t.id === item.ticket_type_id)
      return tt ? (tt.current_price_cents ?? tt.price_cents) * item.quantity : 0
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
    if (!termsAccepted) errors.terms = 'You must accept the buyer terms to continue'
    event?.registration_questions?.forEach(question => {
      const answer = registrationAnswers[question.id]
      if (question.required && (answer === undefined || answer === null || answer === '')) errors[`question_${question.id}`] = 'This answer is required'
    })
    event?.waivers?.forEach(waiver => {
      if (waiver.required && !acceptedWaivers[waiver.id]) errors[`waiver_${waiver.id}`] = 'You must accept this waiver'
    })
    return errors
  }

  const handleInfoSubmit = async (e) => {
    e.preventDefault()
    setSubmitError(null)
    const errors = validateForm()
    if (Object.keys(errors).length > 0) { setFormErrors(errors); return }

    setSubmitting(true)
    try {
      trackFunnel(apiClient, event.id, 'checkout_started')
      const storedAttribution = currentAttribution()
      const payload = {
        event_id: event.id,
        buyer_name: buyerName.trim(),
        buyer_email: buyerEmail.trim(),
        buyer_phone: buyerPhone.trim() || null,
        line_items: lineItems.map(item => ({ ticket_type_id: item.ticket_type_id, quantity: item.quantity })),
        promo_code_id: promoData?.promo_code_id || null,
        catalog_items: Object.entries(catalogSelections).filter(([, value]) => value.quantity > 0).map(([id, value]) => ({
          catalog_item_id: Number(id), quantity: value.quantity,
          amount_cents: event.catalog_items?.find(item => item.id === Number(id))?.kind === 'donation' ? (value.amount_cents || null) : null,
        })),
        registration_answers: registrationAnswers,
        waiver_acceptances: (event.waivers || []).filter(waiver => acceptedWaivers[waiver.id]).map(waiver => ({ event_waiver_id: waiver.id, version: waiver.version })),
        referral_code: new URLSearchParams(location.search).get('ref'),
        attribution: {
          source: new URLSearchParams(location.search).get('utm_source') || storedAttribution.source,
          medium: new URLSearchParams(location.search).get('utm_medium') || storedAttribution.medium,
          campaign: new URLSearchParams(location.search).get('utm_campaign') || storedAttribution.campaign,
          distribution_code: storedAttribution.distribution_code,
          event_referral_code: storedAttribution.event_referral_code,
          anonymous_id: anonymousId(),
        },
        waitlist_offer_token: waitlistOfferToken,
        seat_hold_token: seatHoldToken,
        terms_accepted: termsAccepted,
        terms_version: config.buyer_terms_version,
        live_money_proof: liveMoneyProof,
      }
      const response = await apiClient.post('/orders', payload)
      const order = response.data
      saveOrderAccess(order.id, order.guest_access_token)
      saveActiveCheckout(slug, order.id)

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

  if (!config) return (
    <div className="flex justify-center py-20">
      <Loader2 className="w-8 h-8 text-brand-500 animate-spin" />
    </div>
  )

  const feePercent = parseFloat(config.service_fee_percent) || 3.0
  const feeFlatCents = config ? config.service_fee_flat_cents : 50

  const orderLines = lineItems.map(item => {
    const tt = event.ticket_types.find(t => t.id === item.ticket_type_id)
    if (!tt) return null
    const price = tt.current_price_cents ?? tt.price_cents
    return { ...item, name: tt.name, price_cents: price, lineTotal: price * item.quantity, active_tier: tt.active_tier }
  }).filter(Boolean)

  const totalTickets = orderLines.reduce((s, l) => s + l.quantity, 0)
  const subtotalCents = orderLines.reduce((s, l) => s + l.lineTotal, 0)
  const catalogSubtotalCents = Object.entries(catalogSelections).reduce((sum, [id, selection]) => {
    const item = event.catalog_items?.find(candidate => candidate.id === Number(id))
    if (!item || !selection.quantity) return sum
    return sum + (item.kind === 'donation' ? (selection.amount_cents || 0) : item.price_cents) * selection.quantity
  }, 0)
  const platformFeeCents = subtotalCents === 0 ? 0 : Math.round(subtotalCents * (feePercent / 100)) + (totalTickets * feeFlatCents)
  const serviceFeeCents = Math.round(platformFeeCents * ((event.buyer_fee_percent ?? 100) / 100))
  const discountCents = promoData?.discount_cents || 0
  const totalCents = Math.max(subtotalCents + catalogSubtotalCents + serviceFeeCents - discountCents, 0)
  const displayedSubtotal = orderData?.subtotal_cents ?? (subtotalCents + catalogSubtotalCents)
  const displayedFee = orderData?.service_fee_cents ?? serviceFeeCents
  const displayedDiscount = orderData?.discount_cents ?? discountCents
  const displayedTotal = orderData?.total_cents ?? totalCents
  const checkoutExpired = secondsRemaining === 0
  const countdownLabel = secondsRemaining === null
    ? null
    : `${Math.floor(secondsRemaining / 60)}:${String(secondsRemaining % 60).padStart(2, '0')}`

  const paymentMode = config?.payment_mode || 'simulate'
  const isSimulate = paymentMode === 'simulate'

  return (
    <div className="bg-neutral-50 min-h-screen">
      <SEO title={event ? `Checkout — ${event.title}` : 'Checkout'} noIndex={liveMoneyProof} />
      <div className="max-w-2xl mx-auto px-4 sm:px-6 py-8">
        {/* Back link */}
        <Link to={`/events/${slug}`} className="inline-flex items-center gap-1.5 text-neutral-500 hover:text-neutral-900 mb-6 text-sm font-medium transition-colors">
          <ArrowLeft className="w-4 h-4" />
          {t('checkout.backToEvent')}
        </Link>

        <h1 className="text-2xl sm:text-3xl font-bold text-neutral-900 tracking-tight mb-2">{t('checkout.title')}</h1>
        <PaymentModeBanner mode={paymentMode} />

        {/* Progress */}
        <div className="flex items-center gap-3 mb-6">
          <div className={`flex items-center gap-1.5 text-sm font-medium ${step === 'info' ? 'text-brand-500' : 'text-emerald-600'}`}>
            {step === 'payment'
              ? <div className="w-5 h-5 rounded-full bg-emerald-500 flex items-center justify-center"><Check className="w-3 h-3 text-white" /></div>
              : <span className="w-5 h-5 rounded-full bg-brand-500 text-white text-xs flex items-center justify-center">1</span>
            }
            {t('checkout.yourInfo')}
          </div>
          <div className="w-8 h-px bg-neutral-200" />
          <div className={`flex items-center gap-1.5 text-sm font-medium ${step === 'payment' ? 'text-brand-500' : 'text-neutral-400'}`}>
            <span className={`w-5 h-5 rounded-full text-xs flex items-center justify-center ${step === 'payment' ? 'bg-brand-500 text-white' : 'bg-neutral-200 text-neutral-500'}`}>2</span>
            {t('checkout.payment')}
          </div>
        </div>

        {/* Event summary card */}
        <div className="card p-4 mb-6 flex items-center gap-4">
          {event.cover_image_url && (
            <div className="w-16 h-16 sm:w-20 sm:h-20 rounded-xl overflow-hidden flex-shrink-0">
              <img src={event.cover_image_url} alt={event.title} className="w-full h-full object-cover" />
            </div>
          )}
          <div className="min-w-0">
            <p className="font-semibold text-neutral-900 truncate">{event.title}</p>
            <p className="text-sm text-neutral-500 flex items-center gap-1.5 mt-0.5">
              <Calendar className="w-3.5 h-3.5 flex-shrink-0" />
              {event.starts_at && formatDate(event.starts_at)} · {event.starts_at && formatTime(event.starts_at)}
            </p>
            {event.venue_name && (
              <p className="text-sm text-neutral-500 flex items-center gap-1.5 mt-0.5">
                <MapPin className="w-3.5 h-3.5 flex-shrink-0" />
                {event.venue_name}
              </p>
            )}
          </div>
        </div>

        {/* Order Summary */}
        <div className="card p-5 sm:p-6 mb-6">
          <h2 className="text-base font-semibold text-neutral-900 mb-4">{t('checkout.orderSummary')}</h2>
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
            {selectedSeats.length > 0 && (
              <div className="rounded-xl bg-neutral-50 p-3">
                <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Assigned seats</p>
                <ul className="mt-1 space-y-1 text-sm text-neutral-700">
                  {selectedSeats.map(seat => <li key={seat.id}>{seat.display_label}</li>)}
                </ul>
              </div>
            )}
          </div>
          {seatHoldToken && countdownLabel && step === 'info' && (
            <div className={`mb-4 flex items-center gap-2 rounded-xl border px-3 py-2.5 text-sm ${checkoutExpired ? 'border-red-200 bg-red-50 text-red-700' : 'border-amber-200 bg-amber-50 text-amber-800'}`}>
              <Timer className="h-4 w-4" />
              {checkoutExpired ? 'Your seat hold expired. Return to the event and select seats again.' : `Seats held for ${countdownLabel}`}
            </div>
          )}
          <hr className="border-neutral-100 my-4" />
          <div className="space-y-2 text-sm">
            <div className="flex justify-between"><span className="text-neutral-500">{t('checkout.subtotal')}</span><span>{formatPrice(displayedSubtotal)}</span></div>
            <div className="flex justify-between"><span className="text-neutral-500">{t('checkout.serviceFee')}</span><span>{formatPrice(displayedFee)}</span></div>
            {displayedDiscount > 0 && (
              <div className="flex justify-between text-emerald-600">
                <span className="flex items-center gap-1"><Tag className="w-3 h-3" /> {promoData.code}</span>
                <span>-{formatPrice(displayedDiscount)}</span>
              </div>
            )}
          </div>
          <hr className="border-neutral-100 my-4" />
          <div className="flex justify-between items-center">
            <span className="font-bold text-lg text-neutral-900">{t('checkout.total')}</span>
            <span className="font-bold text-lg text-neutral-900">{formatPrice(displayedTotal)}</span>
          </div>
        </div>

        {/* Promo Code (HP-7) */}
        {step === 'info' && (
          <div className="mb-6">
            {!showPromo && !promoData ? (
              <button onClick={() => setShowPromo(true)} className="text-sm text-brand-500 hover:text-brand-600 font-medium flex items-center gap-1.5 transition-colors">
                <Tag className="w-3.5 h-3.5" /> {t('checkout.havePromoCode')}
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
                  placeholder={t('checkout.enterCode')} className="input flex-1 !py-2.5 text-sm uppercase"
                  onKeyDown={(e) => e.key === 'Enter' && handlePromoValidate()}
                />
                <button onClick={handlePromoValidate} disabled={promoLoading || !promoInput.trim()}
                  className="btn-secondary !py-2.5 text-sm disabled:opacity-50">
                  {promoLoading ? <Loader2 className="w-4 h-4 animate-spin" /> : t('checkout.apply')}
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
            <h2 className="text-base font-semibold text-neutral-900 mb-4">{t('checkout.yourInformation')}</h2>
            {submitError && (
              <div className="bg-red-50 border border-red-200 rounded-xl p-3 mb-4">
                <p className="text-red-700 text-sm">{submitError}</p>
              </div>
            )}
            <form onSubmit={handleInfoSubmit} noValidate>
              <div className="space-y-4">
                <div>
                  <label htmlFor="buyerName" className="block text-sm font-medium text-neutral-700 mb-1.5">{t('checkout.fullName')}</label>
                  <input id="buyerName" type="text" value={buyerName}
                    onChange={(e) => { setBuyerName(e.target.value); setFormErrors(p => ({ ...p, name: null })) }}
                    className={`input ${formErrors.name ? 'input-error' : ''}`}
                    placeholder="Enter your full name" disabled={submitting} />
                  {formErrors.name && <p className="text-red-500 text-xs mt-1">{formErrors.name}</p>}
                </div>
                <div>
                  <label htmlFor="buyerEmail" className="block text-sm font-medium text-neutral-700 mb-1.5">{t('checkout.emailAddress')}</label>
                  <input id="buyerEmail" type="email" value={buyerEmail}
                    onChange={(e) => { setBuyerEmail(e.target.value); setFormErrors(p => ({ ...p, email: null })) }}
                    className={`input ${formErrors.email ? 'input-error' : ''}`}
                    placeholder="you@example.com" disabled={submitting} />
                  {formErrors.email && <p className="text-red-500 text-xs mt-1">{formErrors.email}</p>}
                </div>
                <div>
                  <label htmlFor="buyerPhone" className="block text-sm font-medium text-neutral-700 mb-1.5">
                    {t('checkout.phone')} <span className="text-neutral-400 font-normal">({t('checkout.optional')})</span>
                  </label>
                  <input id="buyerPhone" type="tel" value={buyerPhone}
                    onChange={(e) => setBuyerPhone(e.target.value)}
                    className="input" placeholder="(671) 555-0123" disabled={submitting} />
                </div>
                {event.catalog_items?.length > 0 && (
                  <fieldset className="rounded-xl border border-neutral-200 p-4">
                    <legend className="px-1 text-sm font-semibold text-neutral-900">Extras and support</legend>
                    <div className="space-y-3">
                      {event.catalog_items.map(item => {
                        const selection = catalogSelections[item.id] || { quantity: 0, amount_cents: item.minimum_price_cents || item.price_cents }
                        return <div key={item.id} className="flex items-center justify-between gap-3">
                          <div><p className="text-sm font-medium text-neutral-800">{item.name}</p><p className="text-xs text-neutral-500">{item.description || (item.kind === 'donation' ? 'Support this event' : formatPrice(item.price_cents))}</p></div>
                          <div className="flex items-center gap-2">
                            {item.kind === 'donation' && selection.quantity > 0 && <label className="text-xs text-neutral-500">$<input aria-label={`${item.name} amount`} type="number" min={(item.minimum_price_cents || item.price_cents) / 100} max={item.maximum_price_cents ? item.maximum_price_cents / 100 : undefined} step="1" value={(selection.amount_cents || 0) / 100} onChange={e => setCatalogSelections(previous => ({ ...previous, [item.id]: { ...selection, amount_cents: Math.round(Number(e.target.value) * 100) } }))} className="ml-1 w-20 rounded-lg border border-neutral-300 px-2 py-1" /></label>}
                            <input aria-label={`${item.name} quantity`} type="number" min="0" max={item.quantity_remaining || 10} value={selection.quantity} onChange={e => setCatalogSelections(previous => ({ ...previous, [item.id]: { ...selection, quantity: Math.max(0, Number(e.target.value) || 0) } }))} className="w-16 rounded-lg border border-neutral-300 px-2 py-1.5 text-sm" />
                          </div>
                        </div>
                      })}
                    </div>
                  </fieldset>
                )}
                {event.registration_questions?.length > 0 && (
                  <fieldset className="rounded-xl border border-neutral-200 p-4">
                    <legend className="px-1 text-sm font-semibold text-neutral-900">Registration</legend>
                    <div className="space-y-4">
                      {event.registration_questions.map(question => <div key={question.id}>
                        <label className="mb-1 block text-sm font-medium text-neutral-700" htmlFor={`question-${question.id}`}>{question.prompt}{question.required && ' *'}</label>
                        {question.kind === 'selection' ? <select id={`question-${question.id}`} className="input" value={registrationAnswers[question.id] || ''} onChange={e => setRegistrationAnswers(previous => ({ ...previous, [question.id]: e.target.value }))}><option value="">Select one</option>{question.options.map(option => <option key={option} value={option}>{option}</option>)}</select>
                          : question.kind === 'checkbox' ? <input id={`question-${question.id}`} type="checkbox" checked={Boolean(registrationAnswers[question.id])} onChange={e => setRegistrationAnswers(previous => ({ ...previous, [question.id]: e.target.checked }))} />
                            : question.kind === 'long_text' ? <textarea id={`question-${question.id}`} className="input" rows="3" value={registrationAnswers[question.id] || ''} onChange={e => setRegistrationAnswers(previous => ({ ...previous, [question.id]: e.target.value }))} />
                              : <input id={`question-${question.id}`} className="input" value={registrationAnswers[question.id] || ''} onChange={e => setRegistrationAnswers(previous => ({ ...previous, [question.id]: e.target.value }))} />}
                        {formErrors[`question_${question.id}`] && <p className="mt-1 text-xs text-red-500">{formErrors[`question_${question.id}`]}</p>}
                      </div>)}
                    </div>
                  </fieldset>
                )}
                {event.waivers?.map(waiver => (
                  <div key={waiver.id} className="rounded-xl border border-neutral-200 p-4">
                    <p className="text-sm font-semibold text-neutral-900">{waiver.title}</p>
                    <div className="my-2 max-h-32 overflow-y-auto whitespace-pre-wrap text-xs text-neutral-600">{waiver.body}</div>
                    <label className="flex items-start gap-2 text-sm text-neutral-700"><input type="checkbox" checked={Boolean(acceptedWaivers[waiver.id])} onChange={e => setAcceptedWaivers(previous => ({ ...previous, [waiver.id]: e.target.checked }))} className="mt-0.5" />I accept version {waiver.version}{waiver.required && ' *'}</label>
                    {formErrors[`waiver_${waiver.id}`] && <p className="mt-1 text-xs text-red-500">{formErrors[`waiver_${waiver.id}`]}</p>}
                  </div>
                ))}
                <div>
                  <label className="flex items-start gap-3 text-sm text-neutral-600" htmlFor="termsAccepted">
                    <input
                      id="termsAccepted"
                      type="checkbox"
                      checked={termsAccepted}
                      onChange={(event) => {
                        setTermsAccepted(event.target.checked)
                        setFormErrors(previous => ({ ...previous, terms: null }))
                      }}
                      className="mt-0.5 h-4 w-4 rounded border-neutral-300 text-brand-600 focus:ring-brand-500"
                      disabled={submitting}
                    />
                    <span>
                      I agree to the <Link className="text-brand-600 underline" to="/policies/buyer-terms" target="_blank">Buyer Terms</Link>,{' '}
                      <Link className="text-brand-600 underline" to="/policies/refunds" target="_blank">refund and cancellation policy</Link>, and{' '}
                      <Link className="text-brand-600 underline" to="/policies/privacy" target="_blank">Privacy Policy</Link>.
                    </span>
                  </label>
                  {formErrors.terms && <p className="text-red-500 text-xs mt-1" role="alert">{formErrors.terms}</p>}
                </div>
              </div>
              <button type="submit" disabled={submitting || checkoutExpired} className="w-full mt-6 btn-primary text-base !py-4 hover:-translate-y-0.5 hover:shadow-lg hover:shadow-brand-500/25 active:translate-y-0 transition-all duration-200">
                {submitting
                  ? (isSimulate ? t('checkout.placingOrder') : t('checkout.settingUpPayment'))
                  : (isSimulate ? `${t('checkout.placeOrder')} \u2014 ${formatPrice(displayedTotal)}` : `${t('checkout.continueToPayment')} \u2014 ${formatPrice(displayedTotal)}`)}
              </button>
            </form>
          </div>
        )}

        {/* Step 2: Payment */}
        {step === 'payment' && clientSecret && stripePublishableKey && (
          <div className="card p-5 sm:p-6 mb-6">
            <div className="flex items-center justify-between mb-4">
              <h2 className="text-base font-semibold text-neutral-900">Payment</h2>
              <button onClick={() => {
                if (orderId) {
                  apiClient.post(`/orders/${orderId}/cancel`, {}, { headers: orderAccessHeaders(orderId) }).catch((err) => {
                  alert(`Warning: Could not cancel order. ${err.response?.data?.error || 'Please contact support.'}`)
                  console.warn('Failed to cancel order:', err.response?.data?.error || err.message)
                })
                }
                clearActiveCheckout(slug)
                setStep('info')
                setClientSecret(null)
                setStripePublishableKey(null)
                setOrderId(null)
                setOrderData(null)
              }}
                className="text-sm text-brand-500 hover:text-brand-600 font-medium">{t('checkout.editInfo')}</button>
            </div>
            <div className="bg-neutral-50 rounded-xl p-3 mb-4 text-sm text-neutral-600">
              <span className="font-medium">{buyerName}</span> &middot; {buyerEmail}
            </div>
            {countdownLabel && (
              <div className={`mb-4 flex items-center gap-2 rounded-xl border px-3 py-2.5 text-sm ${checkoutExpired ? 'border-red-200 bg-red-50 text-red-700' : 'border-amber-200 bg-amber-50 text-amber-800'}`}>
                <Timer className="h-4 w-4" />
                {checkoutExpired ? 'Your ticket hold expired. Return to the event to start again.' : `Tickets held for ${countdownLabel}`}
              </div>
            )}
            <PaymentModeBanner mode={paymentMode} />
            <div className="relative z-[60]">
              <StripeProvider publishableKey={stripePublishableKey} clientSecret={clientSecret}>
                {!checkoutExpired && (
                  <PaymentForm
                    totalCents={displayedTotal}
                    returnUrl={`${window.location.origin}/orders/${orderId}/confirmation`}
                    onSuccess={handlePaymentSuccess}
                    submitting={submitting}
                    setSubmitting={setSubmitting}
                  />
                )}
              </StripeProvider>
            </div>
          </div>
        )}

        <p className="text-xs text-neutral-400 text-center">
          {t('checkout.termsNotice')}
        </p>
      </div>
    </div>
  )
}
