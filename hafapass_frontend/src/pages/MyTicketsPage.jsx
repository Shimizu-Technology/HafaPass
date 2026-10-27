import { useTranslation } from 'react-i18next'
import { useState, useEffect, useCallback, useRef } from 'react'
import { Link, useLocation, useNavigate } from 'react-router-dom'
import { Loader2, Ticket } from 'lucide-react'
import { useAuth, useClerk } from '@clerk/clerk-react'
import apiClient from '../api/client'
import SEO from '../components/SEO'
import TicketStock from '../components/Ticket'
import BuyerTitleBand from '../components/BuyerTitleBand'
import BuyerTicketPass from '../components/BuyerTicketPass'
import { formatEventDate, formatEventTime } from '../utils/eventTime'
import { formatMoneyCents } from '../utils/money'
import { signInDestination } from '../utils/authDestination'
import TransferTicketDialog from '../components/TransferTicketDialog'
import useLaunchCapabilities from '../hooks/useLaunchCapabilities'
import InstallAppHelp from '../components/InstallAppHelp'

const TICKETS_PER_PAGE = 100
const MAX_TICKET_PAGES = 20

// This route sits behind ProtectedRoute, so a 401 means Clerk still holds a session the
// API no longer accepts. Refresh the token once; if that fails, end the stale Clerk
// session so the sign-in page does not bounce the visitor straight back here.
function ClerkMyTicketsPage() {
  const { getToken } = useAuth()
  const { signOut } = useClerk()
  const refreshSession = useCallback(() => getToken({ skipCache: true }), [getToken])
  return <MyTicketsContent refreshSession={refreshSession} signOut={signOut} />
}

export default function MyTicketsPage() {
  return import.meta.env.VITE_CLERK_PUBLISHABLE_KEY ? <ClerkMyTicketsPage /> : <MyTicketsContent />
}

