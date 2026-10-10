import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { useAuth } from '@clerk/clerk-react'
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom'
import { AlertTriangle, CheckCircle, ChevronRight, Clock3, Download, Loader2, Mail, RefreshCw } from 'lucide-react'
import apiClient from '../api/client'
import { supportMailto } from '../utils/supportContact'
import useLaunchCapabilities from '../hooks/useLaunchCapabilities'
import SEO from '../components/SEO'
import { formatEventDate, formatEventTime } from '../utils/eventTime'
import { checkoutBuyerIdentity, clearActiveCheckout, getBuyerRefundAttempt, getOrderAccess, orderAccessHeaders, prepareBuyerRefundAttempt, recordBuyerRefundOutcome, saveOrderAccess } from '../utils/orderAccess'

const emailInFlightStatuses = new Set(['queued', 'sent'])
const EMAIL_REFRESH_INTERVAL = 10_000
const EMAIL_REFRESH_LIMIT = 6

const finalStatuses = new Set(['completed', 'partially_refunded', 'refunded', 'cancelled', 'expired'])
const refundNotice = attempt => ({
  pending: 'Refund pending — waiting for the payment provider. Check this saved request; a refund has not been confirmed.',
  unconfirmed: 'The refund outcome is not confirmed. Check this saved request before starting another refund.',
  failed: 'Refund failed. No refund was confirmed. You can try again.',
  cancelled: 'Refund cancelled. No refund was confirmed. You can try again.',
  rejected: 'The refund request was rejected. No refund was confirmed. Contact support or retry this request.',
  succeeded: attempt?.simulated ? 'Test refund complete. No real money was returned.' : 'Refund confirmed by the payment provider.',
  finance_review: 'The payment records need a finance review. Contact support before requesting another refund. Check this saved request for updates.',
}[attempt?.status])
const refundNeedsStatusCheck = attempt => ['pending', 'unconfirmed', 'finance_review'].includes(attempt?.status)
const refundButton = (attempt, initial = 'Refund') => ['failed', 'cancelled'].includes(attempt?.status)
  ? 'Try refund again'
  : refundNeedsStatusCheck(attempt) ? 'Check refund status'
    : attempt?.status === 'rejected' ? 'Retry refund request' : initial

export default function OrderConfirmationPage() {
  const { id } = useParams()
  return import.meta.env.VITE_CLERK_PUBLISHABLE_KEY ? <AuthenticatedOrderConfirmation key={id} /> : <OrderConfirmationContent key={id} />
}

function AuthenticatedOrderConfirmation() {
  const { isLoaded, userId } = useAuth()
  if (!isLoaded || checkoutBuyerIdentity() !== (userId || null)) return <div className="grid min-h-screen place-items-center" role="status">Preparing your account…</div>
  return <OrderConfirmationContent key={userId || 'guest'} />
}

