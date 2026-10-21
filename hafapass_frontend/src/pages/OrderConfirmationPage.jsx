import useTranslatedContent from '../hooks/useTranslatedContent'
import MachineTranslationNotice from '../components/MachineTranslationNotice'
import { formatMoneyCents } from '../utils/money'
import { useTranslation } from 'react-i18next'
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { useAuth } from '@clerk/clerk-react'
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom'
import { AlertTriangle, CheckCircle, Clock3, Ticket, RotateCcw, XCircle, Loader2, Mail, RefreshCw } from 'lucide-react'
import apiClient from '../api/client'
import SupportLink from '../components/SupportLink'
import { SUPPORT_FALLBACK_PATH } from '../utils/supportContact'
import useLaunchCapabilities from '../hooks/useLaunchCapabilities'
import SEO from '../components/SEO'
import TransferTicketDialog from '../components/TransferTicketDialog'
import PendingTransfer from '../components/PendingTransfer'
import { formatEventDate, formatEventTime } from '../utils/eventTime'
import { checkoutBuyerIdentity, clearActiveCheckout, getBuyerRefundAttempt, getOrderAccess, orderAccessHeaders, prepareBuyerRefundAttempt, recordBuyerRefundOutcome, saveOrderAccess } from '../utils/orderAccess'
import { SellerLine } from '../components/PriceDisclosure'

const emailInFlightStatuses = new Set(['queued', 'sent'])
const EMAIL_REFRESH_INTERVAL = 10_000
const EMAIL_REFRESH_LIMIT = 6

const finalStatuses = new Set(['completed', 'partially_refunded', 'refunded', 'cancelled', 'expired'])

export default function OrderConfirmationPage() {
  const { id } = useParams()
  return import.meta.env.VITE_CLERK_PUBLISHABLE_KEY ? <AuthenticatedOrderConfirmation key={id} /> : <OrderConfirmationContent key={id} />
}

function AuthenticatedOrderConfirmation() {
  const { t } = useTranslation()
  const { isLoaded, userId } = useAuth()
  if (!isLoaded || checkoutBuyerIdentity() !== (userId || null)) return <div className="grid min-h-screen place-items-center" role="status">{t('buyerAccount.orderConfirmationPage.preparingYourAccount')}</div>
  return <OrderConfirmationContent key={userId || 'guest'} />
}