function MyTicketsContent({ refreshSession, signOut }) {
  const { t } = useTranslation()
  const location = useLocation()
  const navigate = useNavigate()
  const [signedOut, setSignedOut] = useState(false)
  const [orders, setOrders] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [recovering, setRecovering] = useState(false)
  const [recoveryError, setRecoveryError] = useState(null)
  const [transferTarget, setTransferTarget] = useState(null)
  const [ticketNotice, setTicketNotice] = useState(null)
  const [ticketsCapped, setTicketsCapped] = useState(false)
  const tab = new URLSearchParams(location.search).get('tab') === 'orders' ? 'orders' : 'tickets'
  const activeTab = useRef(tab)
  useEffect(() => { activeTab.current = tab }, [tab])
  const [purchases, setPurchases] = useState([])
  const [purchaseMeta, setPurchaseMeta] = useState(null)
  const [purchaseLoading, setPurchaseLoading] = useState(false)
  const [purchaseError, setPurchaseError] = useState(false)
  const purchaseRequest = useRef(0)
  const ticketRequest = useRef(0)
  const firstPageLoaded = useRef(false)
  const capabilities = useLaunchCapabilities()

  const loadAllTickets = useCallback(async (onPage = () => {}) => {
    const request = ++ticketRequest.current
    const current = () => request === ticketRequest.current
    setTicketsCapped(false)
    const all = []
    let page = 1
    const seen = new Set()
    while (page && !seen.has(page) && seen.size < MAX_TICKET_PAGES) {
      seen.add(page)
      let response
      try {
        response = await apiClient.get('/me/tickets', { params: { page, per_page: TICKETS_PER_PAGE } })
      } catch (err) {
        if (!current()) return
        if (err.response?.status !== 401 || !refreshSession) throw err
        try {
          await refreshSession()
        } catch {
          if (!current()) return
          throw new Error('Session refresh failed')
        }
        if (!current()) return
        response = await apiClient.get('/me/tickets', { params: { page, per_page: TICKETS_PER_PAGE } })
      }
      if (!current()) return
      all.push(...(response.data.tickets || []))
      onPage(all)
      const next = Number(response.data.meta?.next_page)
      page = Number.isInteger(next) && next > page && !seen.has(next) ? next : null
    }
    if (current() && page && seen.size === MAX_TICKET_PAGES) setTicketsCapped(true)
    return all
  }, [refreshSession])

  const showTickets = useCallback(tickets => {
    firstPageLoaded.current = true
    setOrders(tickets.map(ticket => ({ id: ticket.order_id, event: ticket.event, tickets: [ticket] })))
    setLoading(false)
  }, [])

  const loadPurchases = useCallback(async (page = 1) => {
    const request = ++purchaseRequest.current
    setPurchaseLoading(true)
    setPurchaseError(false)
    try {
      let response
      try {
        response = await apiClient.get('/me/orders', { params: { page } })
      } catch (err) {
        if (err.response?.status !== 401 || !refreshSession) throw err
        await refreshSession().catch(() => { throw new Error('Session refresh failed') })
        response = await apiClient.get('/me/orders', { params: { page } })
      }
      if (request !== purchaseRequest.current) return
      setPurchases(response.data.orders || [])
      setPurchaseMeta(response.data.meta || null)
    } catch {
      if (request === purchaseRequest.current) setPurchaseError(true)
    } finally {
      if (request === purchaseRequest.current) setPurchaseLoading(false)
    }
  }, [refreshSession])

  const recoverGuestPurchases = useCallback(async () => {
    setRecovering(true)
    setRecoveryError(null)
    try {
      const response = await apiClient.post('/me/orders/recover_guest')
      if ((response.data?.recovered_orders_count || 0) > 0 || (response.data?.recovered_tickets_count || 0) > 0) {
        await loadAllTickets(showTickets)
        if (activeTab.current === 'orders') await loadPurchases(1)
      }
    } catch {
      setRecoveryError(t('buyerAccount.myTicketsPage.weCouldNotCheckForGuestPurchasesYet'))
    } finally {
      setRecovering(false)
    }
  }, [loadAllTickets, loadPurchases, showTickets, t])

  const fetchOrders = useCallback(async () => {
    firstPageLoaded.current = false
    setError(null)
    setSignedOut(false)
    try {
      await loadAllTickets(showTickets)
      await recoverGuestPurchases()
    } catch (err) {
      if (err.response?.status === 401) {
        // An expired session is not a failure; invite the visitor to sign in again.
        setSignedOut(true)
      } else {
        if (!firstPageLoaded.current) setError(t('buyerAccount.myTicketsPage.weCouldnTLoadYourTicketsTryAgain'))
        else setTicketNotice(t('buyerAccount.myTicketsPage.weCouldnTRefreshYourTicketsReloadThe'))
      }
    } finally {
      setLoading(false)
    }
  }, [loadAllTickets, recoverGuestPurchases, showTickets, t])

  useEffect(() => {
    fetchOrders()
  }, [fetchOrders])

  useEffect(() => {
    if (tab === 'orders') loadPurchases(1)
  }, [tab, loadPurchases])

  // Reload after a transfer change. A ticket the recipient already accepted
  // drops out of this list, because it now belongs to them.
  const refreshTickets = useCallback(async () => {
    try {
      await loadAllTickets(showTickets)
    } catch {
      setTicketNotice(t('buyerAccount.myTicketsPage.weCouldnTRefreshYourTicketsReloadThe'))
    }
  }, [loadAllTickets, showTickets, t])

  const recoveryNotice = (
    <div className="mb-5 text-sm" role="status">
      {ticketNotice && <p className="rounded-xl border border-brand-200 bg-brand-50 p-4 text-brand-900">{ticketNotice}</p>}
      {ticketsCapped && <p className="rounded-xl border border-amber-200 bg-amber-50 p-4 text-amber-900">{t('buyerAccount.myTicketsPage.ticketLimitNotice', { count: orders.length })}</p>}
      {recovering && <p className="sr-only">{t('buyerAccount.myTicketsPage.checkingForPurchasesMadeBeforeYouSignedIn')}</p>}
      {recoveryError && <div className="rounded-xl border border-amber-200 bg-amber-50 p-4 text-amber-900">
        <p>{recoveryError}</p>
        <button onClick={recoverGuestPurchases} disabled={recovering} className="mt-2 min-h-11 font-semibold underline">{t('buyerAccount.myTicketsPage.retryGuestPurchaseRecovery')}</button>
      </div>}
    </div>
  )

  if (signedOut) {
    return (
      <div className="public-listing-min-height bg-stone-50">
        <SEO title={t('buyerAccount.myTicketsPage.myTickets')} />
        <BuyerTitleBand compact title={t('buyerAccount.myTicketsPage.myTickets')} description={t('buyerAccount.myTicketsPage.yourEventPassesAllInOnePlace')} />
        <div className="mx-auto max-w-md px-4 py-8"><div className="card p-6 sm:p-8 text-center">
          <Ticket aria-hidden="true" className="mx-auto h-10 w-10 text-brand-700" />
          <h2 className="mt-4 text-xl font-semibold text-neutral-900">{t('buyerAccount.myTicketsPage.yourSessionExpired')}</h2>
          <p className="mt-2 text-neutral-600">{t('buyerAccount.myTicketsPage.signInAgainToSeeYourTickets')}</p>
          {signOut
            ? <button type="button" onClick={() => signOut({ redirectUrl: signInDestination(location) })} className="btn-primary mt-6 w-full sm:w-auto">{t('buyerAccount.myTicketsPage.signInAgain')}</button>
            : <Link to={signInDestination(location)} className="btn-primary mt-6 w-full sm:w-auto">{t('buyerAccount.myTicketsPage.signInAgain')}</Link>}
        </div></div>
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

  function getStatusBadge(ticket) {
    if (ticket.status === 'issued' && ticket.admission_allowed !== true) return <span className="inline-flex rounded-full bg-amber-100 px-2.5 py-0.5 text-xs font-medium text-amber-900">{t('buyerAccount.myTicketsPage.entryPaused')}</span>
    switch (ticket.status) {
      case 'issued':
        return <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-brand-50 text-brand-900">{t('buyerAccount.myTicketsPage.valid')}</span>
      case 'checked_in':
        return <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-neutral-100 text-neutral-600">{t('buyerAccount.myTicketsPage.used')}</span>
      case 'cancelled':
        return <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-red-100 text-red-800">{t('buyerAccount.myTicketsPage.cancelled')}</span>
      case 'transferred':
        return <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-yellow-100 text-yellow-800">{t('buyerAccount.myTicketsPage.transferred')}</span>
      default:
        return null
    }
  }

  const sendTransfer = ticket => async body => {
    await apiClient.post(`/me/tickets/${ticket.id}/transfer`, body)
    refreshTickets()
  }

  return (
    <div className="public-listing-min-height bg-stone-50 tabular-nums">
      <SEO title={t('buyerAccount.myTicketsPage.myTickets')} />
      <BuyerTitleBand compact title={t('buyerAccount.myTicketsPage.myTickets')} description={t('buyerAccount.myTicketsPage.yourEventPassesAllInOnePlace')} />
      <div className="bg-stone-50">
        <div className="mx-auto max-w-3xl px-4 py-6 sm:px-6">
          {recoveryNotice}
          <InstallAppHelp />
          <div className="mb-5 text-right"><Link to="/account/settings" className="inline-flex min-h-11 items-center text-sm font-semibold text-brand-700 underline">{t('buyerAccount.myTicketsPage.accountSettingsAndPrivacy')}</Link></div>
          <div role="tablist" aria-label={t('buyerAccount.myTicketsPage.purchaseHistory')} className="mb-6 grid w-56 max-w-full grid-cols-2 gap-1 rounded-xl border border-neutral-200 bg-neutral-100 p-1">
            {['tickets', 'orders'].map(value => <button key={value} type="button" role="tab" id={`history-${value}-tab`} aria-controls={`history-${value}-panel`} aria-selected={tab === value}
              tabIndex={tab === value ? 0 : -1}
              onKeyDown={event => {
                const values = ['tickets', 'orders']
                const index = values.indexOf(value)
                const next = event.key === 'ArrowRight' ? values[(index + 1) % values.length] : event.key === 'ArrowLeft' ? values[(index + values.length - 1) % values.length] : event.key === 'Home' ? values[0] : event.key === 'End' ? values[values.length - 1] : null
                if (!next) return
                event.preventDefault()
                navigate({ pathname: location.pathname, search: next === 'orders' ? '?tab=orders' : '' })
                requestAnimationFrame(() => document.getElementById(`history-${next}-tab`)?.focus())
              }}
              onClick={() => navigate({ pathname: location.pathname, search: value === 'orders' ? '?tab=orders' : '' })} className={`min-h-11 min-w-0 rounded-lg px-2 font-semibold focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2 ${tab === value ? 'bg-white text-brand-900' : 'text-neutral-600'}`}>
              {t(`buyerAccount.myTicketsPage.tabs.${value}`)}
            </button>)}
          </div>
          {tab === 'tickets'
            ? <div role="tabpanel" id="history-orders-panel" aria-labelledby="history-orders-tab" hidden />
            : <div role="tabpanel" id="history-tickets-panel" aria-labelledby="history-tickets-tab" hidden />}
          {tab === 'orders' ? <div role="tabpanel" id="history-orders-panel" aria-labelledby="history-orders-tab" className="space-y-4">
            {purchaseLoading && <p role="status" className="flex items-center gap-2 text-neutral-600"><Loader2 className="h-5 w-5 animate-spin" />{t('buyerAccount.myTicketsPage.loadingOrders')}</p>}
            {purchaseError && <div role="alert" className="card p-5"><p>{t('buyerAccount.myTicketsPage.ordersLoadError')}</p><button type="button" onClick={() => loadPurchases(purchaseMeta?.current_page || 1)} className="btn-secondary mt-3">{t('buyerAccount.myTicketsPage.tryAgain')}</button></div>}
            {!purchaseLoading && !purchaseError && purchases.length === 0 && <div className="card p-8 text-center">
              <h2 className="text-xl font-semibold">{recovering ? t('buyerAccount.myTicketsPage.lookingForYourOrders') : recoveryError ? t('buyerAccount.myTicketsPage.guestPurchasesNeedAnotherCheck') : t('buyerAccount.myTicketsPage.noOrdersYet')}</h2>
              <p className="mt-2 text-neutral-600">{t('buyerAccount.myTicketsPage.ordersEmptyHelp')}</p>
              <p className="mt-2 text-neutral-600">{t('pass.buyer.guestCheckoutHelp')}</p>
              <p className="mt-2 text-sm text-neutral-600">{t('pass.buyer.accountTicketsHelp')}</p>
              <Link to="/orders/recover" className="mt-4 inline-flex min-h-11 items-center font-semibold text-brand-700 underline">{t('pass.buyer.findTickets')}</Link>
            </div>}
            {!purchaseLoading && purchases.map(purchase => <Link key={purchase.id} to={`/orders/${purchase.id}/confirmation`} className="card block p-5 [overflow-wrap:anywhere] transition-colors hover:bg-brand-50 focus-visible:outline focus-visible:outline-2 focus-visible:outline-brand-600">
              <div className="flex flex-wrap items-start justify-between gap-2">
                <div>
                  <h2 className="text-lg font-semibold text-neutral-950">{purchase.event.title}</h2>
                  <p className="text-sm text-neutral-600">{formatEventDate(purchase.event.starts_at, purchase.event.timezone)} · {formatEventTime(purchase.event.starts_at, purchase.event.timezone)}</p>
                  <p className="mt-2 text-sm text-neutral-600">{t('buyerAccount.myTicketsPage.orderedOn', { date: formatEventDate(purchase.completed_at || purchase.created_at, purchase.event.timezone) })}</p>
                  <p className="text-sm text-neutral-600">{t('buyerAccount.myTicketsPage.orderNumber', { reference: purchase.reference })}</p>
                  {['test', 'simulate', 'simulated'].includes(purchase.payment_environment) && <p className="mt-2 font-semibold text-amber-900">{t('buyerAccount.myTicketsPage.testOrderNoRealCharge')}</p>}
                  {purchase.receipt_available === false && <p className="mt-2 font-semibold text-amber-900">{t('buyerAccount.myTicketsPage.checkoutNotCompleted')}</p>}
                </div>
                <div className="flex flex-wrap gap-2">
                  <span className="rounded-full bg-neutral-100 px-3 py-1 text-xs font-semibold text-neutral-800">{t(`buyerAccount.myTicketsPage.orderStatus.${purchase.buyer_status || purchase.status}`)}</span>
                  {purchase.refund_pending && <span className="rounded-full bg-amber-100 px-3 py-1 text-xs font-semibold text-amber-900">{t('buyerAccount.myTicketsPage.refundPending')}</span>}
                </div>
              </div>
              <ul className="mt-4 space-y-1 text-sm text-neutral-700">{purchase.order_items.map(item => <li key={item.id}>{item.name} × {item.quantity}</li>)}</ul>
              <div className="mt-4 grid grid-cols-2 gap-2 border-t border-neutral-200 pt-3 text-sm sm:grid-cols-3">
                <span>{t('buyerAccount.myTicketsPage.subtotal')}: {formatMoneyCents(purchase.subtotal_cents)}</span>
                <span>{t('buyerAccount.myTicketsPage.serviceFee')}: {formatMoneyCents(purchase.service_fee_cents)}</span>
                {purchase.discount_cents > 0 && <span>{t('buyerAccount.myTicketsPage.discount')}: −{formatMoneyCents(purchase.discount_cents)}</span>}
                <span className="font-semibold">{purchase.receipt_available === false ? t('buyerAccount.myTicketsPage.noCharge') : ['test', 'simulate', 'simulated'].includes(purchase.payment_environment) ? t('buyerAccount.myTicketsPage.testTotal') : purchase.total_cents === 0 ? t('buyerAccount.myTicketsPage.complimentary') : t('buyerAccount.myTicketsPage.totalPaid')}{purchase.receipt_available === false ? '' : `: ${formatMoneyCents(purchase.total_cents)}`}</span>
                {purchase.refunded_cents > 0 && <span>{t('buyerAccount.myTicketsPage.refundedAmount', { amount: formatMoneyCents(purchase.refunded_cents) })}</span>}
              </div>
            </Link>)}
            {!purchaseLoading && (purchaseMeta?.prev_page || purchaseMeta?.next_page) && <nav aria-label={t('buyerAccount.myTicketsPage.ordersPages')} className="flex items-center justify-between gap-3 pt-2">
              <button type="button" disabled={!purchaseMeta.prev_page} onClick={() => loadPurchases(purchaseMeta.prev_page)} className="btn-secondary disabled:opacity-50">{t('buyerAccount.myTicketsPage.previous')}</button>
              <span className="text-sm text-neutral-600">{t('buyerAccount.myTicketsPage.pageOf', { page: purchaseMeta.current_page, total: purchaseMeta.total_pages })}</span>
              <button type="button" disabled={!purchaseMeta.next_page} onClick={() => loadPurchases(purchaseMeta.next_page)} className="btn-secondary disabled:opacity-50">{t('buyerAccount.myTicketsPage.next')}</button>
            </nav>}
          </div> : error ? <div role="tabpanel" id="history-tickets-panel" aria-labelledby="history-tickets-tab" className="rounded-xl border border-red-200 bg-red-50 p-6 text-center" ><div role="alert"><p className="text-red-700">{error}</p><button type="button" onClick={fetchOrders} className="btn-secondary mt-4">{t('buyerAccount.myTicketsPage.tryAgain')}</button></div></div> : loading ? <div role="tabpanel" id="history-tickets-panel" aria-labelledby="history-tickets-tab" className="flex min-h-32 items-center justify-center"><Loader2 className="h-8 w-8 animate-spin text-brand-500" /></div> : eventGroups.length === 0 ? <div role="tabpanel" id="history-tickets-panel" aria-labelledby="history-tickets-tab">
            <TicketStock stub={<div className="px-6 py-4 sm:px-8"><Link to="/events" className="btn-primary w-full sm:w-auto">{t('buyerAccount.myTicketsPage.browseEvents')}</Link></div>}>
              <div className="px-6 py-6 sm:px-8">
                <Ticket aria-hidden="true" className="mb-4 h-8 w-8 text-brand-700" />
                <h2 className="font-display text-2xl font-bold text-neutral-950">{recovering ? t('buyerAccount.myTicketsPage.lookingForYourTickets') : recoveryError ? t('buyerAccount.myTicketsPage.guestPurchasesNeedAnotherCheck') : t('buyerAccount.myTicketsPage.noTicketsYet')}</h2>
                <p className="mt-3 text-neutral-600">{t('pass.buyer.guestCheckoutHelp')}</p>
                <Link to="/orders/recover" className="ticket-link inline-flex min-h-11 items-center rounded-lg font-semibold text-brand-800 underline underline-offset-4">{t('pass.buyer.findTickets')}</Link>
                <p className="mt-1 text-sm text-neutral-600">{t('pass.buyer.accountTicketsHelp')}</p>
              </div>
            </TicketStock>
          </div> : <div role="tabpanel" id="history-tickets-panel" aria-labelledby="history-tickets-tab" className="space-y-4">
            {eventGroups.flatMap(({ event, tickets }) => {
              const isPast = new Date(event.starts_at) < now
              return tickets.map(ticket => <BuyerTicketPass key={ticket.id} event={event} ticket={ticket} isPast={isPast} status={getStatusBadge(ticket)}
                canTransfer={ticket.status === 'issued' && !ticket.pending_transfer && capabilities.ticket_transfers === true && event.transfers_enabled === true && !isPast}
                onTransfer={() => setTransferTarget({ ticket, event })}
                onCancelTransfer={() => apiClient.delete(`/me/tickets/${ticket.id}/transfer`)}
                onTransferSettled={({ message }) => { setTicketNotice(message); refreshTickets() }} />)
            })}
          </div>}
        </div>
      </div>
      {transferTarget && (
        <TransferTicketDialog
          ticketLabel={t('buyerAccount.myTicketsPage.yourTicketFor', { name: transferTarget.ticket.ticket_type.name, title: transferTarget.event.title })}
          onSend={sendTransfer(transferTarget.ticket)}
          onClose={() => setTransferTarget(null)}
        />
      )}
    </div>
  )
}
