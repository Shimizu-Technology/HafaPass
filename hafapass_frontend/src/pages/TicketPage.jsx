import useTranslatedContent from '../hooks/useTranslatedContent'
import MachineTranslationNotice from '../components/MachineTranslationNotice'
import { useTranslation } from 'react-i18next'
import { useState, useEffect, useLayoutEffect, useRef, useSyncExternalStore } from 'react'
import { useAuth } from '@clerk/clerk-react'
import { useLocation, useParams, Link } from 'react-router-dom'
import { Calendar, MapPin, Clock, AlertTriangle, Loader2, Download, Share2, Smartphone, ChevronDown, ChevronUp } from 'lucide-react'
import { motion, AnimatePresence, useReducedMotion } from 'framer-motion'
import api, { getApiAuthContext, subscribeApiAuthContext } from '../api/client'
import QRCode from '../components/QRCode'
import { formatEventDate, formatEventTime } from '../utils/eventTime'
import { checkoutBuyerIdentity, getOrderAccess, orderAccessHeaders } from '../utils/orderAccess'
import { SellerLine } from '../components/PriceDisclosure'

function AddToHomeScreenInstructions() {
  const { t } = useTranslation()
  const [expanded, setExpanded] = useState(false)
  const reducedMotion = useReducedMotion()
  const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent)
  const isAndroid = /Android/.test(navigator.userAgent)

  if (!isIOS && !isAndroid) return null

  return (
    <div className="mt-4">
      <button
        onClick={() => setExpanded(!expanded)}
        aria-expanded={expanded}
        className="min-h-11 flex items-center gap-2 rounded text-sm text-content-inverse-muted hover:text-white transition-colors mx-auto focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white"
      >
        <Smartphone className="w-4 h-4" />
        <span>{t('buyerAccount.ticketPage.addToHomeScreen')}</span>
        {expanded ? <ChevronUp className="w-3.5 h-3.5" /> : <ChevronDown className="w-3.5 h-3.5" />}
      </button>
      <AnimatePresence>
        {expanded && (
          <motion.div
            initial={reducedMotion ? false : { opacity: 1, height: 0 }}
            animate={{ opacity: 1, height: 'auto' }}
            exit={reducedMotion ? undefined : { opacity: 1, height: 0 }}
            transition={{ duration: reducedMotion ? 0 : 0.2 }}
            className="overflow-hidden"
          >
            <div className="mt-3 p-3 bg-neutral-50 rounded-xl text-xs text-neutral-600 space-y-1.5">
              {isIOS ? (
                <>
                  <p className="font-medium text-neutral-700">{t('buyerAccount.ticketPage.iOSInstructions')}</p>
                  <p>{t('buyerAccount.ticketPage.1TapTheShareButtonInSafari')}</p>
                  <p>{t('buyerAccount.ticketPage.2ScrollDownAndTapAddToHome')}</p>
                  <p>{t('buyerAccount.ticketPage.3TapAddToConfirm')}</p>
                </>
              ) : (
                <>
                  <p className="font-medium text-neutral-700">{t('buyerAccount.ticketPage.androidInstructions')}</p>
                  <p>{t('buyerAccount.ticketPage.1TapTheMenuThreeDotsInChrome')}</p>
                  <p>{t('buyerAccount.ticketPage.2TapAddToHomeScreen')}</p>
                  <p>{t('buyerAccount.ticketPage.3TapAddToConfirm')}</p>
                </>
              )}
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  )
}

function WalletButton({ label, icon, onClick, disabled, loading }) {
  const { t } = useTranslation()
  return (
      <button onClick={onClick} disabled={disabled || loading}
        className="w-full flex items-center justify-center gap-2 px-4 py-2.5 rounded-xl bg-neutral-900 hover:bg-neutral-800 text-white text-sm font-medium disabled:cursor-not-allowed disabled:opacity-50">
        {icon}
        <span>{loading ? t('buyerAccount.ticketPage.opening') : label}</span>
      </button>
  )
}

// Apple Wallet icon (SVG)
function AppleWalletIcon() {
  return (
    <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <rect x="3" y="5" width="18" height="14" rx="2" />
      <line x1="3" y1="10" x2="21" y2="10" />
    </svg>
  )
}

// Google Wallet icon (SVG)
function GoogleWalletIcon() {
  return (
    <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M21 12V7a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h7" />
      <circle cx="18" cy="18" r="3" />
      <path d="M18 15v6" />
      <path d="M15 18h6" />
    </svg>
  )
}

export default function TicketPage() {
  const { credential } = useParams()
  const location = useLocation()
  const orderId = new URLSearchParams(location.search).get('order')
  const routeKey = JSON.stringify([credential, orderId])
  return import.meta.env.VITE_CLERK_PUBLISHABLE_KEY
    ? <AuthenticatedTicket key={routeKey} /> : <TicketContent key={routeKey} />
}

function AuthenticatedTicket() {
  const { t } = useTranslation()
  const { isLoaded, userId, sessionId } = useAuth()
  const context = useSyncExternalStore(subscribeApiAuthContext, getApiAuthContext)
  const accountReady = context?.ready && context.userId === userId && context.sessionId === sessionId
  if (!isLoaded || checkoutBuyerIdentity() !== (userId || null)
    || (userId ? !accountReady : context?.userId)) {
    return <div className="grid min-h-[60vh] place-items-center" role="status">{t('buyerAccount.ticketPage.preparingYourAccount')}</div>
  }
  // Guests keep their explicit order capability; signed-in requests bind to the
  // authoritative session. A changed session remounts private state immediately.
  return <TicketContent key={JSON.stringify([userId, sessionId, context?.generation])}
    authContext={userId ? context : undefined} />
}

function TicketContent({ authContext }) {
  const { t } = useTranslation()
  const reducedMotion = useReducedMotion()
  const { credential } = useParams()
  const location = useLocation()
  const orderId = new URLSearchParams(location.search).get('order')
  const [ticket, setTicket] = useState(null)
  const eventContent = useTranslatedContent(ticket?.event)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [downloading, setDownloading] = useState(false)
  const [downloadError, setDownloadError] = useState(null)
  const [walletLoading, setWalletLoading] = useState(null)
  const [walletError, setWalletError] = useState(null)
  const lifecycle = useRef({ active: false, generation: 0 })
  const access = useRef({ buyerId: checkoutBuyerIdentity(), auth: getApiAuthContext(), token: getOrderAccess(orderId) })
  useLayoutEffect(() => {
    const state = lifecycle.current
    state.active = true
    state.generation += 1
    return () => { state.active = false; state.generation += 1 }
  }, [])

  function currentOperation() {
    const generation = lifecycle.current.generation
    return () => lifecycle.current.active && lifecycle.current.generation === generation
      && checkoutBuyerIdentity() === access.current.buyerId && getApiAuthContext() === access.current.auth
      && getOrderAccess(orderId) === access.current.token
  }

  useEffect(() => {
    let active = true
    const generation = lifecycle.current.generation
    const current = () => active && lifecycle.current.active && lifecycle.current.generation === generation
      && checkoutBuyerIdentity() === access.current.buyerId && getApiAuthContext() === access.current.auth
      && getOrderAccess(orderId) === access.current.token
    async function fetchTicket() {
      try {
        setLoading(true)
        setError(null)
        const response = await api.get(`/tickets/${encodeURIComponent(credential)}`, {
          headers: orderAccessHeaders(orderId, access.current.token), authContext,
        })
        if (!current()) return
        setTicket(response.data)
      } catch (err) {
        if (!current()) return
        if (err.response?.status === 404) {
          setError(t('buyerAccount.ticketPage.ticketNotFound'))
        } else {
          setError(t('buyerAccount.ticketPage.failedToLoadTicketPleaseTryAgain'))
        }
      } finally {
        if (current()) setLoading(false)
      }
    }
    fetchTicket()
    return () => { active = false }
  }, [credential, orderId, authContext, t])

  async function handleDownload() {
    const current = currentOperation()
    if (!current()) return
    let downloadUrl
    let downloadLink
    try {
      setDownloading(true)
      setDownloadError(null)
      const response = await api.get(`/tickets/${encodeURIComponent(credential)}/download`, {
        headers: orderAccessHeaders(orderId, access.current.token), authContext,
        responseType: 'blob',
      })
      if (!current()) return
      downloadUrl = window.URL.createObjectURL(new Blob([response.data], { type: 'application/pdf' }))
      downloadLink = document.createElement('a')
      downloadLink.href = downloadUrl
      downloadLink.setAttribute('download', `hafapass-ticket-${ticket.id}.pdf`)
      document.body.appendChild(downloadLink)
      downloadLink.click()
    } catch (error) {
      if (!current()) return
      let failure = error.response?.data
      if (error.response?.status === 422 && typeof failure?.text === 'function') {
        try { failure = JSON.parse(await failure.text()) } catch { failure = null }
      }
      if (!current()) return
      const unsupportedText = error.response?.status === 422 && failure?.error_code === 'unsupported_pdf_text'
      setDownloadError(unsupportedText
        ? t('buyerAccount.ticketPage.thePDFCannotDisplaySomeTextOnThis')
        : t('buyerAccount.ticketPage.weCouldnTDownloadThePDFYourTicket'))
    } finally {
      downloadLink?.remove()
      if (downloadUrl) window.URL.revokeObjectURL(downloadUrl)
      if (current()) setDownloading(false)
    }
  }

  async function handleShare() {
    if (!currentOperation()()) return
    if (navigator.share) {
      try {
        await navigator.share({
          title: eventContent.title || t('buyerAccount.ticketPage.myTicket'),
          text: t('buyerAccount.ticketPage.checkOutMyTicketFor', { event: eventContent.title }),
          url: window.location.href,
        })
      } catch {
        // User cancelled
      }
    }
  }

  async function handleWallet(kind) {
    const current = currentOperation()
    if (!current()) return
    let walletUrl
    setWalletLoading(kind)
    setWalletError(null)
    try {
      if (kind === 'apple') {
        const response = await api.get(`/tickets/${encodeURIComponent(credential)}/wallet/apple`, {
          headers: orderAccessHeaders(orderId, access.current.token), authContext, responseType: 'blob',
        })
        if (!current()) return
        walletUrl = window.URL.createObjectURL(response.data)
        const link = document.createElement('a')
        link.href = walletUrl
        link.download = `hafapass-ticket-${ticket.id}.pkpass`
        link.click()
      } else {
        const response = await api.get(`/tickets/${encodeURIComponent(credential)}/wallet/google`, {
          params: { response: 'json' }, headers: orderAccessHeaders(orderId, access.current.token), authContext,
        })
        if (!current()) return
        window.location.assign(response.data.url)
      }
    } catch (err) {
      if (current()) setWalletError(err.response?.data?.error || t('buyerAccount.ticketPage.walletIsUnavailable', { wallet: kind === 'apple' ? 'Apple' : 'Google' }))
    } finally {
      if (walletUrl) window.URL.revokeObjectURL(walletUrl)
      if (current()) setWalletLoading(null)
    }
  }

  if (loading) {
    return (
      <div className="flex justify-center items-center min-h-[60vh]">
        <Loader2 className="w-10 h-10 text-brand-500 animate-spin" />
      </div>
    )
  }

  if (error) {
    return (
      <div className="max-w-md mx-auto px-4 py-12 text-center">
        <div className="card p-8">
          <AlertTriangle className="w-12 h-12 text-red-400 mx-auto mb-3" />
          <h1 className="text-xl font-bold text-neutral-950 mb-3">{t('buyerAccount.ticketPage.ticketUnavailable')}</h1>
          <p role="alert" className="text-red-700 font-medium mb-4">{error}</p>
          <Link to="/events" className="btn-primary text-sm">{t('buyerAccount.ticketPage.browseEvents')}</Link>
        </div>
      </div>
    )
  }

  const { event, ticket_type } = ticket

  const formatDate = (dateStr) => formatEventDate(dateStr, event?.timezone, { weekday: 'long', month: 'long' })
  const formatTime = (dateStr) => formatEventTime(dateStr, event?.timezone)

  const statusConfig = {
    access_paused: { label: t('buyerAccount.ticketPage.accessPaused'), bg: 'bg-amber-50', text: 'text-amber-800', border: 'border-amber-200', dot: 'bg-amber-500' },
    issued: { label: t('buyerAccount.ticketPage.valid'), bg: 'bg-emerald-50', text: 'text-emerald-700', border: 'border-emerald-200', dot: 'bg-emerald-500' },
    checked_in: { label: t('buyerAccount.ticketPage.used'), bg: 'bg-neutral-100', text: 'text-neutral-600', border: 'border-neutral-200', dot: 'bg-neutral-400' },
    cancelled: { label: t('buyerAccount.ticketPage.cancelled'), bg: 'bg-red-50', text: 'text-red-700', border: 'border-red-200', dot: 'bg-red-500' },
    transferred: { label: t('buyerAccount.ticketPage.transferred'), bg: 'bg-amber-50', text: 'text-amber-700', border: 'border-amber-200', dot: 'bg-amber-500' },
  }

  const accessPaused = ticket.status === 'issued' && (ticket.admission_allowed === false || Boolean(ticket.admission_block_reason))
  const status = accessPaused ? statusConfig.access_paused : statusConfig[ticket.status] || statusConfig.issued
  const showCredential = ticket.admission_allowed && Boolean(ticket.scan_credential)

  return (
    <div className="min-h-screen bg-gradient-to-b from-neutral-950 via-neutral-900 to-neutral-950 flex items-center justify-center px-3 sm:px-4 py-8">
      <motion.div
        className="w-full max-w-[380px] sm:max-w-sm"
        initial={reducedMotion ? false : { opacity: 1, y: 8 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: reducedMotion ? 0 : 0.22, ease: [0, 0, 0.2, 1] }}
      >
        {['postponed', 'cancelled'].includes(event.status) && (
          <div className="mb-4 rounded-xl border border-amber-300 bg-amber-50 p-4 text-sm text-amber-900">
            <strong className="capitalize">{t('buyerAccount.ticketPage.event', { status: t(`buyerAccount.ticketPage.eventStatus.${event.status}`, { defaultValue: event.status }) })}</strong>{t('buyerAccount.ticketPage.keepThisTicketAndWatchYourEmailFor')}</div>
        )}
        {!ticket.admission_allowed && !['postponed', 'cancelled'].includes(event.status) && (
          <div className="mb-4 rounded-xl border border-red-300 bg-red-50 p-4 text-sm text-red-900">
            <strong>{t('buyerAccount.ticketPage.ticketUnavailable2')}</strong> {ticket.admission_block_reason || t('buyerAccount.ticketPage.thisTicketIsNotCurrentlyValidForEntry')}
          </div>
        )}
        {/* Main Ticket Card */}
        <div className="bg-white rounded-2xl overflow-hidden shadow-2xl shadow-black/30">
          {/* Cover image banner */}
          {event.cover_image_url && (
            <div className="h-32 sm:h-36 overflow-hidden relative">
              <img
                src={event.cover_image_url}
                alt={eventContent.title}
                className="w-full h-full object-cover"
              />
              <div className="absolute inset-0 bg-gradient-to-t from-black/40 to-transparent" />
            </div>
          )}

          {/* Status Badge */}
          <div className={`px-4 py-2.5 ${status.bg} ${status.border} border-b text-center`}>
            <span className={`inline-flex items-center gap-2 text-sm font-semibold ${status.text}`}>
              <span className={`w-2 h-2 rounded-full ${status.dot} ${ticket.status === 'issued' && !accessPaused ? 'animate-pulse motion-reduce:animate-none' : ''}`} />
              {status.label}
            </span>
            {ticket.status === 'checked_in' && ticket.checked_in_at && (
              <span className={`block text-xs ${status.text} opacity-75 mt-0.5`}>{t('buyerAccount.ticketPage.checkedInAt', { time: formatTime(ticket.checked_in_at) })}</span>
            )}
          </div>

          {/* QR Code Section */}
          {showCredential ? <motion.div
            className="px-4 sm:px-6 pt-6 pb-4 flex flex-col items-center"
            initial={false}
            animate={{ scale: 1, opacity: 1 }}
            transition={{ duration: 0 }}
          >
            <div className="bg-white p-3 rounded-xl border border-neutral-100 shadow-sm">
              <QRCode value={ticket.scan_credential} size={220} />
            </div>
            <p className="mt-2 text-[10px] sm:text-xs text-content-muted font-mono break-all text-center select-all">{t('buyerAccount.ticketPage.ticketHPT', { id: ticket.id })}</p>
          </motion.div> : (
            <div className="px-6 py-8 text-center">
              <AlertTriangle className="mx-auto mb-2 h-8 w-8 text-neutral-400" />
              <p className="text-sm font-medium text-neutral-700">{t('buyerAccount.ticketPage.entryCodeUnavailable')}</p>
              <p className="mt-1 text-xs text-neutral-500">{t('buyerAccount.ticketPage.openThisTicketFromYourSecureOrderConfirmation')}</p>
            </div>
          )}

          {/* Ticket-style divider */}
          <div className="relative px-6">
            <div className="absolute left-0 top-1/2 -translate-y-1/2 w-4 h-8 bg-neutral-950 rounded-r-full" />
            <div className="absolute right-0 top-1/2 -translate-y-1/2 w-4 h-8 bg-neutral-950 rounded-l-full" />
            <div className="border-t border-dashed border-neutral-200" />
          </div>

          {/* Event Details */}
          <div className="px-4 sm:px-6 py-5 space-y-3">
            <div>
              <h1 className="font-display text-lg font-bold text-neutral-900">{eventContent.title}</h1>
              <MachineTranslationNotice {...eventContent.notice} />
              <p className="text-sm text-action font-semibold font-sans">{ticket_type.name}</p>
              {ticket.seat && <p className="mt-1 text-sm font-semibold text-brand-700">{ticket.seat.display_label}</p>}
              {ticket.seat?.obstructed_view && <p className="mt-1 text-xs text-amber-700">{t('buyerAccount.ticketPage.obstructedView')}{ticket.seat.view_note ? `: ${ticket.seat.view_note}` : ''}</p>}
            </div>

            <div className="space-y-2.5">
              <div className="flex items-start gap-2.5">
                <Calendar className="w-4 h-4 text-neutral-400 mt-0.5 flex-shrink-0" />
                <div>
                  <p className="text-sm text-neutral-700 font-sans">{formatDate(event.starts_at)}</p>
                  <p className="text-xs text-neutral-500 font-sans">
                    {formatTime(event.starts_at)}
                    {event.ends_at && ` \u2013 ${formatTime(event.ends_at)}`}
                  </p>
                </div>
              </div>

              <div className="flex items-start gap-2.5">
                <MapPin className="w-4 h-4 text-neutral-400 mt-0.5 flex-shrink-0" />
                <div>
                  <p className="text-sm text-neutral-700 font-sans">{event.venue_name}</p>
                  {event.venue_address && (
                    <p className="text-xs text-neutral-500 font-sans">{event.venue_address}</p>
                  )}
                </div>
              </div>

              {event.doors_open_at && (
                <div className="flex items-center gap-2.5">
                  <Clock className="w-4 h-4 text-neutral-400 flex-shrink-0" />
                  <p className="text-xs text-neutral-500 font-sans">{t('buyerAccount.ticketPage.doorsOpenAt', { time: formatTime(event.doors_open_at) })}</p>
                </div>
              )}
            </div>
            <SellerLine seller={ticket.seller} className="mt-3 font-sans" />

          </div>

          {/* Action Buttons */}
          <div className="px-4 sm:px-6 pb-5 space-y-2.5">
            {/* Download PDF */}
            <button
              onClick={handleDownload}
              disabled={downloading || !showCredential}
              className="w-full flex items-center justify-center gap-2 px-4 py-2.5 rounded-xl min-h-11 bg-action-teal hover:bg-action-teal-hover text-content-inverse text-sm font-semibold transition-colors disabled:opacity-60 disabled:cursor-not-allowed focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2"
            >
              {downloading ? (
                <Loader2 className="w-4 h-4 animate-spin" />
              ) : (
                <Download className="w-4 h-4" />
              )}
              <span>{downloading ? t('buyerAccount.ticketPage.generating') : t('buyerAccount.ticketPage.downloadPDF')}</span>
            </button>
            {downloadError && <p role="alert" className="rounded-xl bg-amber-50 p-3 text-sm text-amber-950">{downloadError}</p>}

            {/* Share */}
            {typeof navigator !== 'undefined' && navigator.share && (
              <button
                onClick={handleShare}
                className="w-full flex items-center justify-center gap-2 px-4 py-2.5 rounded-xl bg-neutral-100 hover:bg-neutral-200 text-neutral-700 text-sm font-medium transition-colors"
              >
                <Share2 className="w-4 h-4" />
                <span>{t('buyerAccount.ticketPage.shareTicket')}</span>
              </button>
            )}

            {walletError && <p className="text-center text-xs text-red-600">{walletError}</p>}
            {(ticket.wallet_availability?.apple || ticket.wallet_availability?.google) && (
              <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
                {ticket.wallet_availability.apple && (
                  <WalletButton label={t('buyerAccount.ticketPage.appleWallet')} icon={<AppleWalletIcon />} disabled={!showCredential}
                    loading={walletLoading === 'apple'} onClick={() => handleWallet('apple')} />
                )}
                {ticket.wallet_availability.google && (
                  <WalletButton label={t('buyerAccount.ticketPage.googleWallet')} icon={<GoogleWalletIcon />} disabled={!showCredential}
                    loading={walletLoading === 'google'} onClick={() => handleWallet('google')} />
                )}
              </div>
            )}
          </div>

          {/* Footer */}
          <div className="px-4 sm:px-6 py-3 bg-neutral-50 text-center border-t border-neutral-100">
            <p className="text-xs text-content-muted font-sans">
              {showCredential ? t('buyerAccount.ticketPage.presentThisQRCodeAtTheDoor') : t('buyerAccount.ticketPage.thisTicketHasNoActiveEntryCode')}
            </p>
          </div>
        </div>

        {/* Add to Home Screen */}
        <AddToHomeScreenInstructions />
      </motion.div>
    </div>
  )
}
