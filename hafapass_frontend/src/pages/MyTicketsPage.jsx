import useTranslatedContent from '../hooks/useTranslatedContent'
import MachineTranslationNotice from '../components/MachineTranslationNotice'
import { useTranslation } from 'react-i18next'
import { useState, useEffect, useCallback } from 'react'
import { Link, useLocation } from 'react-router-dom'
import { motion } from 'framer-motion'
import { Loader2, Ticket, Calendar, MapPin, Clock, ChevronRight, Download } from 'lucide-react'
import { useAuth, useClerk } from '@clerk/clerk-react'
import apiClient from '../api/client'
import SEO from '../components/SEO'
import { StaggerContainer, StaggerItem } from '../components/ui/ScrollReveal'
import NoiseOverlay from '../components/ui/NoiseOverlay'
import { formatEventDate, formatEventTime } from '../utils/eventTime'
import { signInDestination } from '../utils/authDestination'
import TransferTicketDialog from '../components/TransferTicketDialog'
import PendingTransfer from '../components/PendingTransfer'
import useLaunchCapabilities from '../hooks/useLaunchCapabilities'

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
  const [signedOut, setSignedOut] = useState(false)
  const [orders, setOrders] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [recovering, setRecovering] = useState(false)
  const [recoveryError, setRecoveryError] = useState(null)
  const [transferTarget, setTransferTarget] = useState(null)
  const [ticketNotice, setTicketNotice] = useState(null)
  const capabilities = useLaunchCapabilities()

  const recoverGuestPurchases = useCallback(async () => {
    setRecovering(true)
    setRecoveryError(null)
    try {
      await apiClient.post('/me/orders/recover_guest')
      const response = await apiClient.get('/me/tickets')
      setOrders((response.data.tickets || []).map(ticket => ({ id: ticket.order_id, event: ticket.event, tickets: [ticket] })))
    } catch {
      setRecoveryError(t('buyerAccount.myTicketsPage.weCouldNotCheckForGuestPurchasesYet'))
    } finally {
      setRecovering(false)
    }
  }, [t])

  const fetchOrders = useCallback(async () => {
    setError(null)
    setSignedOut(false)
    const loadTickets = async () => {
      try {
        return await apiClient.get('/me/tickets')
      } catch (err) {
        if (err.response?.status !== 401 || !refreshSession) throw err
        // If Clerk cannot refresh (offline, temporarily unavailable) the session may
        // still be fine, so this is a retryable load error rather than an expiry.
        try {
          await refreshSession()
        } catch {
          throw new Error('Session refresh failed')
        }
        return apiClient.get('/me/tickets')
      }
    }
    try {
      const response = await loadTickets()
      const tickets = response.data.tickets || []
      setOrders(tickets.map(ticket => ({ id: ticket.order_id, event: ticket.event, tickets: [ticket] })))
      setLoading(false)
      await recoverGuestPurchases()
    } catch (err) {
      if (err.response?.status === 401) {
        // An expired session is not a failure; invite the visitor to sign in again.
        setSignedOut(true)
      } else {
        setError(t('buyerAccount.myTicketsPage.weCouldnTLoadYourTicketsTryAgain'))
      }
    } finally {
      setLoading(false)
    }
  }, [recoverGuestPurchases, refreshSession, t])

  useEffect(() => {
    fetchOrders()
  }, [fetchOrders])

  // Reload after a transfer change. A ticket the recipient already accepted
  // drops out of this list, because it now belongs to them.
  const refreshTickets = useCallback(async () => {
    try {
      const response = await apiClient.get('/me/tickets')
      setOrders((response.data.tickets || []).map(ticket => ({ id: ticket.order_id, event: ticket.event, tickets: [ticket] })))
    } catch {
      setTicketNotice(t('buyerAccount.myTicketsPage.weCouldnTRefreshYourTicketsReloadThe'))
    }
  }, [t])

  const recoveryNotice = (
    <div className="mb-5 text-sm" role="status">
      {ticketNotice && <p className="rounded-xl border border-brand-200 bg-brand-50 p-4 text-brand-900">{ticketNotice}</p>}
      {recovering && <p className="text-neutral-600">{t('buyerAccount.myTicketsPage.checkingForPurchasesMadeBeforeYouSignedIn')}</p>}
      {recoveryError && <div className="rounded-xl border border-amber-200 bg-amber-50 p-4 text-amber-900">
        <p>{recoveryError}</p>
        <button onClick={recoverGuestPurchases} disabled={recovering} className="mt-2 min-h-11 font-semibold underline">{t('buyerAccount.myTicketsPage.retryGuestPurchaseRecovery')}</button>
      </div>}
    </div>
  )

  if (loading) {
    return (
      <div className="min-h-[60vh] flex items-center justify-center">
        <Loader2 className="w-8 h-8 text-brand-500 animate-spin" />
      </div>
    )
  }

  if (signedOut) {
    return (
      <div className="max-w-md mx-auto px-4 py-12">
        <SEO title={t('buyerAccount.myTicketsPage.myTickets')} />
        <div className="card p-6 sm:p-8 text-center">
          <Ticket aria-hidden="true" className="mx-auto h-10 w-10 text-brand-700" />
          <h1 className="mt-4 text-xl font-semibold text-neutral-900">{t('buyerAccount.myTicketsPage.yourSessionExpired')}</h1>
          <p className="mt-2 text-neutral-600">{t('buyerAccount.myTicketsPage.signInAgainToSeeYourTickets')}</p>
          {signOut
            ? <button type="button" onClick={() => signOut({ redirectUrl: signInDestination(location) })} className="btn-primary mt-6 w-full sm:w-auto">{t('buyerAccount.myTicketsPage.signInAgain')}</button>
            : <Link to={signInDestination(location)} className="btn-primary mt-6 w-full sm:w-auto">{t('buyerAccount.myTicketsPage.signInAgain')}</Link>}
        </div>
      </div>
    )
  }

  if (error) {
    return (
      <div className="max-w-2xl mx-auto px-4 py-12">
        <div role="alert" className="bg-red-50 border border-red-200 rounded-xl p-6 text-center">
          <p className="text-red-700">{error}</p>
          <button type="button" onClick={fetchOrders} className="btn-secondary mt-4">{t('buyerAccount.myTicketsPage.tryAgain')}</button>
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
        <SEO title={t('buyerAccount.myTicketsPage.myTickets')} />
        {/* Dark header */}
        <div className="bg-neutral-950 pt-8 pb-12 relative">
          <NoiseOverlay />
          <div className="max-w-3xl mx-auto px-4 sm:px-6 text-center relative z-[2]">
            <h1 className="font-display text-3xl sm:text-4xl font-bold tracking-tight text-white mb-2">{t('buyerAccount.myTicketsPage.myTickets')}</h1>
            <p className="text-neutral-400">{t('buyerAccount.myTicketsPage.yourEventPassesAllInOnePlace')}</p>
          </div>
        </div>
        <div className="h-px bg-gradient-to-r from-transparent via-brand-500/20 to-transparent" />
        <div className="bg-neutral-50 min-h-[40vh]">
          <motion.div
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            className="max-w-2xl mx-auto px-4 py-12 text-center"
          >
            {recoveryNotice}
            <div className="card p-8">
              <Ticket className="mx-auto h-16 w-16 text-neutral-300" />
              <h2 className="mt-4 text-xl font-semibold text-neutral-800">{recovering ? t('buyerAccount.myTicketsPage.lookingForYourTickets') : recoveryError ? t('buyerAccount.myTicketsPage.guestPurchasesNeedAnotherCheck') : t('buyerAccount.myTicketsPage.noTicketsYet')}</h2>
              <p className="mt-2 text-neutral-500">{t('buyerAccount.myTicketsPage.purchasesMadeWithAVerifiedEmailOnYour')}</p>
              <Link to="/orders/recover" className="mt-3 inline-block min-h-11 font-semibold text-brand-600 underline">{t('buyerAccount.myTicketsPage.recoverAnOrderByEmail')}</Link>
              <Link
                to="/events"
                className="mt-6 inline-block btn-primary px-6 py-3"
              >{t('buyerAccount.myTicketsPage.browseEvents')}</Link>
            </div>
          </motion.div>
        </div>
      </div>
    )
  }

  function formatDate(dateStr, event) {
    return formatEventDate(dateStr, event?.timezone, { weekday: 'short' })
  }

  function formatTime(dateStr, event) {
    return formatEventTime(dateStr, event?.timezone)
  }

  function getStatusBadge(status) {
    switch (status) {
      case 'issued':
        return <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-brand-50 text-brand-700">{t('buyerAccount.myTicketsPage.valid')}</span>
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
    <div>
      <SEO title={t('buyerAccount.myTicketsPage.myTickets')} />
      {/* Dark header */}
      <div className="bg-neutral-950 pt-8 pb-12 relative">
        <NoiseOverlay />
        <div className="max-w-3xl mx-auto px-4 sm:px-6 text-center relative z-[2]">
          <h1 className="font-display text-3xl sm:text-4xl font-bold tracking-tight text-white mb-2">{t('buyerAccount.myTicketsPage.myTickets')}</h1>
          <p className="text-neutral-400">{t('buyerAccount.myTicketsPage.yourEventPassesAllInOnePlace')}</p>
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
          {recoveryNotice}
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
                        <TranslatedEventHeading event={event} />
                        <p className="text-sm text-neutral-600 mt-0.5 flex items-center gap-1.5">
                          <Calendar className="w-3.5 h-3.5" />
                          {formatDate(event.starts_at, event)}
                          <Clock className="w-3.5 h-3.5 ml-1" />
                          {formatTime(event.starts_at, event)}
                        </p>
                        {event.venue_name && (
                          <p className="text-sm text-neutral-500 flex items-center gap-1.5 mt-0.5">
                            <MapPin className="w-3.5 h-3.5" />
                            {event.venue_name}
                          </p>
                        )}
                      </div>
                      {isPast && (
                        <span className="text-xs font-medium text-neutral-500 bg-neutral-200 px-2 py-1 rounded-xl">{t('buyerAccount.myTicketsPage.past')}</span>
                      )}
                    </div>
                  </div>

                  <div className="divide-y divide-neutral-100">
                    {tickets.map(ticket => (
                      <div key={ticket.id} className="px-4 sm:px-5 py-3 hover:bg-neutral-50 transition-colors">
                      <div className="flex items-center justify-between min-h-[28px]">
                        <Link
                          to={`/tickets/${encodeURIComponent(ticket.display_credential)}`}
                          className="flex items-center space-x-3 flex-1 min-w-0"
                        >
                          <div className="flex-shrink-0">
                            <Ticket className="h-5 w-5 text-neutral-400" />
                          </div>
                          <div>
                            <p className="text-sm font-medium text-neutral-900">{ticket.ticket_type.name}</p>
                            {ticket.seat && <p className="text-xs font-semibold text-brand-700">{ticket.seat.display_label}</p>}
                            {ticket.attendee_name && (
                              <p className="text-xs text-neutral-500">{ticket.attendee_name}</p>
                            )}
                          </div>
                        </Link>
                        <div className="flex items-center space-x-2">
                          {getStatusBadge(ticket.status)}
                          {ticket.status === 'issued' && !ticket.pending_transfer && capabilities.ticket_transfers === true && event.transfers_enabled === true && !isPast && <button type="button" onClick={() => setTransferTarget({ ticket, event })} className="min-h-11 px-2 text-xs font-semibold text-brand-700 rounded-lg transition-[background-color,transform] duration-150 ease-out-strong active:scale-[0.97] hover:bg-brand-50">{t('buyerAccount.myTicketsPage.transfer')}</button>}
                          <Link
                            to={`/tickets/${encodeURIComponent(ticket.display_credential)}`}
                            className="p-1.5 text-neutral-400 hover:text-brand-500 transition-colors rounded-lg hover:bg-brand-50"
                            title={t('buyerAccount.myTicketsPage.openTicketToDownload')}
                            onClick={(e) => e.stopPropagation()}
                          >
                            <Download className="h-4 w-4" />
                          </Link>
                          <Link to={`/tickets/${encodeURIComponent(ticket.display_credential)}`}>
                            <ChevronRight className="h-4 w-4 text-neutral-400" />
                          </Link>
                        </div>
                      </div>
                      {ticket.status === 'issued' && ticket.pending_transfer && (
                        <div className="pl-8">
                          <PendingTransfer transfer={ticket.pending_transfer} timeZone={event.timezone}
                            onCancel={() => apiClient.delete(`/me/tickets/${ticket.id}/transfer`)}
                            onSettled={({ message }) => { setTicketNotice(message); refreshTickets() }} />
                        </div>
                      )}
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

// Each event has an independent original/translation toggle. Issued ticket
// type names stay as printed on the ticket and on the organizer's door list.
function TranslatedEventHeading({ event }) {
  const content = useTranslatedContent(event)
  return <>
    <Link to={`/events/${event.slug}`} className="text-lg font-semibold text-neutral-900 hover:text-brand-600 transition-colors">{content.title}</Link>
    <MachineTranslationNotice {...content.notice} />
  </>
}