function OrderConfirmationContent() {
  const { id } = useParams()
  const location = useLocation()
  const navigate = useNavigate()
  const capabilities = useLaunchCapabilities()
  const [order, setOrder] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [resendState, setResendState] = useState('idle')
  const [deliveryRefreshing, setDeliveryRefreshing] = useState(false)
  const [deliveryRefreshError, setDeliveryRefreshError] = useState(null)
  const [emailUpdatesPaused, setEmailUpdatesPaused] = useState(false)
  const [deliveryRefreshCycle, setDeliveryRefreshCycle] = useState(0)
  const deliveryRefreshInFlight = useRef(null)
  const deliveryRefreshBudget = useRef({ key: null, attempts: 0 })
  const delivery = order?.confirmation_delivery
  const [decisionState, setDecisionState] = useState('idle')
  const [cancellingTicketId, setCancellingTicketId] = useState(null)
  const [rotatingTicketId, setRotatingTicketId] = useState(null)
  const [transferringTicketId, setTransferringTicketId] = useState(null)
  const [exchangeTicketId, setExchangeTicketId] = useState(null)
  const [exchangeMap, setExchangeMap] = useState(null)
  const [exchangeSeatId, setExchangeSeatId] = useState('')
  const [exchangeAttested, setExchangeAttested] = useState(false)
  const [ticketActionError, setTicketActionError] = useState(null)
  const [, refreshRefundAttempts] = useState(0)
  const lifecycle = useRef({ active: false, generation: 0 })
  const currentRoute = useRef(null)
  const latestFetch = useRef(0)
  currentRoute.current = { id, pathname: location.pathname }
  useLayoutEffect(() => {
    const state = lifecycle.current
    state.active = true
    state.generation += 1
    state.buyerId = checkoutBuyerIdentity()
    return () => { state.active = false; state.generation += 1 }
  }, [])

  useEffect(() => {
    const params = new URLSearchParams(location.search)
    const token = params.get('guest_token')
    if (token) saveOrderAccess(id, token)
    const privateParams = ['guest_token', 'payment_intent_client_secret', 'payment_intent', 'redirect_status']
    if (!privateParams.some(key => params.has(key))) return
    privateParams.forEach(key => params.delete(key))
    navigate({ pathname: location.pathname, search: params.toString() ? `?${params}` : '' }, { replace: true })
  }, [id, location.pathname, location.search, navigate])

  const fetchOrder = useCallback(async ({ preserveOrder = false } = {}) => {
    const generation = lifecycle.current.generation
    const buyerId = checkoutBuyerIdentity()
    const contextCurrent = () => lifecycle.current.active && lifecycle.current.generation === generation
      && lifecycle.current.buyerId === buyerId
      && currentRoute.current.id === id && currentRoute.current.pathname === `/orders/${id}/confirmation`
      && checkoutBuyerIdentity() === buyerId
    if (!contextCurrent()) return
    while (preserveOrder && deliveryRefreshInFlight.current) {
      await deliveryRefreshInFlight.current
      if (!contextCurrent()) return
    }
    if (preserveOrder && (navigator.onLine === false || document.visibilityState === 'hidden')) return
    const request = ++latestFetch.current
    const current = () => contextCurrent() && latestFetch.current === request
    let finishRefresh
    if (preserveOrder) {
      deliveryRefreshInFlight.current = new Promise(resolve => { finishRefresh = resolve })
      setDeliveryRefreshing(true)
    }
    try {
      const response = await apiClient.get(`/orders/${id}`, { headers: orderAccessHeaders(id), ...(preserveOrder ? { timeout: 10_000 } : {}) })
      if (!current()) return
      setOrder(response.data)
      setError(null)
      setDeliveryRefreshError(null)
      if (response.data.event?.slug && finalStatuses.has(response.data.status)) clearActiveCheckout(response.data.event.slug, id)
      return response.data
    } catch (err) {
      if (!current()) return
      if (preserveOrder && err.response?.status !== 404 && err.response?.status !== 401 && err.response?.status !== 403) {
        setDeliveryRefreshError('Unable to refresh email status right now. Your saved order details are still shown. Try Refresh status when connected.')
        return
      }
      setError(err.response?.status === 404
        ? 'We could not securely open this order. Use the recovery page with your order reference and email.'
        : 'Unable to refresh this order right now. Please try again.')
    } finally {
      if (preserveOrder) { deliveryRefreshInFlight.current = null; finishRefresh() }
      if (current()) { setLoading(false); setDeliveryRefreshing(false) }
    }
  }, [id])

  useEffect(() => {
    fetchOrder()
  }, [fetchOrder, location.search])

  useEffect(() => {
    if (!order || finalStatuses.has(order.status)) return undefined
    const interval = window.setInterval(fetchOrder, 3000)
    return () => window.clearInterval(interval)
  }, [fetchOrder, order])

  useEffect(() => {
    const budgetKey = `${id}:${deliveryRefreshCycle}`
    if (deliveryRefreshBudget.current.key !== budgetKey) {
      deliveryRefreshBudget.current = { key: budgetKey, attempts: 0 }
      setEmailUpdatesPaused(false)
    }
    if (deliveryRefreshError || !order || String(order.id) !== id || !finalStatuses.has(order.status) || delivery?.simulated || !emailInFlightStatuses.has(delivery?.status)) return undefined
    const budget = deliveryRefreshBudget.current
    const buyerId = lifecycle.current.buyerId
    let active = true
    let timer
    let busy = false
    let stopped = false
    const eligible = () => active && !stopped && lifecycle.current.active && checkoutBuyerIdentity() === buyerId
      && currentRoute.current.id === id && document.visibilityState !== 'hidden' && navigator.onLine !== false
    const exhausted = () => budget.attempts >= EMAIL_REFRESH_LIMIT
    const schedule = () => {
      window.clearTimeout(timer)
      if (!eligible() || busy) return
      if (exhausted()) { setEmailUpdatesPaused(true); return }
      timer = window.setTimeout(async () => {
        if (!eligible() || exhausted()) { if (active && exhausted()) setEmailUpdatesPaused(true); return }
        busy = true
        budget.attempts += 1
        const refreshed = await fetchOrder({ preserveOrder: true })
        busy = false
        if (!active) return
        if (!refreshed) { stopped = true; return }
        if (refreshed.confirmation_delivery?.simulated || !emailInFlightStatuses.has(refreshed.confirmation_delivery?.status)) return
        schedule()
      }, EMAIL_REFRESH_INTERVAL)
    }
    const availabilityChanged = () => schedule()
    document.addEventListener('visibilitychange', availabilityChanged)
    window.addEventListener('online', availabilityChanged)
    window.addEventListener('offline', availabilityChanged)
    schedule()
    return () => {
      active = false
      window.clearTimeout(timer)
      document.removeEventListener('visibilitychange', availabilityChanged)
      window.removeEventListener('online', availabilityChanged)
      window.removeEventListener('offline', availabilityChanged)
    }
  }, [id, order, delivery?.status, delivery?.simulated, deliveryRefreshCycle, deliveryRefreshError, fetchOrder])

  const refreshDeliveryStatus = () => {
    if (navigator.onLine === false) {
      setDeliveryRefreshError('Connect to the internet, then use Refresh status. Your saved order details are still shown.')
      return
    }
    return fetchOrder({ preserveOrder: true })
  }

  const formatPrice = (cents = 0) => cents === 0 ? 'Free' : `$${(cents / 100).toFixed(2)}`
  const event = order?.event
  const awaitingPayment = order?.status === 'pending' && order?.payment_resumable === true
  const isProcessing = order && !finalStatuses.has(order.status)
  const ticketsAvailable = ['completed', 'partially_refunded', 'refunded', 'cancelled'].includes(order?.status) && order?.tickets?.length > 0
  const usableTickets = Boolean(order?.event?.status === 'published' && order?.tickets?.some(ticket => ticket.status === 'issued') && !order?.ticket_access_blocked)
  const deliveryFailed = !delivery?.simulated && ['failed', 'bounced', 'complained', 'suppressed'].includes(delivery?.status)
  const deliveryMessage = delivery?.simulated
    ? usableTickets ? 'Email is simulated in this test environment. Open or download your tickets below.' : 'Email is simulated in this test environment. Check your order and ticket statuses below.'
    : delivery?.status === 'delivered'
      ? 'Your ticket email was delivered.'
      : delivery?.status === 'sent'
        ? 'Your ticket email was accepted for delivery. Delivery has not been confirmed.'
        : delivery?.status === 'delayed'
          ? 'Your ticket email is delayed. Delivery has not been confirmed. You can open or download your tickets below.'
          : delivery?.status === 'queued'
          ? 'Your ticket email is queued for delivery. You can open or download your tickets below.'
          : delivery?.status === 'cancelled'
            ? 'This ticket email request was cancelled. Check your order and ticket statuses below.'
            : deliveryFailed
            ? 'Your ticket email delivery needs attention. Open or download your tickets below, or contact support.'
            : usableTickets
              ? 'Your tickets are ready below. You can request a confirmation email using Resend.'
              : 'You can view your order and ticket statuses here. Email delivery will appear when a confirmation is available.'
  const change = order?.latest_event_change
  const refundNeedsRetry = change?.response === 'refund_requested' && order?.tickets?.some(ticket => (
    ticket.status === 'issued' && ticket.refundable_cents >= 0
  ))
  const eventRefundAttempt = change ? getBuyerRefundAttempt(id, `event:${change.id}`) : null
  const canRespondToChange = change && (!change.response || refundNeedsRetry || refundNeedsStatusCheck(eventRefundAttempt)) && ['cancelled', 'postponed', 'rescheduled'].includes(change.change_type)
  const decisionBusy = ['accepted', 'refund_requested'].includes(decisionState)
  // Recovery links import credentials after mount. Read the current credential for every action.
  const orderHeaders = () => orderAccessHeaders(id)

  async function resend() {
    const generation = lifecycle.current.generation
    const buyerId = checkoutBuyerIdentity()
    const current = () => lifecycle.current.active && lifecycle.current.generation === generation && checkoutBuyerIdentity() === buyerId && currentRoute.current.id === id
    setResendState('sending')
    try {
      await apiClient.post(`/orders/${id}/resend`, {}, { headers: orderHeaders() })
      if (!current()) return
      setResendState('requested')
      setDeliveryRefreshCycle(value => value + 1)
      await refreshDeliveryStatus()
    } catch (err) {
      if (!current()) return
      setResendState(err.response?.status === 429 ? 'cooldown' : 'error')
    }
  }

  async function respondToChange(decision) {
    setDecisionState(decision)
    const operation = `event:${change.id}`
    const isPaidRefund = decision === 'refund_requested' && (getBuyerRefundAttempt(id, operation) || order.tickets?.some(ticket => ticket.status === 'issued' && ticket.refundable_cents > 0))
    try {
      const attempt = isPaidRefund ? prepareBuyerRefundAttempt(id, operation) : null
      const response = await apiClient.post(`/orders/${id}/event_change_response`, {
        event_change_id: change.id,
        decision,
      }, {
        headers: {
          ...orderHeaders(),
          ...(decision === 'refund_requested' ? { 'Idempotency-Key': attempt?.key || `buyer-event-refund:${id}:${change.id}` } : {}),
        },
      })
      if (attempt) recordBuyerRefundOutcome(id, operation, response.data)
      await fetchOrder()
      setDecisionState('done')
    } catch (err) {
      if (isPaidRefund) recordBuyerRefundOutcome(id, operation, err.response?.data)
      setDecisionState('error')
    } finally {
      refreshRefundAttempts(value => value + 1)
    }
  }

  async function cancelTicket(ticket) {
    const operation = `ticket:${ticket.id}`
    const isPaidRefund = ticket.refundable_cents > 0 || Boolean(getBuyerRefundAttempt(id, operation))
    const checkingSavedRefund = isPaidRefund && refundNeedsStatusCheck(getBuyerRefundAttempt(id, operation))
    if (!checkingSavedRefund && !window.confirm(isPaidRefund ? `Request a refund for this ${ticket.ticket_type.name} ticket? Cancellation follows a confirmed refund.` : `Cancel this ${ticket.ticket_type.name} ticket? This cannot be undone.`)) return
    setCancellingTicketId(ticket.id)
    setTicketActionError(null)
    try {
      const attempt = isPaidRefund ? prepareBuyerRefundAttempt(id, operation) : null
      const response = await apiClient.post(`/orders/${id}/tickets/${ticket.id}/cancel`, {}, {
        headers: { ...orderHeaders(), 'Idempotency-Key': attempt?.key || `buyer-ticket-cancel:${id}:${ticket.id}` },
      })
      if (attempt) recordBuyerRefundOutcome(id, operation, response.data)
      await fetchOrder()
    } catch (err) {
      if (isPaidRefund) recordBuyerRefundOutcome(id, operation, err.response?.data)
      setTicketActionError(err.response?.data?.error || 'Unable to cancel this ticket. Please refresh before retrying.')
    } finally {
      refreshRefundAttempts(value => value + 1)
      setCancellingTicketId(null)
    }
  }

  async function rotateTicket(ticket) {
    if (!window.confirm('Replace this ticket’s entry QR? Any saved copy of the old QR will stop working.')) return
    setRotatingTicketId(ticket.id)
    try {
      await apiClient.post(`/orders/${id}/tickets/${ticket.id}/rotate_scan`, {}, { headers: orderHeaders() })
      await fetchOrder()
    } catch (err) {
      setTicketActionError(err.response?.data?.error || 'Unable to replace the QR. Please refresh before retrying.')
    } finally {
      setRotatingTicketId(null)
    }
  }

  async function transferTicket(ticket) {
    const recipientEmail = window.prompt('Enter the recipient email address. They must sign in with this email to accept the ticket.')
    if (!recipientEmail) return
    setTransferringTicketId(ticket.id)
    setTicketActionError(null)
    try {
      await apiClient.post(`/orders/${id}/tickets/${ticket.id}/transfer`, { recipient_email: recipientEmail }, { headers: orderHeaders() })
      window.alert('Transfer invitation sent. You retain control until the recipient accepts it.')
    } catch (err) {
      setTicketActionError(err.response?.data?.error || 'Unable to transfer this ticket.')
    } finally {
      setTransferringTicketId(null)
    }
  }

  async function openSeatExchange(ticket) {
    setTicketActionError(null)
    setExchangeTicketId(ticket.id)
    setExchangeSeatId('')
    setExchangeAttested(false)
    try {
      const response = await apiClient.get(`/events/${event.slug}/seating`)
      setExchangeMap(response.data)
    } catch (err) {
      setTicketActionError(err.response?.data?.error || 'Unable to load available seats.')
      setExchangeTicketId(null)
    }
  }

  async function exchangeSeat(ticket) {
    if (!exchangeSeatId) return
    setTicketActionError(null)
    try {
      await apiClient.post(`/orders/${id}/tickets/${ticket.id}/exchange_seat`, {
        event_seat_id: Number(exchangeSeatId),
        accessibility_attested: exchangeAttested,
      }, { headers: orderHeaders() })
      setExchangeTicketId(null)
      setExchangeMap(null)
      await fetchOrder()
    } catch (err) {
      setTicketActionError(err.response?.data?.error || 'The seat could not be changed.')
    }
  }

  if (loading) return <div className="flex min-h-[60vh] items-center justify-center"><Loader2 className="h-8 w-8 animate-spin text-brand-500" /></div>

  if (error || !order) {
    return (
      <div className="mx-auto max-w-lg px-4 py-16">
        <div className="card p-8 text-center">
          <AlertTriangle className="mx-auto mb-3 h-10 w-10 text-amber-500" />
          <p className="mb-5 text-neutral-700">{error}</p>
          <Link to="/orders/recover" className="btn-primary">Recover my order</Link>
        </div>
      </div>
    )
  }

  return (
    <div className="min-h-screen bg-neutral-50">
      <SEO title={`Order ${order.reference}`} />
      <div className="mx-auto max-w-2xl px-4 py-8 sm:px-6">
        <div className="mb-7 text-center">
          <div className={`mx-auto mb-4 flex h-16 w-16 items-center justify-center rounded-full ${isProcessing ? 'bg-amber-100' : 'bg-emerald-100'}`}>
            {isProcessing ? <Clock3 className="h-8 w-8 text-amber-700" /> : <CheckCircle className="h-8 w-8 text-emerald-700" />}
          </div>
          <h1 className="text-3xl font-bold tracking-tight text-neutral-950">
            {awaitingPayment ? 'Your payment is not complete' : isProcessing ? 'Payment is processing' : order.status === 'refunded' ? 'Your order was refunded' : order.status === 'partially_refunded' ? 'Your order was partially refunded' : order.status === 'cancelled' || order.status === 'expired' ? 'Order closed' : 'Your order is confirmed'}
          </h1>
          <p className="mt-2 text-neutral-500">Order {order.reference} · {order.buyer_email}</p>
          {awaitingPayment ? <div className="mt-3">
            <p className="mb-3 text-sm text-amber-700">Your tickets are held until {new Date(order.expires_at).toLocaleTimeString()}. Resume the original checkout to pay.</p>
            <Link to={`/checkout/${event.slug}?resume=${order.id}`} className="btn-primary">Resume payment</Link>
          </div> : isProcessing && <p className="mt-2 text-sm text-amber-700">This page refreshes automatically. Do not submit another payment.</p>}
        </div>

        <section className={`mb-6 rounded-xl border p-4 text-sm ${deliveryFailed ? 'border-amber-200 bg-amber-50 text-amber-950' : 'border-neutral-200 bg-white text-neutral-700'}`} aria-labelledby="confirmation-delivery-title">
          <h2 id="confirmation-delivery-title" className="font-semibold">Ticket email</h2>
          <p className="mt-1" role="status">{deliveryMessage}</p>
          {!delivery?.simulated && <button onClick={refreshDeliveryStatus} disabled={deliveryRefreshing} className="mt-2 inline-flex min-h-11 items-center gap-1.5 font-semibold text-brand-700 disabled:opacity-50"><RefreshCw className="h-4 w-4" />{deliveryRefreshing ? 'Refreshing status…' : 'Refresh status'}</button>}
          {deliveryRefreshError && <p className="mt-1 text-amber-800" role="alert">{deliveryRefreshError}</p>}
          {emailUpdatesPaused && emailInFlightStatuses.has(delivery?.status) && <p className="mt-1 text-neutral-600">Automatic email updates have paused. Use Refresh status to check again.</p>}
          {deliveryFailed && <div className="mt-2 flex flex-wrap gap-x-4 gap-y-2">
            {usableTickets && <a href="#order-tickets" className="inline-flex min-h-11 items-center font-semibold text-brand-700 underline">Open or download tickets</a>}
            <a href={supportMailto(`Ticket email for order ${order.reference}`)} className="inline-flex min-h-11 items-center font-semibold text-brand-700 underline">Contact support</a>
          </div>}
        </section>

        {change && (
          <section className="mb-6 rounded-2xl border border-amber-200 bg-amber-50 p-5">
            <h2 className="font-semibold text-amber-950">Event {change.change_type}</h2>
            <p className="mt-1 text-sm text-amber-900">{change.reason || 'The organizer changed this event. Review the updated details below.'}</p>
            {change.response && <p className="mt-3 text-sm font-medium text-amber-950">Your response: {change.response.replace('_', ' ')}</p>}
            {canRespondToChange && (
              <div className="mt-4 flex flex-col gap-2 sm:flex-row">
                {!change.response && (
                  <button className="btn-secondary" disabled={decisionBusy} onClick={() => respondToChange('accepted')}>Keep my tickets</button>
                )}
                <button className="rounded-xl border border-red-300 bg-white px-4 py-2.5 text-sm font-semibold text-red-700" disabled={decisionBusy || eventRefundAttempt?.status === 'succeeded'} onClick={() => respondToChange('refund_requested')}>{refundButton(eventRefundAttempt, refundNeedsRetry ? 'Retry refund' : 'Request refund')}</button>
              </div>
            )}
            {eventRefundAttempt && <p role="status" className="mt-3 text-sm text-amber-950">{refundNotice(eventRefundAttempt)}</p>}
            {eventRefundAttempt?.status === 'finance_review' && <a className="inline-flex min-h-11 items-center font-semibold text-brand-700 underline" href={supportMailto(`Refund review for order ${order.reference}`)}>Contact support</a>}
            {decisionState === 'error' && !eventRefundAttempt && <p className="mt-3 text-sm text-red-700">We could not save that choice. Please try again.</p>}
          </section>
        )}

        <section className="card mb-6 overflow-hidden">
          <div className="border-b border-neutral-100 p-5 sm:p-6">
            <p className="min-h-11 px-2 text-xs font-semibold uppercase tracking-wider text-brand-600">{event.status}</p>
            <h2 className="mt-1 text-xl font-bold text-neutral-950">{event.title}</h2>
            <p className="mt-2 text-sm text-neutral-600">{formatEventDate(event.starts_at, event.timezone, { weekday: 'long' })} · {formatEventTime(event.starts_at, event.timezone)}</p>
            <p className="text-sm text-neutral-500">{event.venue_name}{event.venue_address ? ` · ${event.venue_address}` : ''}</p>
          </div>
          <div className="space-y-2 p-5 text-sm sm:p-6">
            {order.order_items.map(item => (
              <div key={item.id} className="flex justify-between gap-4"><span>{item.name || item.item_name} × {item.quantity}</span><span>{formatPrice(item.subtotal_cents)}</span></div>
            ))}
            <div className="flex justify-between border-t border-neutral-100 pt-3 text-neutral-600"><span>Service fee</span><span>{formatPrice(order.service_fee_cents)}</span></div>
            {order.discount_cents > 0 && <div className="flex justify-between text-emerald-700"><span>Discount</span><span>−{formatPrice(order.discount_cents)}</span></div>}
            <div className="flex justify-between pt-1 text-lg font-bold text-neutral-950"><span>Total</span><span>{formatPrice(order.total_cents)}</span></div>
            {order.refunded_cents > 0 && <div className="flex justify-between text-sm font-medium text-red-700"><span>Refunded</span><span>−{formatPrice(order.refunded_cents)}</span></div>}
          </div>
        </section>

        {ticketsAvailable && (
          <section id="order-tickets" className="card mb-6 scroll-mt-24 p-5 sm:p-6">
            <div className="mb-4 flex items-center justify-between">
              <h2 className="font-semibold text-neutral-950">Tickets ({order.tickets.length})</h2>
              {['completed', 'partially_refunded'].includes(order.status) && (
                <button onClick={resend} disabled={resendState === 'sending'} className="inline-flex items-center gap-1.5 text-sm font-semibold text-brand-600"><Mail className="h-4 w-4" /> Resend</button>
              )}
            </div>
            {resendState === 'requested' && <p className="mb-3 text-sm text-neutral-700">Your email request was saved. Check the delivery status above.</p>}
            {resendState === 'cooldown' && <p className="mb-3 text-sm text-amber-700">An email request was made recently. Please wait two minutes.</p>}
            {resendState === 'error' && <p className="mb-3 text-sm text-red-700">Unable to resend right now.</p>}
            {ticketActionError && <p className="mb-3 text-sm text-red-700">{ticketActionError}</p>}
            <div className="divide-y divide-neutral-100">
              {order.tickets.map(ticket => {
                const ticketRefundAttempt = getBuyerRefundAttempt(id, `ticket:${ticket.id}`)
                const exchangeOptions = exchangeMap?.sections.flatMap(section => section.rows.flatMap(row =>
                  row.seats.filter(seat => seat.status === 'available' && seat.ticket_type_id === ticket.ticket_type.id &&
                    seat.accessibility_kind === ticket.seat?.accessibility_kind)
                )) || []
                const selectedExchangeSeat = exchangeOptions.find(seat => seat.id === Number(exchangeSeatId))
                return <div key={ticket.id} className="py-3">
                <div className="flex flex-col items-start justify-between gap-3 sm:flex-row sm:items-center">
                  <div className="min-w-0 flex-1">
                    <p className="truncate font-medium text-neutral-900">{ticket.ticket_type.name}</p>
                    {ticket.seat && <p className="text-sm font-semibold text-brand-700">{ticket.seat.display_label}</p>}
                    <p className="text-xs capitalize text-neutral-500">{ticket.attendee_name || 'New holder'} · {ticket.status.replace('_', ' ')}</p>
                  </div>
                  <div className="flex flex-wrap items-center gap-2">
                    {ticket.status === 'issued' && (
                      <button onClick={() => rotateTicket(ticket)} disabled={rotatingTicketId === ticket.id} className="min-h-11 px-2 text-xs font-semibold text-neutral-600">{rotatingTicketId === ticket.id ? 'Refreshing…' : 'Refresh QR'}</button>
                    )}
                    {(ticket.status === 'issued' && (ticket.refundable_cents === 0 || ['cancelled', 'postponed'].includes(event.status)) || refundNeedsStatusCheck(ticketRefundAttempt)) && (
                      <button onClick={() => cancelTicket(ticket)} disabled={cancellingTicketId === ticket.id || ticketRefundAttempt?.status === 'succeeded'} className="min-h-11 px-2 text-xs font-semibold text-red-600">{cancellingTicketId === ticket.id ? 'Checking…' : ticketRefundAttempt || ticket.refundable_cents > 0 ? refundButton(ticketRefundAttempt) : 'Cancel'}</button>
                    )}
                    {ticket.status === 'issued' && capabilities.ticket_transfers && event.transfers_enabled !== false && (
                      <button onClick={() => transferTicket(ticket)} disabled={transferringTicketId === ticket.id} className="min-h-11 px-2 text-xs font-semibold text-brand-600">{transferringTicketId === ticket.id ? 'Sending…' : 'Transfer'}</button>
                    )}
                    {ticket.status === 'issued' && ticket.seat && (
                      <button onClick={() => openSeatExchange(ticket)} className="min-h-11 px-2 text-xs font-semibold text-brand-600">Change seat</button>
                    )}
                    {ticket.status === 'issued' && !order.ticket_access_blocked && (
                      <Link to={`/tickets/${encodeURIComponent(ticket.display_credential)}?order=${id}`} className="inline-flex min-h-11 min-w-11 items-center justify-center" aria-label="Download ticket"><Download className="h-4 w-4 text-neutral-500" /></Link>
                    )}
                    {ticket.display_credential && <Link to={`/tickets/${encodeURIComponent(ticket.display_credential)}?order=${id}`} className="inline-flex min-h-11 min-w-11 items-center justify-center" aria-label="View ticket"><ChevronRight className="h-5 w-5 text-neutral-400" /></Link>}
                  </div>
                </div>
                {ticketRefundAttempt && <p role="status" className="mt-2 text-sm text-neutral-700">{refundNotice(ticketRefundAttempt)}</p>}
                {ticketRefundAttempt?.status === 'finance_review' && <a className="inline-flex min-h-11 items-center text-sm font-semibold text-brand-700 underline" href={supportMailto(`Refund review for order ${order.reference}`)}>Contact support</a>}
                {exchangeTicketId === ticket.id && (
                  <div className="mt-3 rounded-xl border border-brand-200 bg-brand-50 p-4">
                    <label className="block text-sm font-medium text-neutral-800">Available equivalent seats
                      <select className="input mt-1" value={exchangeSeatId} onChange={eventValue => setExchangeSeatId(eventValue.target.value)}>
                        <option value="">Choose a seat</option>
                        {exchangeOptions.map(seat => <option key={seat.id} value={seat.id}>{seat.display_label}</option>)}
                      </select>
                    </label>
                    {selectedExchangeSeat?.requires_accessibility_attestation && (
                      <label className="mt-3 flex items-start gap-2 text-sm text-neutral-700"><input type="checkbox" className="mt-1" checked={exchangeAttested} onChange={eventValue => setExchangeAttested(eventValue.target.checked)} />I attest that this party needs an accessible seating location.</label>
                    )}
                    <div className="mt-3 flex gap-2">
                      <button className="btn-primary !px-3 !py-2 text-sm" disabled={!exchangeSeatId || (selectedExchangeSeat?.requires_accessibility_attestation && !exchangeAttested)} onClick={() => exchangeSeat(ticket)}>Confirm seat change</button>
                      <button className="btn-secondary !px-3 !py-2 text-sm" onClick={() => setExchangeTicketId(null)}>Cancel</button>
                    </div>
                  </div>
                )}
              </div>
              })}
            </div>
          </section>
        )}

        <div className="flex items-center justify-center gap-5 text-sm font-medium">
          <button onClick={fetchOrder} className="inline-flex items-center gap-1.5 text-neutral-600"><RefreshCw className="h-4 w-4" /> Refresh</button>
          <Link to="/events" className="text-brand-600">Browse events</Link>
          {!getOrderAccess(id) && <Link to="/my-tickets" className="text-brand-600">My tickets</Link>}
        </div>
      </div>
    </div>
  )
}