function OrderConfirmationContent() {
  const { t } = useTranslation()
  const refundNotice = attempt => ({
    pending: t('buyerAccount.orderConfirmationPage.refundPendingWaitingForThePaymentProviderCheck'),
    unconfirmed: t('buyerAccount.orderConfirmationPage.theRefundOutcomeIsNotConfirmedCheckThis'),
    failed: t('buyerAccount.orderConfirmationPage.refundFailedNoRefundWasConfirmedYouCan'),
    cancelled: t('buyerAccount.orderConfirmationPage.refundCancelledNoRefundWasConfirmedYouCan'),
    rejected: t('buyerAccount.orderConfirmationPage.theRefundRequestWasRejectedNoRefundWas'),
    succeeded: attempt?.simulated ? t('buyerAccount.orderConfirmationPage.testRefundCompleteNoRealMoneyWasReturned') : t('buyerAccount.orderConfirmationPage.refundConfirmedByThePaymentProvider'),
    finance_review: t('buyerAccount.orderConfirmationPage.thePaymentRecordsNeedAFinanceReviewContact'),
  }[attempt?.status])
  const refundNeedsStatusCheck = attempt => ['pending', 'unconfirmed', 'finance_review'].includes(attempt?.status)
  const refundButton = (attempt, initial = t('buyerAccount.orderConfirmationPage.refund')) => ['failed', 'cancelled'].includes(attempt?.status)
    ? t('buyerAccount.orderConfirmationPage.tryRefundAgain')
    : refundNeedsStatusCheck(attempt) ? t('buyerAccount.orderConfirmationPage.checkRefundStatus')
      : attempt?.status === 'rejected' ? t('buyerAccount.orderConfirmationPage.retryRefundRequest') : initial

  const { id } = useParams()
  const location = useLocation()
  const navigate = useNavigate()
  const capabilities = useLaunchCapabilities()
  const [order, setOrder] = useState(null)
  const eventContent = useTranslatedContent(order?.event)
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
  const [transferTarget, setTransferTarget] = useState(null)
  const [exchangeTicketId, setExchangeTicketId] = useState(null)
  const [exchangeMap, setExchangeMap] = useState(null)
  const [exchangeSeatId, setExchangeSeatId] = useState('')
  const [exchangeAttested, setExchangeAttested] = useState(false)
  const [ticketActionError, setTicketActionError] = useState(null)
  const [ticketActionNotice, setTicketActionNotice] = useState(null)
  const [receiptState, setReceiptState] = useState('idle')
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
      if (response.data.confirmation_delivery?.reconciliation_required === false) setResendState(state => state === 'uncertain' ? 'idle' : state)
      if (response.data.event?.slug && finalStatuses.has(response.data.status)) clearActiveCheckout(response.data.event.slug, id)
      return response.data
    } catch (err) {
      if (!current()) return
      if (preserveOrder && err.response?.status !== 404 && err.response?.status !== 401 && err.response?.status !== 403) {
        setDeliveryRefreshError(t('buyerAccount.orderConfirmationPage.unableToRefreshEmailStatusRightNowYour'))
        return
      }
      setError(err.response?.status === 404
        ? t('buyerAccount.orderConfirmationPage.weCouldNotSecurelyOpenThisOrderUse')
        : t('buyerAccount.orderConfirmationPage.unableToRefreshThisOrderRightNowPlease'))
    } finally {
      if (preserveOrder) { deliveryRefreshInFlight.current = null; finishRefresh() }
      if (current()) { setLoading(false); setDeliveryRefreshing(false) }
    }
  }, [id, t])

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
  }, [id, order, delivery?.status, delivery?.simulated, delivery?.reconciliation_required, deliveryRefreshCycle, deliveryRefreshError, fetchOrder])

  const refreshDeliveryStatus = () => {
    if (navigator.onLine === false) {
      setDeliveryRefreshError(t('buyerAccount.orderConfirmationPage.connectToTheInternetThenUseRefreshStatus'))
      return
    }
    return fetchOrder({ preserveOrder: true })
  }

  const formatPrice = (cents = 0) => cents === 0 ? t('buyerAccount.orderConfirmationPage.free') : formatMoneyCents(cents)
  const event = order?.event
  // Transfers close when the event starts, matching the server and My Tickets.
  const transfersOpen = Boolean(event?.starts_at) && new Date(event.starts_at) > new Date()
  const awaitingPayment = order?.status === 'pending' && order?.payment_resumable === true
  const isProcessing = order && !finalStatuses.has(order.status)
  const isClosed = ['cancelled', 'expired'].includes(order?.status)
  const isRefunded = order?.status === 'refunded'
  const isPartiallyRefunded = order?.status === 'partially_refunded'
  const ticketsAvailable = ['completed', 'partially_refunded', 'refunded', 'cancelled'].includes(order?.status) && order?.tickets?.length > 0
  const usableTickets = Boolean(order?.event?.status === 'published' && order?.tickets?.some(ticket => ticket.status === 'issued' && ticket.admission_allowed === true && !ticket.admission_block_reason) && !order?.ticket_access_blocked)
  const deliveryUnconfirmed = !delivery?.simulated && delivery?.reconciliation_required === true
  const deliveryFailed = !delivery?.simulated && !deliveryUnconfirmed && ['failed', 'bounced', 'complained', 'suppressed'].includes(delivery?.status)
  const deliveryMessage = delivery?.simulated
    ? usableTickets ? t('buyerAccount.orderConfirmationPage.emailIsSimulatedInThisTestEnvironmentOpen') : t('buyerAccount.orderConfirmationPage.emailIsSimulatedInThisTestEnvironmentCheck')
    : delivery?.status === 'delivered'
      ? t('buyerAccount.orderConfirmationPage.yourTicketEmailWasDelivered')
      : deliveryUnconfirmed
        ? t('buyerAccount.orderConfirmationPage.aTicketEmailRequestStillHasAnUnconfirmed')
      : delivery?.status === 'sent'
        ? t('buyerAccount.orderConfirmationPage.yourTicketEmailWasAcceptedForDeliveryDelivery')
        : delivery?.status === 'delayed'
          ? t('buyerAccount.orderConfirmationPage.yourTicketEmailIsDelayedDeliveryHasNot')
          : delivery?.status === 'queued'
          ? t('buyerAccount.orderConfirmationPage.yourTicketEmailIsQueuedForDeliveryYou')
          : delivery?.status === 'cancelled'
            ? t('buyerAccount.orderConfirmationPage.thisTicketEmailRequestWasCancelledCheckYour')
            : deliveryFailed
            ? t('buyerAccount.orderConfirmationPage.yourTicketEmailDeliveryNeedsAttentionOpenOr')
            : usableTickets
              ? t('buyerAccount.orderConfirmationPage.yourTicketsAreReadyYouCanRequestA')
              : t('buyerAccount.orderConfirmationPage.youCanViewYourOrderAndTicketStatuses')
  const change = order?.latest_event_change
  const refundNeedsRetry = change?.response === 'refund_requested' && order?.tickets?.some(ticket => (
    ticket.status === 'issued' && ticket.refundable_cents >= 0
  ))
  const eventRefundAttempt = change ? getBuyerRefundAttempt(id, `event:${change.id}`) : null
  const canRespondToChange = change && (!change.response || refundNeedsRetry || refundNeedsStatusCheck(eventRefundAttempt)) && ['cancelled', 'postponed', 'rescheduled'].includes(change.change_type)
  const cancelledRefund = change?.change_type === 'cancelled' ? (order?.cancellation_refund || (order?.status === 'refunded'
    ? { status: 'refunded', amount_cents: order.refunded_cents, payment_method: order.payment_method } : null)) : null
  const showCancelledRefundStatus = cancelledRefund && ['refunded', 'processing', 'needs_cash_return', 'needs_attention', 'awaiting_dispute', 'resolved'].includes(cancelledRefund.status)
  const decisionBusy = ['accepted', 'refund_requested'].includes(decisionState)
  // Recovery links import credentials after mount. Read the current credential for every action.
  const orderHeaders = () => orderAccessHeaders(id)

  async function downloadReceipt() {
    const generation = lifecycle.current.generation
    const buyerId = checkoutBuyerIdentity()
    const route = currentRoute.current
    const guestAccess = getOrderAccess(id)
    const current = () => lifecycle.current.active && lifecycle.current.generation === generation
      && currentRoute.current.id === route.id && currentRoute.current.pathname === route.pathname
      && checkoutBuyerIdentity() === buyerId && getOrderAccess(id) === guestAccess
    setReceiptState('loading')
    try {
      const response = await apiClient.get(`/orders/${id}/receipt`, { headers: orderAccessHeaders(id, guestAccess), responseType: 'blob' })
      if (!current()) return
      const url = URL.createObjectURL(response.data)
      const link = document.createElement('a')
      link.href = url
      link.download = `hafapass-receipt-${order.reference}.pdf`
      document.body.appendChild(link)
      link.click()
      link.remove()
      URL.revokeObjectURL(url)
      setReceiptState('idle')
    } catch {
      if (current()) setReceiptState('error')
    }
  }

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
      if (err.response?.status === 409 && err.response?.data?.reconciliation_required === true) {
        setResendState('uncertain')
        await refreshDeliveryStatus()
      } else {
        setResendState(err.response?.status === 429 ? 'cooldown' : 'error')
      }
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
    if (!checkingSavedRefund && !window.confirm(isPaidRefund ? t('buyerAccount.orderConfirmationPage.requestARefundForThisTicketCancellationFollows', { name: ticket.ticket_type.name }) : t('buyerAccount.orderConfirmationPage.cancelThisTicketThisCannotBeUndone', { name: ticket.ticket_type.name }))) return
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
      setTicketActionError(err.response?.data?.error || t('buyerAccount.orderConfirmationPage.unableToCancelThisTicketPleaseRefreshBefore'))
    } finally {
      refreshRefundAttempts(value => value + 1)
      setCancellingTicketId(null)
    }
  }

  async function rotateTicket(ticket) {
    if (!window.confirm(t('buyerAccount.orderConfirmationPage.replaceThisTicketSEntryQRAnySaved'))) return
    setRotatingTicketId(ticket.id)
    try {
      await apiClient.post(`/orders/${id}/tickets/${ticket.id}/rotate_scan`, {}, { headers: orderHeaders() })
      await fetchOrder()
    } catch (err) {
      setTicketActionError(err.response?.data?.error || t('buyerAccount.orderConfirmationPage.unableToReplaceTheQRPleaseRefreshBefore'))
    } finally {
      setRotatingTicketId(null)
    }
  }

  const sendTransfer = ticket => async body => {
    await apiClient.post(`/orders/${id}/tickets/${ticket.id}/transfer`, body, { headers: orderHeaders() })
    fetchOrder({ preserveOrder: true })
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
      setTicketActionError(err.response?.data?.error || t('buyerAccount.orderConfirmationPage.unableToLoadAvailableSeats'))
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
      setTicketActionError(err.response?.data?.error || t('buyerAccount.orderConfirmationPage.theSeatCouldNotBeChanged'))
    }
  }

  if (loading) return <div className="flex min-h-[60vh] items-center justify-center"><Loader2 className="h-8 w-8 animate-spin text-brand-500" /></div>

  if (error || !order) {
    return (
      <div className="mx-auto max-w-lg px-4 py-16">
        <div className="card p-8 text-center">
          <AlertTriangle className="mx-auto mb-3 h-10 w-10 text-amber-500" />
          <p className="mb-5 text-neutral-700">{error}</p>
          <Link to="/orders/recover" className="btn-primary">{t('buyerAccount.orderConfirmationPage.recoverMyOrder')}</Link>
        </div>
      </div>
    )
  }

  return (
    <div className="min-h-screen bg-neutral-50">
      <SEO title={t('buyerAccount.orderConfirmationPage.order', { reference: order.reference })} />
      <div className="mx-auto max-w-2xl px-4 py-8 sm:px-6">
        <div className="mb-7 text-center">
          <div className={`mx-auto mb-4 flex h-16 w-16 items-center justify-center rounded-full ${isProcessing || isPartiallyRefunded ? 'bg-amber-100' : isClosed || isRefunded ? 'bg-neutral-100' : 'bg-emerald-100'}`}>
            {isProcessing ? <Clock3 aria-label={t('buyerAccount.orderConfirmationPage.paymentPending')} className="h-8 w-8 text-amber-700" /> : isClosed ? <XCircle aria-label={t('buyerAccount.orderConfirmationPage.orderClosed')} className="h-8 w-8 text-neutral-600" /> : isRefunded ? <RotateCcw aria-label={t('buyerAccount.orderConfirmationPage.orderRefunded')} className="h-8 w-8 text-neutral-600" /> : isPartiallyRefunded ? <AlertTriangle aria-label={t('buyerAccount.orderConfirmationPage.orderPartiallyRefunded')} className="h-8 w-8 text-amber-700" /> : <CheckCircle aria-label={t('buyerAccount.orderConfirmationPage.orderConfirmed')} className="h-8 w-8 text-emerald-700" />}
          </div>
          <h1 className="text-3xl font-bold tracking-tight text-neutral-950">
            {awaitingPayment ? t('buyerAccount.orderConfirmationPage.yourPaymentIsNotComplete') : isProcessing ? t('buyerAccount.orderConfirmationPage.paymentIsProcessing') : order.status === 'refunded' ? t('buyerAccount.orderConfirmationPage.yourOrderWasRefunded') : order.status === 'partially_refunded' ? t('buyerAccount.orderConfirmationPage.yourOrderWasPartiallyRefunded') : order.status === 'cancelled' ? t('buyerAccount.orderConfirmationPage.orderCancelled') : order.status === 'expired' ? t('buyerAccount.orderConfirmationPage.reservationExpired') : t('buyerAccount.orderConfirmationPage.yourOrderIsConfirmed')}
          </h1>
          <p className="mt-2 break-words text-neutral-600">{t('buyerAccount.orderConfirmationPage.order2', { reference: order.reference, email: order.buyer_email })}</p>
          {['test', 'simulate', 'simulated'].includes(order.payment_environment) && <p className="mt-3 rounded-lg bg-amber-100 p-3 font-semibold text-amber-950">{t('buyerAccount.orderConfirmationPage.testOrderNoRealCharge')}</p>}
          {order.receipt_available === false && <p className="mt-3 rounded-lg bg-amber-100 p-3 font-semibold text-amber-950">{t('buyerAccount.orderConfirmationPage.checkoutNotCompleted')}</p>}
          {(order.completed_at || order.created_at) && <p className="mt-1 text-sm text-neutral-600">{t('buyerAccount.orderConfirmationPage.orderedOn', { date: formatEventDate(order.completed_at || order.created_at, order.event.timezone) })}</p>}
          {finalStatuses.has(order.status) && order.receipt_available !== false && <button type="button" onClick={downloadReceipt} disabled={receiptState === 'loading'} className="btn-secondary mt-4 min-h-11">{receiptState === 'loading' ? t('buyerAccount.orderConfirmationPage.preparingReceipt') : t('buyerAccount.orderConfirmationPage.downloadReceipt')}</button>}
          {receiptState === 'error' && <p role="alert" className="mt-2 text-sm text-red-700">{t('buyerAccount.orderConfirmationPage.receiptDownloadFailed')}</p>}
          {awaitingPayment ? <div className="mt-3">
            <p className="mb-3 text-sm text-amber-700">{t('buyerAccount.orderConfirmationPage.yourTicketsAreHeldUntilResumeTheOriginal', { time: formatEventTime(order.expires_at, event.timezone, { second: '2-digit' }) })}</p>
            <Link to={`/checkout/${event.slug}?resume=${order.id}`} className="btn-primary">{t('buyerAccount.orderConfirmationPage.resumePayment')}</Link>
          </div> : isProcessing && <p className="mt-2 text-sm text-amber-700">{t('buyerAccount.orderConfirmationPage.thisPageRefreshesAutomaticallyDoNotSubmitAnother')}</p>}
        </div>

        {change && (
          <section id="order-event-change" className="mb-6 scroll-mt-24 rounded-2xl border border-amber-200 bg-amber-50 p-5">
            <h2 className="font-semibold text-amber-950">{t('buyerAccount.orderConfirmationPage.event', { change: t(`buyerAccount.orderConfirmationPage.eventStatus.${change.change_type}`, { defaultValue: change.change_type }) })}</h2>
            <p className="mt-1 text-sm text-amber-900">{change.reason || t('buyerAccount.orderConfirmationPage.theOrganizerChangedThisEventReviewTheUpdated')}</p>
            {change.response && <p className="mt-3 text-sm font-medium text-amber-950">{t('buyerAccount.orderConfirmationPage.yourResponse', { response: t(`buyerAccount.orderConfirmationPage.changeResponse.${change.response}`, { defaultValue: change.response.replace('_', ' ') }) })}</p>}
            {showCancelledRefundStatus && <p role="status" className="mt-3 text-sm font-semibold text-amber-950">{cancelledRefund.status === 'refunded'
              ? cancelledRefund.refunded_at
                ? t(cancelledRefund.payment_method === 'door_cash' ? 'buyerAccount.orderConfirmationPage.cancelledCashRefunded' : 'buyerAccount.orderConfirmationPage.cancelledCardRefunded', { amount: formatMoneyCents(cancelledRefund.amount_cents || 0), date: formatEventDate(cancelledRefund.refunded_at, event.timezone) })
                : t('buyerAccount.orderConfirmationPage.cancelledRefundComplete')
              : t({ needs_cash_return: 'buyerAccount.orderConfirmationPage.cancelledCashReturnPending',
                needs_attention: 'buyerAccount.orderConfirmationPage.cancelledRefundNeedsAttention',
                awaiting_dispute: 'buyerAccount.orderConfirmationPage.cancelledRefundAwaitingDispute',
                resolved: 'buyerAccount.orderConfirmationPage.cancelledPaymentResolved',
              }[cancelledRefund.status] || 'buyerAccount.orderConfirmationPage.cancelledRefundProcessing')}</p>}
            {canRespondToChange && (!showCancelledRefundStatus || refundNeedsStatusCheck(eventRefundAttempt)) && (
              <div className="mt-4 flex flex-col gap-2 sm:flex-row">
                {!change.response && change.change_type !== 'cancelled' && (
                  <button className="btn-secondary" disabled={decisionBusy} onClick={() => respondToChange('accepted')}>{t('buyerAccount.orderConfirmationPage.keepMyTickets')}</button>
                )}
                <button className="rounded-xl border border-red-300 bg-white px-4 py-2.5 text-sm font-semibold text-red-700" disabled={decisionBusy || eventRefundAttempt?.status === 'succeeded'} onClick={() => respondToChange('refund_requested')}>{refundButton(eventRefundAttempt, refundNeedsRetry ? t('buyerAccount.orderConfirmationPage.retryRefund') : t('buyerAccount.orderConfirmationPage.requestRefund'))}</button>
              </div>
            )}
            {eventRefundAttempt && <p role="status" className="mt-3 text-sm text-amber-950">{refundNotice(eventRefundAttempt)}</p>}
            {eventRefundAttempt?.status === 'finance_review' && <SupportLink subject={t('buyerAccount.orderConfirmationPage.refundReviewForOrder', { reference: order.reference })} fallbackHref={SUPPORT_FALLBACK_PATH} className="inline-flex min-h-11 items-center font-semibold text-brand-700 underline">{t('buyerAccount.orderConfirmationPage.contactSupport')}</SupportLink>}
            {decisionState === 'error' && !eventRefundAttempt && <p className="mt-3 text-sm text-red-700">{t('buyerAccount.orderConfirmationPage.weCouldNotSaveThatChoicePleaseTry')}</p>}
          </section>
        )}

        {ticketsAvailable && (
          <section id="order-tickets" className="card mb-6 scroll-mt-24 p-5 sm:p-6">
            <div className="mb-4 flex items-center justify-between">
              <h2 className="font-semibold text-neutral-950">{t('buyerAccount.orderConfirmationPage.tickets', { count: order.tickets.length })}</h2>
              {['completed', 'partially_refunded'].includes(order.status) && (
                <button onClick={resend} disabled={resendState === 'sending' || resendState === 'uncertain' || deliveryUnconfirmed} className="inline-flex items-center gap-1.5 text-sm font-semibold text-brand-700"><Mail className="h-4 w-4" />{t('buyerAccount.orderConfirmationPage.resend')}</button>
              )}
            </div>
            {resendState === 'requested' && <p className="mb-3 text-sm text-neutral-700">{t('buyerAccount.orderConfirmationPage.yourEmailRequestWasSavedCheckTheDelivery')}</p>}
            {resendState === 'cooldown' && <p className="mb-3 text-sm text-amber-700">{t('buyerAccount.orderConfirmationPage.anEmailRequestWasMadeRecentlyPleaseWait')}</p>}
            {resendState === 'uncertain' && <p className="mb-3 text-sm text-amber-700">{t('buyerAccount.orderConfirmationPage.aPreviousTicketEmailIsStillUnconfirmedUse')}</p>}
            {resendState === 'error' && <p className="mb-3 text-sm text-red-700">{t('buyerAccount.orderConfirmationPage.unableToResendRightNow')}</p>}
            {ticketActionError && <p className="mb-3 text-sm text-red-700">{ticketActionError}</p>}
            {ticketActionNotice && <p role="status" className="mb-3 text-sm text-brand-800">{ticketActionNotice}</p>}
            {transferTarget && <TransferTicketDialog ticketLabel={t('buyerAccount.orderConfirmationPage.transferTicketLabel', { name: transferTarget.ticket_type.name })} onSend={sendTransfer(transferTarget)} onClose={() => setTransferTarget(null)} />}
            <div className="divide-y divide-neutral-100">
              {order.tickets.map(ticket => {
                const canOpenTicket = ticket.status === 'issued' && usableTickets && ticket.admission_allowed === true && !ticket.admission_block_reason
                const ticketRefundAttempt = getBuyerRefundAttempt(id, `ticket:${ticket.id}`)
                const exchangeOptions = exchangeMap?.sections.flatMap(section => section.rows.flatMap(row =>
                  row.seats.filter(seat => seat.status === 'available' && seat.ticket_type_id === ticket.ticket_type.id &&
                    seat.accessibility_kind === ticket.seat?.accessibility_kind)
                )) || []
                const selectedExchangeSeat = exchangeOptions.find(seat => seat.id === Number(exchangeSeatId))
                return <div key={ticket.id} className="py-3">
                <div className="flex flex-col items-start justify-between gap-3 sm:flex-row sm:items-center">
                  <div className="min-w-0 flex-1">
                    <p className="break-words font-medium text-neutral-900">{ticket.ticket_type.name}</p>
                    {ticket.seat && <p className="text-sm font-semibold text-brand-700">{ticket.seat.display_label}</p>}
                    <p className="text-xs capitalize text-neutral-600">{ticket.attendee_name || t('buyerAccount.orderConfirmationPage.newHolder')} · {t(`buyerAccount.orderConfirmationPage.ticketStatus.${ticket.status}`, { defaultValue: ticket.status.replace('_', ' ') })}</p>
                    {ticket.admission_block_reason && <p className="mt-1 text-sm text-amber-800">{ticket.admission_block_reason}</p>}
                    {ticket.status === 'issued' && ticket.pending_transfer && <PendingTransfer transfer={ticket.pending_transfer} timeZone={event.timezone}
                      onCancel={() => apiClient.delete(`/orders/${id}/tickets/${ticket.id}/transfer`, { headers: orderHeaders() })}
                      onSettled={({ message }) => { setTicketActionNotice(message); fetchOrder({ preserveOrder: true }) }} />}
                  </div>
                  <div className="flex flex-wrap items-center gap-2">
                    {ticket.display_credential && <Link to={`/tickets/${encodeURIComponent(ticket.display_credential)}?order=${id}`}
                      className={canOpenTicket ? 'btn-primary min-h-11 gap-2' : 'btn-secondary min-h-11 gap-2'}
                      aria-label={canOpenTicket ? t('buyerAccount.orderConfirmationPage.openTicket', { name: ticket.ticket_type.name }) : t('buyerAccount.orderConfirmationPage.viewTicket')}>
                      <Ticket aria-hidden="true" className="h-4 w-4" />{canOpenTicket ? t('buyerAccount.orderConfirmationPage.openTicket2') : t('buyerAccount.orderConfirmationPage.viewTicketStatus')}
                    </Link>}
                    {ticket.status === 'issued' && (
                      <button onClick={() => rotateTicket(ticket)} disabled={rotatingTicketId === ticket.id} className="min-h-11 px-2 text-xs font-semibold text-neutral-600">{rotatingTicketId === ticket.id ? t('buyerAccount.orderConfirmationPage.refreshing') : t('buyerAccount.orderConfirmationPage.refreshQR')}</button>
                    )}
                    {(ticket.status === 'issued' && (ticket.refundable_cents === 0 || ['cancelled', 'postponed'].includes(event.status)) || refundNeedsStatusCheck(ticketRefundAttempt)) && (
                      <button onClick={() => cancelTicket(ticket)} disabled={cancellingTicketId === ticket.id || ticketRefundAttempt?.status === 'succeeded'} className="min-h-11 px-2 text-xs font-semibold text-red-600">{cancellingTicketId === ticket.id ? t('buyerAccount.orderConfirmationPage.checking') : ticketRefundAttempt || ticket.refundable_cents > 0 ? refundButton(ticketRefundAttempt) : t('buyerAccount.orderConfirmationPage.cancel')}</button>
                    )}
                    {ticket.status === 'issued' && !ticket.pending_transfer && capabilities.ticket_transfers === true && event.transfers_enabled === true && transfersOpen && (
                      <button type="button" onClick={() => { setTicketActionError(null); setTransferTarget(ticket) }} className="min-h-11 px-2 text-xs font-semibold text-brand-700">{t('buyerAccount.orderConfirmationPage.transfer')}</button>
                    )}
                    {ticket.status === 'issued' && ticket.seat && (
                      <button onClick={() => openSeatExchange(ticket)} className="min-h-11 px-2 text-xs font-semibold text-brand-700">{t('buyerAccount.orderConfirmationPage.changeSeat')}</button>
                    )}

                  </div>
                </div>
                {ticketRefundAttempt && <p role="status" className="mt-2 text-sm text-neutral-700">{refundNotice(ticketRefundAttempt)}</p>}
                {ticketRefundAttempt?.status === 'finance_review' && <SupportLink subject={t('buyerAccount.orderConfirmationPage.refundReviewForOrder', { reference: order.reference })} fallbackHref={SUPPORT_FALLBACK_PATH} className="inline-flex min-h-11 items-center text-sm font-semibold text-brand-700 underline">{t('buyerAccount.orderConfirmationPage.contactSupport')}</SupportLink>}
                {exchangeTicketId === ticket.id && (
                  <div className="mt-3 rounded-xl border border-brand-200 bg-brand-50 p-4">
                    <label className="block text-sm font-medium text-neutral-800">{t('buyerAccount.orderConfirmationPage.availableEquivalentSeats')}<select className="input mt-1" value={exchangeSeatId} onChange={eventValue => setExchangeSeatId(eventValue.target.value)}>
                        <option value="">{t('buyerAccount.orderConfirmationPage.chooseASeat')}</option>
                        {exchangeOptions.map(seat => <option key={seat.id} value={seat.id}>{seat.display_label}</option>)}
                      </select>
                    </label>
                    {selectedExchangeSeat?.requires_accessibility_attestation && (
                      <label className="mt-3 flex items-start gap-2 text-sm text-neutral-700"><input type="checkbox" className="mt-1" checked={exchangeAttested} onChange={eventValue => setExchangeAttested(eventValue.target.checked)} />{t('buyerAccount.orderConfirmationPage.iAttestThatThisPartyNeedsAnAccessible')}</label>
                    )}
                    <div className="mt-3 flex gap-2">
                      <button className="btn-primary !px-3 !py-2 text-sm" disabled={!exchangeSeatId || (selectedExchangeSeat?.requires_accessibility_attestation && !exchangeAttested)} onClick={() => exchangeSeat(ticket)}>{t('buyerAccount.orderConfirmationPage.confirmSeatChange')}</button>
                      <button className="btn-secondary !px-3 !py-2 text-sm" onClick={() => setExchangeTicketId(null)}>{t('buyerAccount.orderConfirmationPage.cancel')}</button>
                    </div>
                  </div>
                )}
              </div>
              })}
            </div>
          </section>
        )}

        <section className={`mb-6 rounded-xl border p-4 text-sm ${deliveryFailed || deliveryUnconfirmed ? 'border-amber-200 bg-amber-50 text-amber-950' : 'border-neutral-200 bg-white text-neutral-700'}`} aria-labelledby="confirmation-delivery-title">
          <h2 id="confirmation-delivery-title" className="font-semibold">{t('buyerAccount.orderConfirmationPage.ticketEmail')}</h2>
          <p className="mt-1" role="status">{deliveryMessage}</p>
          {deliveryUnconfirmed && delivery?.status === 'delivered' && <p className="mt-2" role="status">{t('buyerAccount.orderConfirmationPage.aPreviousTicketEmailRequestStillHasAn')}</p>}
          {!delivery?.simulated && <button onClick={refreshDeliveryStatus} disabled={deliveryRefreshing} className="mt-2 inline-flex min-h-11 items-center gap-1.5 font-semibold text-brand-700 disabled:opacity-50"><RefreshCw className="h-4 w-4" />{deliveryRefreshing ? t('buyerAccount.orderConfirmationPage.refreshingStatus') : t('buyerAccount.orderConfirmationPage.refreshStatus')}</button>}
          {deliveryRefreshError && <p className="mt-1 text-amber-800" role="alert">{deliveryRefreshError}</p>}
          {emailUpdatesPaused && emailInFlightStatuses.has(delivery?.status) && <p className="mt-1 text-neutral-600">{t('buyerAccount.orderConfirmationPage.automaticEmailUpdatesHavePausedUseRefreshStatus')}</p>}
          {(deliveryFailed || deliveryUnconfirmed) && <div className="mt-2 flex flex-wrap gap-x-4 gap-y-2">
            {usableTickets && <a href="#order-tickets" className="inline-flex min-h-11 items-center font-semibold text-brand-700 underline">{t('buyerAccount.orderConfirmationPage.openOrDownloadTickets')}</a>}
            <SupportLink subject={t('buyerAccount.orderConfirmationPage.ticketEmailForOrder', { reference: order.reference })} fallbackHref={SUPPORT_FALLBACK_PATH} className="inline-flex min-h-11 items-center font-semibold text-brand-700 underline">{t('buyerAccount.orderConfirmationPage.contactSupport')}</SupportLink>
          </div>}
        </section>


        <section className="card mb-6 overflow-hidden">
          <div className="border-b border-neutral-100 p-5 sm:p-6">
            <p className="min-h-11 px-2 text-xs font-semibold uppercase tracking-wider text-brand-700">{t(`buyerAccount.orderConfirmationPage.eventStatus.${event.status}`, { defaultValue: event.status })}</p>
            <h2 className="mt-1 text-xl font-bold text-neutral-950">{eventContent.title}</h2>
            <MachineTranslationNotice {...eventContent.notice} />
            <p className="mt-2 text-sm text-neutral-600">{formatEventDate(event.starts_at, event.timezone, { weekday: 'long' })} · {formatEventTime(event.starts_at, event.timezone)}</p>
            <p className="text-sm text-neutral-600">{event.venue_name}{event.venue_address ? ` · ${event.venue_address}` : ''}</p>
            <SellerLine seller={order.seller} className="mt-2" />
          </div>
          <div className="space-y-2 p-5 text-sm sm:p-6">
            {order.order_items.map(item => (
              <div key={item.id} className="flex justify-between gap-4"><span>{item.name || item.item_name} × {item.quantity}</span><span>{formatPrice(item.subtotal_cents)}</span></div>
            ))}
            <div className="flex justify-between gap-4 border-t border-neutral-100 pt-3 text-neutral-600"><span>{t('buyerAccount.orderConfirmationPage.serviceFee')}{order.processing_fee_bearer === 'platform' && order.service_fee_cents > 0 && <span className="block text-xs text-neutral-500">{t('buyerAccount.orderConfirmationPage.includesCardProcessing')}</span>}</span><span>{formatMoneyCents(order.service_fee_cents || 0)}</span></div>
            {order.discount_cents > 0 && <div className="flex justify-between text-emerald-700"><span>{t('buyerAccount.orderConfirmationPage.discount')}</span><span>−{formatPrice(order.discount_cents)}</span></div>}
            <div className="flex justify-between pt-1 text-lg font-bold text-neutral-950"><span>{t('buyerAccount.orderConfirmationPage.total')}</span><span>{formatPrice(order.total_cents)}</span></div>
            {order.refunded_cents > 0 && <div className="flex justify-between text-sm font-medium text-red-700"><span>{t('buyerAccount.orderConfirmationPage.refunded')}</span><span>−{formatPrice(order.refunded_cents)}</span></div>}
            {order.payment_method && <p className="border-t border-neutral-100 pt-3 text-sm text-neutral-600">{t('buyerAccount.orderConfirmationPage.paymentMethod')}: {order.payment_method.card_brand && order.payment_method.last4 ? t('buyerAccount.orderConfirmationPage.cardEnding', { brand: order.payment_method.card_brand, last4: order.payment_method.last4 }) : t(`buyerAccount.orderConfirmationPage.paymentTypes.${order.payment_method.type}`, { defaultValue: t('buyerAccount.orderConfirmationPage.paymentTypes.other') })}</p>}
            {order.seller?.seller_name && (
              <p className="border-t border-neutral-100 pt-3 text-xs leading-5 text-neutral-500" data-testid="receipt-seller">{t(order.seller.operator_name ? 'buyerAccount.orderConfirmationPage.sellerWithOperator' : 'buyerAccount.orderConfirmationPage.seller', { seller: order.seller.seller_name, service: order.seller.ticketing_service, operator: order.seller.operator_name })}</p>
            )}
          </div>
        </section>

        <section className="card mb-6 p-5 sm:p-6" aria-labelledby="refund-history-title">
          <h2 id="refund-history-title" className="font-semibold text-neutral-950">{t('buyerAccount.orderConfirmationPage.refundHistory')}</h2>
          {order.refund_history?.length ? <ul className="mt-3 space-y-3 text-sm">{order.refund_history.map(refund => <li key={refund.id} className="flex flex-wrap justify-between gap-2 border-t border-neutral-100 pt-3">
            <span>{formatMoneyCents(refund.amount_cents)} · {t(`buyerAccount.orderConfirmationPage.refundStatus.${refund.status}`)}</span>
            <span className="text-neutral-600">{formatEventDate(refund.requested_at, event.timezone)}</span>
          </li>)}</ul> : <p className="mt-2 text-sm text-neutral-600">{t('buyerAccount.orderConfirmationPage.noRefunds')}</p>}
          {(canRespondToChange || order.tickets?.some(ticket => ticket.status === 'issued' && ticket.refundable_cents > 0 && ['cancelled', 'postponed'].includes(event.status))) && <a href={canRespondToChange ? '#order-event-change' : '#order-tickets'} className="mt-3 inline-flex min-h-11 items-center font-semibold text-brand-700 underline">{t('buyerAccount.orderConfirmationPage.requestRefund')}</a>}
        </section>


        <div className="flex items-center justify-center gap-5 text-sm font-medium">
          <button onClick={fetchOrder} className="inline-flex items-center gap-1.5 text-neutral-600"><RefreshCw className="h-4 w-4" />{t('buyerAccount.orderConfirmationPage.refresh')}</button>
          <Link to="/events" className="text-brand-700">{t('buyerAccount.orderConfirmationPage.browseEvents')}</Link>
          {!getOrderAccess(id) && <Link to="/my-tickets" className="text-brand-700">{t('buyerAccount.orderConfirmationPage.myTickets')}</Link>}
        </div>
      </div>
    </div>
  )
}
